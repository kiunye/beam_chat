defmodule BeamChatWeb.RoomLive.Show do
  @moduledoc """
  The room view: message stream (LiveView stream + ChatScroll), typing
  indicators, composer, presence rail, and the LiveKit video panel —
  inlined directly into the view (no LiveComponent, per the project's
  LiveView guidelines).

  Security posture (PRD §2.2, §4.5): every mutating event re-fetches the
  user fresh from the database (`fresh_active_user/1`) so a ban or an
  expired paid subscription issued mid-session cannot keep this LiveView
  acting on behalf of an authorized user. Room entry itself was checked at
  mount via `BeamChat.Rooms.AccessPolicy`.
  """

  use BeamChatWeb, :live_view

  alias BeamChat.Accounts.User
  alias BeamChat.Messages.Message
  alias BeamChat.Repo
  alias BeamChat.Rooms
  alias BeamChat.Rooms.AccessPolicy
  alias BeamChat.Settings
  alias BeamChat.Video.TokenService
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
        mount_room(socket, Repo.preload(room, [:category, :owner]))
    end
  end

  defp mount_room(socket, room) do
    user = socket.assigns.current_user
    topic = Rooms.topic(room.id)

    case AccessPolicy.check(room, user) do
      :ok ->
        messages = Rooms.list_recent_messages(room.id)
        message_form = to_form(%{"content" => ""}, as: :message)

        socket =
          socket
          |> assign(:page_title, room.name)
          |> assign(:room, room)
          |> assign(:access, :ok)
          |> assign(:active_nav, :rooms)
          |> assign(:topic, topic)
          |> assign(:typing_user_ids, MapSet.new())
          |> assign(:typing_clear_timer_ref, nil)
          |> assign(:typing_broadcast_at, nil)
          |> assign(:presence_list, %{})
          |> assign(:presence_list_sorted, [])
          |> assign(:sibling_rooms, load_sibling_rooms(user, room))
          |> assign(:room_member_count, Rooms.member_count(room.id))
          |> assign(:participant_count, nil)
          |> assign(:message_form, message_form)
          |> assign(:can_video, AccessPolicy.can_video?(room, user))
          |> assign(:can_moderate, Rooms.can_moderate?(user, room))
          |> assign(:video_configured, video_configured?())
          |> assign(:video_state, :idle)
          |> assign(:video_error, nil)
          |> stream(:messages, messages, dom_id: &message_dom_id/1)

        socket =
          if connected?(socket) do
            Rooms.subscribe(room.id)

            {:ok, _} =
              RoomPresence.track(self(), topic, user.id, %{
                username: user.username,
                online_at: System.system_time(:second),
                video_active: false
              })

            presence_list = RoomPresence.list(topic)

            socket
            |> assign(:presence_list, presence_list)
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
    |> assign(:active_nav, :rooms)
    |> assign(:access, {:blocked, reason})
    |> assign(:wallet_balance, wallet_balance_for_blocked(user, reason))
    |> assign(:topic, nil)
    |> assign(:presence_list, %{})
    |> assign(:presence_list_sorted, [])
    |> assign(:message_form, nil)
    |> assign(:can_video, false)
    |> assign(:can_moderate, false)
    |> assign(:video_configured, false)
    |> assign(:video_state, :idle)
    |> assign(:video_error, nil)
    |> assign(:participant_count, nil)
    |> assign(:typing_user_ids, MapSet.new())
    |> assign(:typing_clear_timer_ref, nil)
    |> assign(:typing_broadcast_at, nil)
    |> stream(:messages, [], reset: true)
  end

  # Paid-room gate shows the wallet balance so the shortfall is visible
  # and the user can go top up (PRD §2.6).
  defp wallet_balance_for_blocked(user, :upgrade_required) do
    case BeamChat.Wallet.ensure_wallet(user.id) do
      {:ok, wallet} -> wallet.balance
      _ -> Decimal.new(0)
    end
  end

  defp wallet_balance_for_blocked(_user, _reason), do: nil

  defp message_dom_id(%Message{id: id}), do: "msg-#{id}"

  @impl true
  def terminate(_reason, socket) do
    user = socket.assigns[:current_user]
    room = socket.assigns[:room]
    topic = socket.assigns[:topic]

    if socket.assigns[:access] == :ok && user && room && topic do
      # `untrack/3` is a call to the presence server; run it in a detached
      # task so shutdown never blocks on a busy presence process.
      pid = self()
      Task.start(fn -> RoomPresence.untrack(pid, topic, user.id) end)
    end

    :ok
  end

  ## Server messages

  @impl true
  def handle_info({:new_message, %Message{} = msg}, socket) do
    if msg.room_id == socket.assigns.room.id do
      {:noreply,
       socket
       |> stream_insert(:messages, msg)
       |> maybe_scroll_flagged(msg)}
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
    Rooms.set_typing(socket.assigns.room.id, user_id, false)

    {:noreply,
     socket
     |> assign(:typing_clear_timer_ref, nil)
     |> assign(:typing_broadcast_at, nil)}
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

  ## Events

  @impl true
  def handle_event("send", %{"message" => %{"content" => content}}, socket) do
    socket = cancel_typing_clear_timer(socket)

    case fresh_active_user(socket) do
      {:ok, user} ->
        case Rooms.send_message(socket.assigns.room, user.id, content) do
          {:ok, _row} ->
            Rooms.set_typing(socket.assigns.room.id, user.id, false)

            {:noreply,
             socket
             |> assign(:message_form, to_form(%{"content" => ""}, as: :message))
             |> assign(:typing_clear_timer_ref, nil)}

          {:error, {:blocked, reason}} ->
            {:noreply, put_flash(socket, :error, "Message blocked: #{reason}")}

          {:error, :banned} ->
            {:noreply, reject_banned(socket, :banned)}

          {:error, {:access, reason}} ->
            {:noreply, reject_banned(socket, {:access, reason})}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not send that message.")}
        end

      {:error, reason} ->
        {:noreply, reject_banned(socket, reason)}
    end
  end

  def handle_event("typing", %{"message" => %{"content" => content}}, socket) do
    socket = cancel_typing_clear_timer(socket)

    case fresh_active_user(socket) do
      {:ok, user} ->
        handle_typing_content(socket, user, socket.assigns.room.id, content)

      {:error, _reason} ->
        # Silently no-op typing for banned/missing users. They can't see the
        # chat, so any in-flight typing event is irrelevant.
        {:noreply, socket}
    end
  end

  def handle_event("subscribe_paid_room", _params, socket) do
    room = socket.assigns.room

    case fresh_active_user(socket) do
      {:ok, user} ->
        case Rooms.subscribe_paid_room(user, room) do
          {:ok, _wallet, _txn, _sub} ->
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

      {:error, reason} ->
        {:noreply, reject_banned(socket, reason)}
    end
  end

  # -- Video (LiveKit), inlined: the hook carries the connection, this
  #    view carries the state.

  def handle_event("join_video", _params, socket) do
    case fresh_active_user(socket) do
      {:ok, user} -> do_join_video(socket, user)
      {:error, reason} -> {:noreply, reject_banned(socket, reason)}
    end
  end

  def handle_event("leave_video", _params, socket) do
    update_my_video_presence(socket, false)

    {:noreply,
     socket
     |> assign(:video_state, :idle)
     |> assign(:participant_count, nil)
     |> push_event("livekit_disconnect", %{})}
  end

  def handle_event("video_connected", params, socket) do
    update_my_video_presence(socket, true)

    {:noreply,
     socket
     |> assign(:video_state, :connected)
     |> assign(:participant_count, participant_count_from_params(params) || 1)}
  end

  def handle_event("video_disconnected", _params, socket) do
    update_my_video_presence(socket, false)

    {:noreply,
     socket
     |> assign(:video_state, :idle)
     |> assign(:participant_count, nil)}
  end

  def handle_event("video_error", %{"message" => message}, socket) do
    {:noreply,
     socket
     |> assign(:video_state, :error)
     |> assign(:video_error, message)}
  end

  # -- Moderation: soft-delete a message (room owner/moderator or staff).

  def handle_event("delete_message", %{"message_id" => message_id}, socket) do
    message = Repo.get(Message, message_id)

    if is_nil(message) or message.room_id != socket.assigns.room.id do
      {:noreply, put_flash(socket, :error, "That message is not in this room.")}
    else
      do_delete_message(socket, message)
    end
  end

  defp do_delete_message(socket, message) do
    case fresh_active_user(socket) do
      {:ok, user} ->
        case Rooms.delete_message(user, message, "removed by moderator") do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Message removed.")
             |> refresh_messages()}

          {:error, :forbidden} ->
            {:noreply, put_flash(socket, :error, "You cannot moderate this room.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not remove the message.")}
        end

      {:error, reason} ->
        {:noreply, reject_banned(socket, reason)}
    end
  end

  # `fresh_active_user/1` has already re-fetched the user (ban check) and
  # re-run the room access policy; `can_video?/2` is re-checked here so the
  # token is never issued for a room whose policy denies video (defence in
  # depth against a crafted phx-click with the button hidden).
  defp do_join_video(socket, user) do
    room = socket.assigns.room

    if AccessPolicy.can_video?(room, user) do
      case TokenService.generate_token(user, room.id) do
        {:ok, payload} ->
          {:noreply,
           socket
           |> assign(:video_state, :connecting)
           |> assign(:video_error, nil)
           |> push_event("livekit_connect", payload)}

        {:error, :not_configured} ->
          {:noreply,
           socket
           |> assign(:video_state, :error)
           |> assign(:video_error, "LiveKit is not configured on this server.")
           |> put_flash(:error, "Video is not configured. Contact an administrator.")}
      end
    else
      {:noreply,
       socket
       |> assign(:video_state, :idle)
       |> put_flash(:error, "You do not have permission to join the video room.")}
    end
  end

  # Applies the typing event for a known user: broadcasts the typing
  # indicator (throttled to at most once every 2200 ms) and schedules the
  # clear timer, or clears typing when the content is blank.
  defp handle_typing_content(socket, user, room_id, content) do
    if String.trim(content) != "" do
      now = System.monotonic_time(:millisecond)

      {should_broadcast, broadcast_at} =
        typing_broadcast_decision(now, socket.assigns[:typing_broadcast_at])

      if should_broadcast, do: Rooms.set_typing(room_id, user.id, true)

      timer_ref = Process.send_after(self(), {:clear_my_typing, user.id}, 2200)

      {:noreply,
       socket
       |> assign(:typing_broadcast_at, broadcast_at)
       |> assign(:typing_clear_timer_ref, timer_ref)}
    else
      Rooms.set_typing(room_id, user.id, false)

      {:noreply,
       socket
       |> assign(:typing_broadcast_at, nil)
       |> assign(:typing_clear_timer_ref, nil)}
    end
  end

  defp typing_broadcast_decision(now, last) do
    case last do
      nil -> {true, now}
      ts when now - ts >= 2200 -> {true, now}
      _ -> {false, last}
    end
  end

  defp participant_count_from_params(%{"participants" => n}) when is_integer(n), do: n
  defp participant_count_from_params(_), do: nil

  # Flips this LiveView process's own presence entry between video states so
  # the room has a view of who is currently in the LiveKit video room.
  defp update_my_video_presence(socket, active) do
    if socket.assigns[:access] == :ok && socket.assigns[:topic] && socket.assigns[:current_user] do
      RoomPresence.update(self(), socket.assigns.topic, socket.assigns.current_user.id, fn meta ->
        Map.put(meta, :video_active, active)
      end)
    end

    :ok
  end

  defp refresh_messages(socket) do
    messages = Rooms.list_recent_messages(socket.assigns.room.id)

    stream(socket, :messages, messages, reset: true, dom_id: &message_dom_id/1)
  end

  # A flagged message arriving live gets the same treatment as any other:
  # stream it (the flagged badge renders for moderators).
  defp maybe_scroll_flagged(socket, %Message{} = _msg), do: socket

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-5 section-spacious bg-grid-subtle min-h-dvh" id={"room-#{@room.id}"}>
      <header class="animate-fade-up">
        <nav
          aria-label="Room path"
          class="flex flex-wrap items-center gap-2 text-label-md text-base-content/40 mb-2"
        >
          <.link navigate={~p"/rooms"} class="hover:text-primary transition-colors">
            Rooms
          </.link>
          <%= for crumb <- category_crumbs(@room) do %>
            <span class="text-base-300">›</span>
            <span>{crumb}</span>
          <% end %>
          <span class="text-base-300">›</span>
          <span class="text-ink font-semibold">{@room.name}</span>
        </nav>

        <div class="flex flex-wrap items-center justify-between gap-4">
          <div class="min-w-0">
            <h1 class="flex flex-wrap items-center gap-2 text-headline-lg font-extrabold text-ink tracking-tight">
              <span class="text-base-content/25">#</span>
              {@room.name}
            </h1>

            <div class="flex flex-wrap items-center gap-2 mt-2">
              <span class="premium-chip" data-state="on" id="members-online-chip">
                <span class="size-1.5 rounded-full bg-primary pulse-dot"></span>
                {map_size(@presence_list)} online
              </span>
              <span class={[
                "premium-chip",
                @room.type != "public" && "border-amber-200 bg-amber-50 text-amber-800"
              ]}>
                {type_label(@room.type)}
              </span>
              <%= if @room.type == "paid" do %>
                <span class="premium-chip tnum">
                  {format_money(@room.price)} {Settings.base_currency()} / 30 days
                </span>
              <% end %>
            </div>
          </div>

          <div class="flex items-center gap-2" id="room-actions">
            <%= if @access == :ok and @can_video and @video_configured do %>
              <button
                :if={@video_state == :idle}
                type="button"
                class="btn btn-primary btn-premium"
                phx-click="join_video"
                id="join-video"
              >
                <span class="btn-icon"><.icon name="hero-video-camera" class="size-4" /></span>
                Join video
              </button>
              <button
                :if={@video_state in [:connecting, :connected]}
                type="button"
                class="btn btn-outline btn-error btn-premium"
                phx-click="leave_video"
                id="leave-video"
              >
                <span class="btn-icon"><.icon name="hero-phone-x-mark" class="size-4" /></span>
                Leave
                <span :if={@participant_count} class="badge badge-sm">{@participant_count}</span>
              </button>
            <% end %>
          </div>
        </div>
      </header>

      <%= case @access do %>
        <% {:blocked, reason} -> %>
          <.room_gate reason={reason} room={@room} wallet_balance={@wallet_balance} />
        <% :ok -> %>
          <div class="grid items-start gap-5 xl:grid-cols-[minmax(0,1fr)_18rem]">
            <section
              class="premium-card glass overflow-hidden animate-fade-up stagger-1"
              id="room-chat-panel"
            >
              <div class="flex flex-wrap items-center gap-3 border-b border-base-200/80 bg-base-100/40 px-5 py-3">
                <span class="rounded-md bg-primary/10 px-3 py-1 font-mono text-code-sm text-primary">
                  room:{@room.slug}
                </span>
                <span class="text-label-sm text-base-content/40 hidden sm:inline">
                  {@room_member_count} members
                </span>

                <label for="message-filter" class="sr-only">Filter messages</label>
                <input
                  id="message-filter"
                  type="search"
                  placeholder="Filter…"
                  autocomplete="off"
                  phx-hook=".MessageFilter"
                  class="search-input ml-auto w-44 px-4 py-2 text-xs"
                />
              </div>

              <div
                id="chat-scroll"
                phx-hook="ChatScroll"
                phx-update="stream"
                class="flex-1 min-h-[30rem] max-h-[70vh] space-y-1 overflow-y-auto px-5 py-5 scroll-smooth"
              >
                <div
                  id="room-messages-empty"
                  class="hidden only:block py-20 text-center"
                >
                  <div class="text-5xl mb-4 opacity-20">
                    <.icon name="hero-chat-bubble-left-right" class="size-16" />
                  </div>
                  <p class="text-base-content/40 text-lg">No messages yet — say hello.</p>
                </div>

                <div
                  :for={{mid, msg} <- @streams.messages}
                  id={mid}
                  data-message-row={msg.id}
                  class={[
                    "group flex gap-3 text-sm message-bubble",
                    own_message?(msg, @current_user) && "flex-row-reverse text-right"
                  ]}
                >
                  <div class={[
                    "flex size-9 shrink-0 items-center justify-center rounded-full text-xs font-bold uppercase",
                    own_message?(msg, @current_user) && "bg-primary text-primary-content shadow-sm",
                    !own_message?(msg, @current_user) && "bg-base-200 text-base-content/60"
                  ]}>
                    {initial(msg.sender)}
                  </div>

                  <div class={[
                    "min-w-0 max-w-[80%] flex-1",
                    own_message?(msg, @current_user) && "flex flex-col items-end"
                  ]}>
                    <div class={[
                      "flex items-center gap-2 text-xs mb-1",
                      own_message?(msg, @current_user) && "justify-end"
                    ]}>
                      <span class="font-semibold text-ink">
                        {sender_name(msg.sender, @current_user, own_message?(msg, @current_user))}
                      </span>
                      <span
                        :if={msg.sender && msg.sender.role == "moderator"}
                        class="rounded-full border border-primary/30 bg-primary/10 px-2 py-0.5 text-label-sm text-primary"
                      >
                        moderator
                      </span>
                      <span
                        :if={msg.sender && msg.sender.role == "admin"}
                        class="rounded-full border border-base-300 bg-base-100 px-2 py-0.5 text-label-sm text-base-content/50"
                      >
                        admin
                      </span>
                      <span
                        :if={@can_moderate and msg.moderation_flag}
                        class="badge badge-warning badge-sm"
                      >
                        flagged
                      </span>
                      <span class="tnum text-base-content/30">
                        {Calendar.strftime(msg.inserted_at, "%H:%M")}
                      </span>

                      <button
                        :if={@can_moderate and not msg.is_deleted}
                        type="button"
                        class="opacity-0 group-hover:opacity-100 transition-opacity text-base-content/30 hover:text-error"
                        phx-click="delete_message"
                        phx-value-message_id={msg.id}
                        data-confirm="Remove this message?"
                        aria-label="Remove message"
                        id={"delete-msg-#{msg.id}"}
                      >
                        <.icon name="hero-trash" class="size-3" />
                      </button>
                    </div>

                    <%= if msg.content do %>
                      <p class={[
                        "mt-1 rounded-2xl border px-4 py-2.5 whitespace-pre-wrap break-words text-[0.875rem]",
                        !own_message?(msg, @current_user) &&
                          "rounded-bl-md bg-base-100 border-base-200 text-ink text-left shadow-sm",
                        own_message?(msg, @current_user) &&
                          "rounded-br-md bg-primary text-primary-content text-left"
                      ]}>
                        {msg.content}
                      </p>
                    <% end %>
                  </div>
                </div>
              </div>

              <div
                class="min-h-[1.75rem] border-t border-base-200/50 px-5 py-2 text-xs text-base-content/40"
                aria-live="polite"
              >
                <span
                  :if={typing_line(@typing_user_ids, @current_user.id) != ""}
                  id="typing-indicator"
                  class="text-primary"
                >
                  ●●● {typing_line(@typing_user_ids, @current_user.id)}
                </span>
              </div>

              <.form
                for={@message_form}
                id="room-message-form"
                phx-submit="send"
                phx-change="typing"
                phx-hook=".ComposerSubmit"
                class="flex gap-3 border-t border-base-200/50 bg-white p-4"
              >
                <.input
                  field={@message_form[:content]}
                  type="textarea"
                  class="textarea textarea-bordered min-h-[3rem] flex-1 rounded-xl"
                  placeholder={"Message " <> @room.name}
                  rows="2"
                  autocomplete="off"
                  phx-debounce="400"
                />
                <div class="flex flex-col items-end justify-between">
                  <span class="text-label-sm text-base-content/30 hidden sm:inline">
                    Ctrl + Enter
                  </span>
                  <button type="submit" class="btn btn-primary btn-premium" id="send-room-message">
                    <span class="btn-icon"><.icon name="hero-paper-airplane" class="size-4" /></span>
                    Send
                  </button>
                </div>
              </.form>
            </section>

            <aside class="flex flex-col gap-4 animate-fade-up stagger-2" id="room-presence-panel">
              <div class="beam-media-stage p-4" id="livekit-tile">
                <div class="flex items-center justify-between">
                  <p class="text-label-sm uppercase tracking-widest text-white/40">Video</p>
                  <span
                    :if={@video_state == :connected}
                    class="inline-flex items-center gap-1 rounded-full bg-red-500/15 px-2 py-0.5 text-label-md text-red-400"
                  >
                    <span class="size-1.5 animate-pulse rounded-full bg-red-500 pulse-dot"></span>
                    {@participant_count || 1} in call
                  </span>
                </div>

                <%= if not @video_configured do %>
                  <p class="mt-2 text-sm text-white/50">
                    LiveKit video is not configured on this deployment.
                  </p>
                <% else %>
                  <%= if not @can_video do %>
                    <p class="mt-2 text-sm text-white/50">
                      You do not have video access to this room.
                    </p>
                  <% else %>
                    <div id="livekit-room" phx-hook="LiveKitRoom"></div>

                    <div class="mt-3" id="video-status">
                      <%= case @video_state do %>
                        <% :idle -> %>
                          <p class="text-sm text-white/50">
                            Camera off — join the call from the header.
                          </p>
                        <% :connecting -> %>
                          <p class="text-sm text-white/70">Connecting camera and microphone…</p>
                        <% :connected -> %>
                          <p class="text-sm text-emerald-300">
                            You are live. Mic and camera published.
                          </p>
                        <% :error -> %>
                          <p class="text-sm text-red-400" id="video-error-message">
                            {@video_error || "Connection failed."}
                          </p>
                      <% end %>
                    </div>
                  <% end %>
                <% end %>
              </div>

              <div class="premium-card p-5" id="presence-card">
                <h2 class="flex items-center gap-2 text-label-md uppercase tracking-wider text-base-content/40">
                  <.icon name="hero-user-group" class="size-4 text-primary" />
                  Online · {map_size(@presence_list)}
                </h2>

                <ul class="mt-3 space-y-2 text-sm" id="presence-list">
                  <li
                    :for={{uid, data} <- @presence_list_sorted}
                    id={"presence-" <> uid}
                    class="flex items-center gap-2"
                  >
                    <span class="size-2 rounded-full bg-primary pulse-dot"></span>
                    <span class="truncate font-medium">{presence_label(uid, data)}</span>
                    <span
                      :if={presence_video_active?(data)}
                      class="badge badge-primary badge-xs ml-auto"
                      id={"presence-video-" <> uid}
                    >
                      in video
                    </span>
                  </li>
                </ul>

                <p :if={map_size(@presence_list) == 0} class="text-xs text-base-content/40">
                  Connecting…
                </p>
              </div>

              <div class="premium-card p-5" id="sibling-rooms">
                <h2 class="flex items-center gap-2 text-label-md uppercase tracking-wider text-base-content/40">
                  <.icon name="hero-squares-2x2" class="size-4 text-primary" /> More in this category
                </h2>
                <ul class="mt-3 space-y-1 text-sm" id="sibling-room-list">
                  <li
                    :for={sub <- @sibling_rooms}
                    class="rounded-lg hover:bg-base-100 transition-colors"
                  >
                    <.link
                      navigate={~p"/rooms/#{sub.slug}"}
                      class="flex items-center gap-2 px-3 py-2 text-base-content/70 transition-colors"
                    >
                      <span class="text-base-content/25">#</span>
                      <span class="truncate font-medium">{sub.name}</span>
                    </.link>
                  </li>
                  <li :if={@sibling_rooms == []} class="px-3 py-2 text-sm text-base-content/30">
                    Nothing else here yet.
                  </li>
                </ul>
              </div>

              <div class="premium-card p-5">
                <h2 class="flex items-center gap-2 text-label-md uppercase tracking-wider text-base-content/40">
                  <.icon name="hero-shield-check" class="size-4 text-primary" /> About
                </h2>
                <dl class="mt-3 space-y-2 text-sm">
                  <div class="flex justify-between gap-4">
                    <dt class="text-base-content/40">Type</dt>
                    <dd class="font-semibold capitalize">{type_label(@room.type)}</dd>
                  </div>
                  <div class="flex justify-between gap-4">
                    <dt class="text-base-content/40">Category</dt>
                    <dd class="truncate font-semibold">
                      {(@room.category && @room.category.name) || "—"}
                    </dd>
                  </div>
                  <div class="flex justify-between gap-4">
                    <dt class="text-base-content/40">Owner</dt>
                    <dd class="truncate font-semibold">{@room.owner && @room.owner.username}</dd>
                  </div>
                  <div class="flex justify-between gap-4">
                    <dt class="text-base-content/40">Created</dt>
                    <dd class="tnum">{Calendar.strftime(@room.inserted_at, "%d %b %Y")}</dd>
                  </div>
                </dl>
              </div>
            </aside>
          </div>
      <% end %>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".MessageFilter">
      export default {
        mounted() {
          this.el.addEventListener("input", () => this.apply())
        },
        apply() {
          const q = this.el.value.trim().toLowerCase()
          document.querySelectorAll("[data-message-row]").forEach((el) => {
            const truthy = el.textContent.toLowerCase().includes(q)
            el.style.display = truthy ? "" : "none"
          })
        },
      }
    </script>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".ComposerSubmit">
      export default {
        mounted() {
          this.el.addEventListener("keydown", (e) => {
            if ((e.ctrlKey || e.metaKey) && e.key === "Enter") {
              e.preventDefault()
              this.el.requestSubmit()
            }
          })
        },
      }
    </script>
    """
  end

  # -- Access gates --------------------------------------------------------

  attr :reason, :atom, required: true
  attr :room, :any, required: true
  attr :wallet_balance, :any, default: nil

  defp room_gate(assigns) do
    ~H"""
    <%= case @reason do %>
      <% :upgrade_required -> %>
        <div
          class="card border border-amber-300/70 bg-amber-50 p-6 shadow-panel rounded-box space-y-3"
          id="access-upgrade-panel"
        >
          <h2 class="text-headline-md">Paid room</h2>
          <p class="text-sm text-base-content/70">
            Subscribe with your wallet balance ({format_money(@wallet_balance)} {Settings.base_currency()} available).
            Price: {format_money(@room.price || Decimal.new(0))} {Settings.base_currency()} for 30 days.
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
              <span class="text-sm text-base-content/60">
                Shortfall: {format_money(shortfall(@wallet_balance, @room.price))} {Settings.base_currency()}
              </span>
              <.link navigate={~p"/wallet"} class="btn btn-primary btn-sm" id="top-up-wallet-link">
                Top up wallet
              </.link>
            <% end %>
            <.link navigate={~p"/rooms"} class="btn btn-ghost btn-sm">Browse other rooms</.link>
          </div>
        </div>
      <% :membership_required -> %>
        <div
          class="card border border-primary/20 bg-primary/5 p-6 shadow-panel rounded-box space-y-3"
          id="access-request-panel"
        >
          <h2 class="text-headline-md">Membership required</h2>
          <p class="text-sm text-base-content/70">
            This room is private. Ask the owner or a platform moderator for a membership grant —
            memberships are handed out explicitly, never self-serve.
          </p>
          <.link navigate={~p"/rooms"} class="btn btn-outline btn-sm">Back to the directory</.link>
        </div>
      <% :secret_forbidden -> %>
        <div
          class="card border border-error/30 bg-red-50 p-6 shadow-panel rounded-box space-y-3"
          id="access-secret-panel"
        >
          <h2 class="text-headline-md">Secret room</h2>
          <p class="text-sm text-base-content/70">You do not have access to this room.</p>
          <.link navigate={~p"/rooms"} class="btn btn-ghost btn-sm">Leave</.link>
        </div>
      <% :archived -> %>
        <div
          class="card border border-base-300 bg-base-100 p-6 shadow-panel rounded-box space-y-3"
          id="access-archived-panel"
        >
          <h2 class="text-headline-md">Archived</h2>
          <p class="text-sm text-base-content/70">This room has been archived and is read-only.</p>
          <.link navigate={~p"/rooms"} class="btn btn-outline btn-sm">Back to the directory</.link>
        </div>
      <% :banned -> %>
        <div
          class="card border border-error/30 bg-red-50 p-6 shadow-panel rounded-box space-y-3"
          id="access-banned-panel"
        >
          <h2 class="text-headline-md">Account restricted</h2>
          <p class="text-sm text-base-content/70">Your account is banned and cannot enter rooms.</p>
        </div>
      <% :not_authenticated -> %>
        <div
          class="card border border-base-300 bg-base-100 p-6 shadow-panel rounded-box space-y-3"
          id="access-login-panel"
        >
          <h2 class="text-headline-md">Log in</h2>
          <p class="text-sm text-base-content/70">You need to log in to enter this room.</p>
          <.link navigate={~p"/auth/login"} class="btn btn-primary btn-sm">Log in</.link>
        </div>
    <% end %>
    """
  end

  # -- Helpers ----------------------------------------------------------------

  defp category_crumbs(nil), do: []
  defp category_crumbs(%{category: nil}), do: []

  defp category_crumbs(%{category: category}) when not is_nil(category) do
    category
    |> BeamChat.Categories.path()
    |> Enum.map(& &1.name)
  end

  # "More in this category" rail: sibling rooms visible to the user.
  defp load_sibling_rooms(_user, %{category_id: nil}), do: []

  defp load_sibling_rooms(user, %{category_id: category_id, id: room_id}) do
    Rooms.list_visible_rooms(user, category_id: category_id)
    |> Enum.reject(&(&1.id == room_id))
    |> Enum.take(8)
  end

  defp type_label("public"), do: "public"
  defp type_label("private"), do: "private"
  defp type_label("paid"), do: "paid"
  defp type_label("secret"), do: "secret"
  defp type_label(other), do: other

  defp own_message?(%{sender_id: sender_id}, %{id: me}), do: sender_id == me
  defp own_message?(_, _), do: false

  defp initial(nil), do: "?"
  defp initial(%{username: u}) when is_binary(u), do: String.first(u) |> String.upcase()

  defp sender_name(_sender, _me, true), do: "You"
  defp sender_name(sender, _me, false), do: display_name(sender)

  defp display_name(nil), do: "Unknown"
  defp display_name(%{username: u}), do: u

  defp presence_label(_uid, %{metas: [%{username: u} | _]}) when is_binary(u), do: u
  defp presence_label(uid, _), do: String.slice(uid, 0, 8) <> "…"

  defp presence_video_active?(%{metas: metas}) when is_list(metas) do
    Enum.any?(metas, &(&1[:video_active] == true))
  end

  defp presence_video_active?(_), do: false

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
      [] -> ""
      [_] -> "Someone is typing…"
      _ -> "Several people are typing…"
    end
  end

  defp sorted_presence_list(presence_list) when is_map(presence_list) do
    presence_list
    |> Map.to_list()
    |> Enum.sort_by(fn {uid, _} -> uid end)
  end

  defp format_money(%Decimal{} = d), do: Decimal.round(d, 2) |> Decimal.to_string(:normal)
  defp format_money(nil), do: "0.00"

  defp sufficient_for_paid_room?(%Decimal{} = balance, price) do
    price = price || Decimal.new(0)

    Decimal.compare(price, Decimal.new(0)) == :gt and
      Decimal.compare(balance, price) in [:gt, :eq]
  end

  defp sufficient_for_paid_room?(_, _), do: false

  defp shortfall(%Decimal{} = balance, price) do
    price
    |> Decimal.sub(balance)
    |> Decimal.max(Decimal.new(0))
    |> Decimal.round(2)
  end

  defp shortfall(nil, price), do: format_money(price)

  defp video_configured? do
    case TokenService.generate_token(%{id: Ecto.UUID.autogenerate()}, Ecto.UUID.autogenerate()) do
      {:ok, _payload} -> true
      {:error, :not_configured} -> false
    end
  rescue
    _ -> false
  end

  # Re-fetch the user from the database so that a ban issued mid-session
  # cannot keep the LiveView acting on behalf of an authorized user
  # (PRD §2.2 — fresh, per-request database check).
  defp fresh_active_user(socket) do
    case socket.assigns[:current_user] do
      nil ->
        {:error, :no_user}

      %User{id: uid} ->
        case Repo.get_by(User, id: uid) do
          nil -> {:error, :user_gone}
          %User{is_banned: true} -> {:error, :banned}
          %User{} = fresh -> authorize_against_room(socket, fresh)
        end
    end
  end

  defp authorize_against_room(socket, %User{} = fresh) do
    case AccessPolicy.check(socket.assigns.room, fresh) do
      :ok -> {:ok, fresh}
      {:blocked, reason} -> {:error, {:access, reason}}
    end
  end

  defp reject_banned(socket, reason) do
    case reason do
      :banned ->
        socket
        |> put_flash(:error, "Your account is no longer authorized to do that.")
        |> push_navigate(to: ~p"/rooms")

      :user_gone ->
        socket
        |> put_flash(:error, "Your account could not be found.")
        |> push_navigate(to: ~p"/auth/login")

      {:access, :upgrade_required} ->
        socket
        |> put_flash(:error, "Your paid subscription has lapsed.")
        |> push_navigate(to: ~p"/rooms/#{socket.assigns.room.slug}")

      {:access, _other} ->
        socket
        |> put_flash(:error, "You no longer have access to this room.")
        |> push_navigate(to: ~p"/rooms")

      _ ->
        put_flash(socket, :error, "Action not permitted.")
    end
  end
end
