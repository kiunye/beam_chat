defmodule BeamChatWeb.RoomLive.Show do
  use BeamChatWeb, :live_view

  alias BeamChat.MessagePipeline.Producer
  alias BeamChat.Messages.Message
  alias BeamChat.Rooms
  alias BeamChat.Rooms.AccessPolicy
  alias BeamChat.Rooms.Room
  alias BeamChat.Video.TokenService
  alias BeamChat.Wallet
  alias BeamChatWeb.RoomPresence

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Rooms.get_room_by_slug(slug) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That room could not be found.")
         |> push_navigate(to: ~p"/rooms")}

      room ->
        mount_room(socket, room)
    end
  end

  defp mount_room(socket, room) do
    user = socket.assigns.current_user
    topic = "room:#{room.id}"

    case AccessPolicy.check(room, user) do
      :ok ->
        messages = Rooms.list_recent_messages(room.id)
        message_form = to_form(%{"content" => ""}, as: :message)

        socket =
          socket
          |> assign(:page_title, room.name)
          |> assign(:room, room)
          |> assign(:access, :ok)
          |> assign(:wallet_balance, nil)
          |> assign(:topic, topic)
          |> assign(:typing_user_ids, MapSet.new())
          |> assign(:typing_clear_timer_ref, nil)
          |> assign(:presence_list, %{})
          |> assign(:presence_list_sorted, [])
          |> assign(:message_form, message_form)
          |> assign(:can_video, can_video?(user, room))
          |> assign(:video_configured, video_configured?())
          |> stream(:messages, messages, dom_id: &message_dom_id/1)

        socket =
          if connected?(socket) do
            Rooms.ensure_room_server_started(room.id)
            Room.join_room(room.id, user.id, user.username)
            Phoenix.PubSub.subscribe(BeamChat.PubSub, topic)

            {:ok, _} =
              RoomPresence.track(self(), topic, user.id, %{
                username: user.username,
                online_at: System.system_time(:second)
              })

            presence_list = RoomPresence.list(topic)

            assign(socket, :presence_list, presence_list)
            |> assign(:presence_list_sorted, sorted_presence_list(presence_list))
          else
            socket
          end

        {:ok, socket}

      {:blocked, reason} ->
        {:ok, assign_blocked_mount(socket, room, reason, user)}
    end
  end

  defp assign_blocked_mount(socket, room, reason, user) do
    socket
    |> assign(:page_title, room.name)
    |> assign(:room, room)
    |> assign(:access, {:blocked, reason})
    |> assign(:wallet_balance, wallet_balance_for_blocked(user, reason))
    |> assign(:topic, nil)
    |> assign(:typing_user_ids, MapSet.new())
    |> assign(:typing_clear_timer_ref, nil)
    |> assign(:presence_list, %{})
    |> assign(:presence_list_sorted, [])
    |> assign(:message_form, nil)
    |> stream(:messages, [], reset: true)
  end

  defp wallet_balance_for_blocked(user, :upgrade_required) do
    case Wallet.ensure_wallet(user.id) do
      {:ok, w} -> w.balance
      _ -> Decimal.new(0)
    end
  end

  defp wallet_balance_for_blocked(_, _), do: nil

  defp message_dom_id(%Message{id: id}), do: "msg-#{id}"

  @impl true
  def terminate(_reason, socket) do
    user = socket.assigns[:current_user]
    room = socket.assigns[:room]
    topic = socket.assigns[:topic]

    if socket.assigns[:access] == :ok && user && room && topic do
      Room.leave_room(room.id, user.id)
      RoomPresence.untrack(self(), topic, user.id)
    end

    :ok
  end

  @impl true
  def handle_info({:new_message, %Message{} = msg}, socket) do
    if msg.room_id == socket.assigns.room.id do
      {:noreply, stream_insert(socket, :messages, msg)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:user_typing, %{data: uid}}, socket) do
    {:noreply, assign(socket, :typing_user_ids, MapSet.put(socket.assigns.typing_user_ids, uid))}
  end

  def handle_info({:user_stopped_typing, %{data: uid}}, socket) do
    {:noreply,
     assign(socket, :typing_user_ids, MapSet.delete(socket.assigns.typing_user_ids, uid))}
  end

  def handle_info({:clear_my_typing, user_id}, socket) do
    Room.set_typing(socket.assigns.room.id, user_id, false)
    {:noreply, assign(socket, :typing_clear_timer_ref, nil)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", topic: topic}, socket) do
    if socket.assigns[:topic] == topic do
      presence_list = RoomPresence.list(topic)

      {:noreply,
       socket
       |> assign(:presence_list, presence_list)
       |> assign(:presence_list_sorted, sorted_presence_list(presence_list))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("send", %{"message" => %{"content" => content}}, socket) do
    socket = cancel_typing_clear_timer(socket)

    Producer.push_messages(BeamChat.MessagePipeline, [
      %{
        room_id: socket.assigns.room.id,
        user_id: socket.assigns.current_user.id,
        content: content,
        inserted_at: nil
      }
    ])

    Room.set_typing(socket.assigns.room.id, socket.assigns.current_user.id, false)

    {:noreply,
     socket
     |> assign(:message_form, to_form(%{"content" => ""}, as: :message))
     |> assign(:typing_clear_timer_ref, nil)}
  end

  def handle_event("subscribe_paid_room", _, socket) do
    room = socket.assigns.room
    user = socket.assigns.current_user

    case Wallet.subscribe_paid_room(user, room) do
      {:ok, _, _, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "You are subscribed. Welcome in!")
         |> push_navigate(to: ~p"/rooms/#{room.slug}")}

      {:error, :insufficient_funds} ->
        {:noreply,
         socket
         |> put_flash(:error, "Not enough wallet balance. Top up from your wallet page.")
         |> push_navigate(to: ~p"/wallet")}

      {:error, :already_subscribed} ->
        {:noreply,
         socket
         |> put_flash(:info, "You already have an active subscription.")
         |> push_navigate(to: ~p"/rooms/#{room.slug}")}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not complete subscription.")
         |> push_navigate(to: ~p"/rooms")}
    end
  end

  def handle_event("typing", %{"message" => %{"content" => content}}, socket) do
    room_id = socket.assigns.room.id
    user_id = socket.assigns.current_user.id
    socket = cancel_typing_clear_timer(socket)

    timer_ref =
      if String.trim(content) != "" do
        Room.set_typing(room_id, user_id, true)
        Process.send_after(self(), {:clear_my_typing, user_id}, 2200)
      else
        Room.set_typing(room_id, user_id, false)
        nil
      end

    {:noreply, assign(socket, :typing_clear_timer_ref, timer_ref)}
  end

  # Video events sent from the client-side LiveKitRoom hook are forwarded
  # to the VideoLive LiveComponent (id="video-panel") for state tracking.
  def handle_event("video_connected", params, socket) do
    send_update(BeamChatWeb.VideoLive, id: "video-panel", video_state: :connected)

    {:noreply,
     socket
     |> assign_video_participant_count(params)}
  end

  def handle_event("video_disconnected", _params, socket) do
    send_update(BeamChatWeb.VideoLive, id: "video-panel", video_state: :idle)
    {:noreply, socket}
  end

  def handle_event("video_error", %{"message" => message}, socket) do
    send_update(BeamChatWeb.VideoLive,
      id: "video-panel",
      video_state: :error,
      video_error: message
    )

    {:noreply, socket}
  end

  defp assign_video_participant_count(socket, %{"participants" => n}) when is_integer(n),
    do: assign(socket, :participant_count, n)

  defp assign_video_participant_count(socket, _), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex flex-wrap items-center gap-3">
        <.link navigate={~p"/rooms"} class="btn btn-ghost btn-sm" id="back-to-rooms">
          ← Rooms
        </.link>
        <h1 class="font-display text-xl font-semibold tracking-tight text-base-content">
          {@room.name}
        </h1>
        <span class="badge badge-ghost badge-sm">@{@room.slug}</span>
      </div>

      <%= case @access do %>
        <% {:blocked, :upgrade_required} -> %>
          <div
            class="rounded-box border border-warning/40 bg-warning/10 p-6 space-y-3"
            id="access-upgrade-panel"
          >
            <h2 class="font-display font-semibold text-lg text-base-content">Paid room</h2>
            <p class="text-sm text-base-content/80">
              Subscribe with your wallet balance ({format_money(@wallet_balance)} {@room.currency} available).
              Price: {format_money(@room.price || Decimal.new(0))} {@room.currency} for 30 days.
            </p>
            <div class="flex flex-wrap gap-2">
              <%= if sufficient_for_paid_room?(@wallet_balance, @room.price) do %>
                <button
                  type="button"
                  phx-click="subscribe_paid_room"
                  class="btn btn-primary btn-sm"
                  id="subscribe-paid-room"
                >
                  Subscribe with wallet
                </button>
              <% else %>
                <.link navigate={~p"/wallet"} class="btn btn-primary btn-sm" id="top-up-wallet-link">
                  Top up wallet
                </.link>
              <% end %>
              <.link navigate={~p"/rooms"} class="btn btn-ghost btn-sm">
                Browse other rooms
              </.link>
            </div>
          </div>
        <% {:blocked, :membership_required} -> %>
          <div
            class="rounded-box border border-info/40 bg-info/10 p-6 space-y-3"
            id="access-request-panel"
          >
            <h2 class="font-display font-semibold text-lg text-base-content">Membership required</h2>
            <p class="text-sm text-base-content/80">
              This room is private or secret. Request access from the owner or a moderator, or use an
              invite link when your host shares one.
            </p>
            <ul class="text-sm text-base-content/70 list-disc pl-5 space-y-1">
              <li>Owners can add members from the moderation tools (coming soon).</li>
              <li>If you were invited, accept the invite from your email or dashboard.</li>
            </ul>
            <.link navigate={~p"/rooms"} class="btn btn-outline btn-sm">
              Back to directory
            </.link>
          </div>
        <% {:blocked, :secret_forbidden} -> %>
          <div class="rounded-box border border-error/40 bg-error/10 p-6" id="access-secret-panel">
            <p class="text-sm text-base-content/90">You do not have access to this secret room.</p>
            <.link navigate={~p"/rooms"} class="btn btn-ghost btn-sm mt-3">Leave</.link>
          </div>
        <% :ok -> %>
          <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_14rem] items-stretch">
            <section
              class="flex flex-col rounded-box border border-base-300 bg-base-100 min-h-[28rem] shadow-sm"
              id="room-chat-panel"
            >
              <div
                id="chat-scroll"
                phx-hook="ChatScroll"
                phx-update="stream"
                class="flex-1 overflow-y-auto px-4 py-3 space-y-3 scroll-smooth"
              >
                <div
                  id="room-messages-empty"
                  class="hidden only:block text-sm text-base-content/60 text-center py-12"
                >
                  No messages yet — say hello.
                </div>
                <div
                  :for={{mid, msg} <- @streams.messages}
                  id={mid}
                  class="flex gap-2 text-sm"
                >
                  <div class="shrink-0 w-24 text-xs text-base-content/55 truncate">
                    {display_name(msg.sender)}
                  </div>
                  <div class="min-w-0 flex-1">
                    <p class="text-base-content whitespace-pre-wrap break-words">{msg.content}</p>
                    <p class="text-[0.65rem] text-base-content/45 mt-0.5">
                      {format_time(msg.inserted_at)}
                    </p>
                  </div>
                </div>
              </div>

              <div class="border-t border-base-300 px-3 py-2 min-h-[2.5rem] text-xs text-base-content/65">
                <%= if typing_line(@typing_user_ids, @current_user.id) != "" do %>
                  <span id="typing-indicator">{typing_line(@typing_user_ids, @current_user.id)}</span>
                <% end %>
              </div>

              <.form
                for={@message_form}
                id="room-message-form"
                phx-submit="send"
                phx-change="typing"
                class="border-t border-base-300 p-3 flex gap-2"
              >
                <.input
                  field={@message_form[:content]}
                  type="textarea"
                  class="textarea textarea-bordered flex-1 min-h-[3rem]"
                  placeholder={"Message " <> @room.name}
                  rows="2"
                  autocomplete="off"
                  phx-debounce="400"
                />
                <button type="submit" class="btn btn-primary self-end" id="send-room-message">
                  Send
                </button>
              </.form>
            </section>

            <aside
              class="rounded-box border border-base-300 bg-base-200/40 p-3"
              id="room-presence-panel"
            >
              <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/60 mb-2">
                Here now
              </h2>
              <ul class="space-y-2 text-sm" id="presence-list">
                <li
                  :for={{uid, data} <- @presence_list_sorted}
                  id={"presence-" <> uid}
                >
                  <span class="font-medium text-base-content truncate block">
                    {presence_label(uid, data)}
                  </span>
                  <span class="text-[0.65rem] text-success">● online</span>
                </li>
              </ul>
              <p :if={map_size(@presence_list) == 0} class="text-xs text-base-content/55">
                Connecting…
              </p>

              <.live_component
                :if={@video_configured}
                module={BeamChatWeb.VideoLive}
                id="video-panel"
                room={@room}
                current_user={@current_user}
                can_video={@can_video}
              />
            </aside>
          </div>
      <% end %>
    </div>
    """
  end

  defp display_name(nil), do: "Unknown"
  defp display_name(%{username: u}), do: u

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M")
  end

  defp presence_label(_uid, %{metas: [%{username: u} | _]}) when is_binary(u), do: u
  defp presence_label(uid, _), do: String.slice(uid, 0, 8) <> "…"

  defp cancel_typing_clear_timer(socket) do
    case socket.assigns[:typing_clear_timer_ref] do
      ref when is_reference(ref) ->
        Process.cancel_timer(ref)
        assign(socket, :typing_clear_timer_ref, nil)

      _ ->
        socket
    end
  end

  defp typing_line(ids, me) do
    ids
    |> MapSet.delete(me)
    |> MapSet.to_list()
    |> case do
      [] ->
        ""

      [_] ->
        "Someone is typing…"

      _ ->
        "Several people are typing…"
    end
  end

  defp sorted_presence_list(presence_list) when is_map(presence_list) do
    presence_list
    |> Map.to_list()
    |> Enum.sort_by(fn {uid, _} -> uid end)
  end

  defp format_money(%Decimal{} = d), do: Decimal.round(d, 2) |> Decimal.to_string(:normal)
  defp format_money(nil), do: "0.00"

  defp sufficient_for_paid_room?(%Decimal{} = bal, price) do
    price = price || Decimal.new(0)

    Decimal.compare(price, Decimal.new(0)) == :gt and
      Decimal.compare(bal, price) in [:gt, :eq]
  end

  defp sufficient_for_paid_room?(_, _), do: false

  defp can_video?(user, room), do: AccessPolicy.can_video?(room, user)

  defp video_configured? do
    case TokenService.generate_token(%{id: Ecto.UUID.autogenerate()}, Ecto.UUID.autogenerate()) do
      {:ok, _payload} -> true
      {:error, :not_configured} -> false
    end
  rescue
    _ -> false
  end
end
