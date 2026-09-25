defmodule BeamChatWeb.RoomLive.Show do
  use BeamChatWeb, :live_view

  alias BeamChat.Accounts.User
  alias BeamChat.Messages.Message
  alias BeamChat.Repo
  alias BeamChat.Rooms
  alias BeamChat.Rooms.AccessPolicy
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
          |> assign(:active_tab, :channel)
          |> assign(:active_room_slug, room.slug)
          |> assign(:livekit_on_air, false)
          |> assign(:wallet_balance, nil)
          |> assign(:topic, topic)
          |> assign(:typing_user_ids, MapSet.new())
          |> assign(:typing_clear_timer_ref, nil)
          |> assign(:typing_broadcast_at, nil)
          |> assign(:presence_list, %{})
          |> assign(:presence_list_sorted, [])
          |> assign(:subrooms, load_sibling_rooms(room))
          |> assign(:room_member_count, Rooms.room_member_count(room.id))
          |> assign(:participant_count, nil)
          |> assign(:message_form, message_form)
          |> assign(:can_video, can_video?(user, room))
          |> assign(:video_configured, video_configured?())
          |> stream(:messages, messages, dom_id: &message_dom_id/1)

        socket =
          if connected?(socket) do
            Phoenix.PubSub.subscribe(BeamChat.PubSub, topic)

            {:ok, _} =
              RoomPresence.track(self(), topic, user.id, %{
                username: user.username,
                online_at: System.system_time(:second),
                video_active: false
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
    |> assign(:active_tab, :channel)
    |> assign(:livekit_on_air, false)
    |> assign(:participant_count, nil)
    |> assign(:access, {:blocked, reason})
    |> assign(:wallet_balance, wallet_balance_for_blocked(user, reason))
    |> assign(:topic, nil)
    |> assign(:typing_user_ids, MapSet.new())
    |> assign(:typing_clear_timer_ref, nil)
    |> assign(:typing_broadcast_at, nil)
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
      # `untrack/3` is a call to the presence server; run it in a detached task
      # so shutdown never blocks on a busy presence process (SECURITY_REVIEW.md
      # P3 #25). The pid is captured first — the task process must not be the
      # one tracked in the presence entry.
      pid = self()
      Task.start(fn -> RoomPresence.untrack(pid, topic, user.id) end)
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

  @impl true
  def handle_event("send", %{"message" => %{"content" => content}}, socket) do
    socket = cancel_typing_clear_timer(socket)

    case fresh_active_user(socket) do
      {:ok, user} ->
        case Rooms.send_message(socket.assigns.room.id, user.id, content) do
          {:ok, _row} ->
            Rooms.set_typing(socket.assigns.room.id, user.id, false)

            {:noreply,
             socket
             |> assign(:message_form, to_form(%{"content" => ""}, as: :message))
             |> assign(:typing_clear_timer_ref, nil)}

          {:error, {:blocked, reason}} ->
            {:noreply, put_flash(socket, :error, "Message blocked: #{reason}")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not send that message.")}
        end

      {:error, reason} ->
        {:noreply, reject_banned(socket, reason)}
    end
  end

  def handle_event("subscribe_paid_room", _, socket) do
    room = socket.assigns.room

    case fresh_active_user(socket) do
      {:ok, user} ->
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

      {:error, reason} ->
        {:noreply, reject_banned(socket, reason)}
    end
  end

  def handle_event("typing", %{"message" => %{"content" => content}}, socket) do
    socket = cancel_typing_clear_timer(socket)

    case fresh_active_user(socket) do
      {:ok, user} ->
        room_id = socket.assigns.room.id
        handle_typing_content(socket, user, room_id, content)

      {:error, _reason} ->
        # Silently no-op typing for banned/missing users. They can't see the
        # chat, so any in-flight typing event is irrelevant.
        {:noreply, socket}
    end
  end

  # Video events sent from the client-side LiveKitRoom hook are forwarded
  # to the VideoLive LiveComponent (id="video-panel") for state tracking.
  #
  # NOTE: `participant_count` must ride the `send_update` — the component
  # update message is processed before the parent's own
  # `assign_video_participant_count/2` lands on the first connect, and the
  # component's render reads `@participant_count` whenever `video_state` is
  # `:connected`. Without it the component render raises KeyError. This also
  # feeds the "N live" badge in the video panel (falls back to 1 when the
  # count is unknown).
  def handle_event("video_connected", params, socket) do
    participant_count = participant_count_from_params(params)

    send_update(BeamChatWeb.VideoLive,
      id: "video-panel",
      video_state: :connected,
      participant_count: participant_count
    )

    update_my_video_presence(socket, true)

    {:noreply,
     socket
     |> assign(:livekit_on_air, true)
     |> assign_video_participant_count(params)}
  end

  def handle_event("video_disconnected", _params, socket) do
    send_update(BeamChatWeb.VideoLive, id: "video-panel", video_state: :idle)
    update_my_video_presence(socket, false)
    {:noreply, socket |> assign(:livekit_on_air, false)}
  end

  def handle_event("video_error", %{"message" => message}, socket) do
    send_update(BeamChatWeb.VideoLive,
      id: "video-panel",
      video_state: :error,
      video_error: message
    )

    {:noreply, socket}
  end

  # Applies the typing event for a known user: broadcasts the typing
  # indicator (throttled to at most once every 2200 ms — see
  # `typing_broadcast_decision/2`) and schedules the clear timer, or clears
  # typing when the content is blank.
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

  # Typing broadcasts are throttled to at most once every 2200 ms
  # while the user is typing.
  defp typing_broadcast_decision(now, last) do
    case last do
      nil -> {true, now}
      ts when now - ts >= 2200 -> {true, now}
      _ -> {false, last}
    end
  end

  defp assign_video_participant_count(socket, params) do
    case participant_count_from_params(params) do
      nil -> socket
      n -> assign(socket, :participant_count, n)
    end
  end

  defp participant_count_from_params(%{"participants" => n}) when is_integer(n), do: n
  defp participant_count_from_params(_), do: nil

  # Flips this LiveView process's own presence entry between video states so
  # the room has a cluster-wide view of who is currently in the LiveKit video
  # room. Guarded like `terminate/2` so it only runs for an authorised member
  # on a room topic. `RoomPresence.update/4` is a GenServer call — it runs
  # inline inside the event handler, like the `track/4` call at mount.
  defp update_my_video_presence(socket, active) do
    if socket.assigns[:access] == :ok && socket.assigns[:topic] && socket.assigns[:current_user] do
      RoomPresence.update(self(), socket.assigns.topic, socket.assigns.current_user.id, fn meta ->
        Map.put(meta, :video_active, active)
      end)
    end

    :ok
  end

  @doc """
  The Active Channel view: message stream with per-sender bubbles, typing
  indicators, a compose bar, and the inspector rail (presence + LiveKit
  video panel + room dossier).
  """
  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-5" id={"channel-#{@room.id}"}>
      <!-- Breadcrumb + title + channel health -->
      <header class="flex flex-wrap items-start justify-between gap-3">
        <div class="space-y-1 min-w-0">
          <nav
            aria-label="Room path"
            class="text-label-sm font-medium text-slate-500 flex flex-wrap items-center gap-2"
          >
            <.link navigate={~p"/rooms"} class="hover:text-emerald-700" id="back-to-rooms">
              {tenant_name(@room)}
            </.link>
            <span class="text-slate-300">›</span>
            <span class="text-slate-700">{parent_label(@room)}</span>
            <span class="text-slate-300">›</span>
            <span class="text-slate-900">{@room.name}</span>
          </nav>

          <h1 class="font-display text-headline-lg tracking-tight text-slate-900 flex flex-wrap items-center gap-2">
            <.icon name="hero-squares-2x2" class="size-5 text-emerald-600" />
            {@room.name}
          </h1>

          <div class="flex flex-wrap items-center gap-2 pt-1">
            <span class="civic-chip" data-state="on" id="officers-online-chip">
              <span class="size-1.5 rounded-full bg-emerald-500" />
              {map_size(@presence_list)} online
            </span>
            <span class="civic-chip">Phoenix LiveView sync stream</span>
            <span class={[
              "civic-chip",
              @room.type != "public" && "border-amber-200 bg-amber-50 text-amber-800"
            ]}>
              {channel_type_label(@room)}
            </span>
          </div>
        </div>

        <div class="flex items-center gap-2" id="channel-actions">
          <%= if @access == :ok and @can_video do %>
            <button
              type="button"
              class="btn btn-sm btn-primary rounded-md gap-2"
              phx-click={JS.push("join_video", target: "#video-panel")}
              id="channel-join-call"
            >
              <.icon name="hero-video-camera" class="size-4" /> Join call
              <span
                :if={@participant_count}
                class="rounded-full bg-emerald-500/30 px-2 py-0.5 text-label-sm font-semibold text-emerald-50"
              >
                {@participant_count} on call
              </span>
            </button>
          <% end %>
        </div>
      </header>

      <%= case @access do %>
        <% {:blocked, reason} -> %>
          <.channel_gate reason={reason} room={@room} wallet_balance={@wallet_balance} />
        <% :ok -> %>
          <div class="grid gap-5 xl:grid-cols-[15rem_minmax(0,1fr)_20rem] lg:grid-cols-[minmax(0,1fr)_20rem] lg:items-start">
            <!-- Sub-dockets (same ward / sibling rooms) -->
            <aside
              class="hidden lg:block rounded-lg border border-slate-200 bg-white p-4 shadow-civic-2"
              id="channel-subrooms"
            >
              <h2 class="text-label-sm uppercase tracking-[0.12em] text-slate-500 flex items-center justify-between">
                Sub-dockets <.icon name="hero-squares-2x2" class="size-4" />
              </h2>

              <ul class="mt-3 space-y-1" id="subroom-list">
                <li :for={sub <- @subrooms} class="rounded-md hover:bg-slate-50">
                  <.link
                    navigate={~p"/rooms/#{sub.slug}"}
                    class="flex items-center gap-2 px-2 py-1.5 text-sm text-slate-700"
                  >
                    <span class="text-slate-400">#</span>
                    <span class="truncate">{sub.name}</span>
                    <span
                      :if={sub.id == @room.id}
                      class="ml-auto badge badge-xs bg-emerald-50 text-emerald-700 border border-emerald-200"
                    >
                      live
                    </span>
                  </.link>
                </li>
                <li :if={@subrooms == []} class="px-2 py-2 text-sm text-slate-500">
                  No sub-rooms attached here yet.
                </li>
              </ul>
            </aside>
            
    <!-- Message stream -->
            <section
              class="flex flex-col rounded-lg border border-slate-200 bg-white shadow-sm min-h-[32rem] overflow-hidden"
              id="room-chat-panel"
            >
              <div class="flex flex-wrap items-center gap-2 border-b border-slate-200 bg-slate-50/60 px-4 py-2.5">
                <span class="rounded-md bg-slate-900 px-2 py-1 font-mono text-code-sm text-white">
                  phoenix_channel:{@room.slug}
                </span>

                <span
                  :if={typing_line(@typing_user_ids, @current_user.id) == ""}
                  class="text-xs text-slate-500"
                >
                  LiveView latency <span class="tnum">0ms</span>
                </span>

                <span
                  :if={typing_line(@typing_user_ids, @current_user.id) == ""}
                  class="inline-flex items-center gap-1 text-xs text-slate-500"
                >
                  <.icon name="hero-lock-closed" class="size-3.5 text-slate-400" />
                  RLS-verified tenant mesh
                </span>

                <label for="message-filter" class="sr-only">Filter messages</label>
                <input
                  id="message-filter"
                  type="search"
                  placeholder="Filter this channel…"
                  autocomplete="off"
                  phx-hook=".MessageFilter"
                  class="ml-auto w-48 rounded-md border border-slate-200 bg-white px-3 py-1.5 text-xs text-slate-800 placeholder:text-slate-400 focus:border-emerald-500"
                />
              </div>

              <div
                id="chat-scroll"
                phx-hook="ChatScroll"
                phx-update="stream"
                class="flex-1 overflow-y-auto px-4 py-4 space-y-3 scroll-smooth"
              >
                <div
                  id="room-messages-empty"
                  class="hidden only:block text-center text-sm text-slate-500 py-14"
                >
                  No messages yet — say hello.
                </div>

                <div
                  :for={{mid, msg} <- @streams.messages}
                  id={mid}
                  data-message-row={msg.id}
                  class={[
                    "flex gap-3 text-sm",
                    own_message?(msg, @current_user) && "flex-row-reverse text-right"
                  ]}
                >
                  <div class={[
                    "flex size-8 shrink-0 items-center justify-center rounded-full text-xs font-semibold",
                    own_message?(msg, @current_user) && "bg-emerald-700 text-white",
                    !own_message?(msg, @current_user) && "bg-slate-200 text-slate-700"
                  ]}>
                    {initial(msg.sender)}
                  </div>

                  <div class={[
                    "min-w-0 flex-1 max-w-[85%]",
                    own_message?(msg, @current_user) && "flex flex-col items-end"
                  ]}>
                    <div class={[
                      "flex items-center gap-2 text-xs",
                      own_message?(msg, @current_user) && "justify-end"
                    ]}>
                      <span class="font-semibold text-slate-800">
                        {sender_name(msg.sender, @current_user, own_message?(msg, @current_user))}
                      </span>
                      <span
                        :if={msg.sender && msg.sender.role == "moderator"}
                        class="text-label-sm text-emerald-700 bg-emerald-50 border border-emerald-200 rounded-full px-2 py-0.5"
                      >
                        moderator
                      </span>
                      <span
                        :if={msg.sender && msg.sender.role == "admin"}
                        class="text-label-sm text-slate-600 bg-slate-100 border border-slate-200 rounded-full px-2 py-0.5"
                      >
                        admin
                      </span>
                      <span class="tnum text-slate-400">
                        {Calendar.strftime(msg.inserted_at, "%H:%M")}
                      </span>
                    </div>

                    <%= if msg.content do %>
                      <p class={[
                        "mt-1 whitespace-pre-wrap break-words rounded-lg px-3.5 py-2 shadow-sm",
                        !own_message?(msg, @current_user) &&
                          "bg-white border border-slate-200 border-l-[3px] border-l-emerald-600 text-slate-800 text-left",
                        own_message?(msg, @current_user) && "bg-slate-900 text-slate-50 text-left"
                      ]}>
                        {msg.content}
                      </p>
                    <% end %>

                    <p class={[
                      "text-[0.65rem] text-slate-400 mt-1 flex items-center gap-1",
                      own_message?(msg, @current_user) && "justify-end"
                    ]}>
                      {if own_message?(msg, @current_user),
                        do: "Dispatched · Synchronous ACK",
                        else: ""}
                    </p>
                  </div>
                </div>
              </div>
              
    <!-- Typing line -->
              <div
                class="border-t border-slate-200 px-4 py-2 min-h-[1.75rem] text-xs text-slate-500"
                aria-live="polite"
              >
                <span
                  :if={typing_line(@typing_user_ids, @current_user.id) != ""}
                  id="typing-indicator"
                  class="text-emerald-700"
                >
                  ●●● {typing_line(@typing_user_ids, @current_user.id)}
                </span>
              </div>
              
    <!-- Composer -->
              <.form
                for={@message_form}
                id="room-message-form"
                phx-submit="send"
                phx-change="typing"
                phx-hook=".ComposerSubmit"
                class="border-t border-slate-200 p-3 flex gap-2 bg-white"
              >
                <.input
                  field={@message_form[:content]}
                  type="textarea"
                  class="textarea textarea-bordered flex-1 min-h-[3rem] rounded-md border-slate-300 focus:border-emerald-500"
                  placeholder={"Message " <> @room.name}
                  rows="2"
                  autocomplete="off"
                  phx-debounce="400"
                />
                <div class="flex flex-col items-end justify-between">
                  <span class="text-label-sm text-slate-400">Ctrl + Enter to dispatch</span>
                  <button
                    type="submit"
                    class="btn btn-primary rounded-md gap-2"
                    id="send-room-message"
                  >
                    Send <.icon name="hero-paper-airplane" class="size-4" />
                  </button>
                </div>
              </.form>
            </section>
            
    <!-- Inspector -->
            <aside class="space-y-4" id="room-presence-panel">
              <!-- LiveKit tile -->
              <div class="civic-tile-dark p-4 space-y-3" id="livekit-tile">
                <div class="flex items-center justify-between">
                  <p class="text-label-sm uppercase tracking-[0.12em] text-slate-400">LiveKit room</p>
                  <span
                    :if={@participant_count}
                    class="inline-flex items-center gap-1 rounded-full bg-red-500/15 px-2 py-0.5 text-label-md text-red-400"
                  >
                    <span class="size-1.5 rounded-full bg-red-500 animate-pulse" /> Online
                  </span>
                </div>

                <.live_component
                  :if={@video_configured}
                  module={BeamChatWeb.VideoLive}
                  id="video-panel"
                  room={@room}
                  current_user={@current_user}
                  can_video={@can_video}
                />
              </div>
              
    <!-- Online presence -->
              <div
                class="rounded-lg border border-slate-200 bg-white p-4 shadow-civic-2"
                id="presence-card"
              >
                <h2 class="text-label-sm uppercase tracking-[0.12em] text-slate-500 flex items-center gap-2">
                  <.icon name="hero-user-group" class="size-4 text-emerald-600" />
                  Online · {map_size(@presence_list)} {grammar("officer", map_size(@presence_list))}
                </h2>

                <ul class="mt-3 space-y-2 text-sm" id="presence-list">
                  <li
                    :for={{uid, data} <- @presence_list_sorted}
                    id={"presence-" <> uid}
                    class="flex items-center gap-2"
                  >
                    <span class="size-2 rounded-full bg-emerald-500" />
                    <span class="font-medium text-slate-800 truncate">
                      {presence_label(uid, data)}
                    </span>
                    <span
                      :if={presence_video_active?(data)}
                      class="ml-auto badge badge-xs bg-emerald-50 text-emerald-700 border border-emerald-200"
                      id={"presence-video-" <> uid}
                    >
                      In video
                    </span>
                  </li>
                </ul>

                <p :if={map_size(@presence_list) == 0} class="text-xs text-slate-500">
                  The stream is connecting…
                </p>
              </div>
              
    <!-- Room dossier -->
              <div class="rounded-lg border border-slate-200 bg-white p-4 shadow-civic-2">
                <h2 class="text-label-sm uppercase tracking-[0.12em] text-slate-500 flex items-center gap-2">
                  <.icon name="hero-shield-check" class="size-4 text-emerald-600" /> Channel profile
                </h2>

                <dl class="mt-3 space-y-2 text-body-md text-slate-600">
                  <div class="flex justify-between gap-4">
                    <dt>Scope</dt>
                    <dd class="font-medium text-slate-900">{type_label(@room.type)}</dd>
                  </div>
                  <div class="flex justify-between gap-4">
                    <dt>Slug</dt>
                    <dd class="font-mono text-code-sm text-slate-800">#{@room.slug}</dd>
                  </div>
                  <div class="flex justify-between gap-4">
                    <dt>Owner</dt>
                    <dd class="font-medium text-slate-900 truncate">
                      @{@room.owner && @room.owner.username}
                    </dd>
                  </div>
                  <div class="flex justify-between gap-4">
                    <dt>Registered</dt>
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

  defp display_name(nil), do: "Unknown"
  defp display_name(%{username: u}), do: u

  # Sibling sub-rooms of the current room (its parent's children when it has
  # a parent, else the room's own children) — feeding the "Sub-dockets" rail.
  defp load_sibling_rooms(%{parent_id: nil} = room), do: Rooms.list_child_rooms(room.id)

  defp load_sibling_rooms(%{parent_id: parent_id}),
    do: parent_id |> Rooms.list_child_rooms() |> Enum.reject(&is_nil(&1.parent_id))

  defp tenant_name(%{tenant: %{name: name}}) when is_binary(name), do: name
  defp tenant_name(_), do: "County"

  defp parent_label(%{parent: %{name: name}}) when is_binary(name), do: name

  defp parent_label(%{category: %{name: name}}) when is_binary(name), do: name

  defp parent_label(_), do: "Channels"

  defp channel_type_label(%{type: "public"}), do: "Open channel"
  defp channel_type_label(%{type: "private"}), do: "Members-only channel"

  defp channel_type_label(%{type: "paid", price: price}),
    do: "Paid advisory · " <> format_money(price)

  defp channel_type_label(%{type: "secret"}), do: "Secret committee"
  defp channel_type_label(_), do: "Open channel"

  defp type_label("public"), do: "Open"
  defp type_label("private"), do: "Members-only"
  defp type_label("paid"), do: "Paid advisory"
  defp type_label("secret"), do: "Secret committee"
  defp type_label(other), do: other

  defp own_message?(%{sender_id: sid}, %{id: me}), do: sid == me
  defp own_message?(_, _), do: false

  defp initial(nil), do: "?"
  defp initial(%{username: u}) when is_binary(u), do: String.first(u) |> String.upcase()

  defp sender_name(_sender, me, true), do: "You (@" <> username_or_member(me) <> ")"
  defp sender_name(sender, _me, false), do: display_name(sender) || "member"

  defp username_or_member(%{username: u}), do: u
  defp username_or_member(_), do: "member"

  defp grammar(word, 1), do: word
  defp grammar(word, _n), do: word <> "s"

  # Access gates: paid / membership / secret panels restyled to the civic card
  # scheme. Ids retained — the room access upgrade tests target them.

  attr :reason, :atom, required: true
  attr :room, :any, required: true
  attr :wallet_balance, :any, default: nil

  defp channel_gate(assigns) do
    ~H"""
    <%= case @reason do %>
      <% :upgrade_required -> %>
        <div
          class="rounded-lg border border-amber-300/60 bg-amber-50 p-6 space-y-3 shadow-civic-2"
          id="access-upgrade-panel"
        >
          <h2 class="font-display text-headline-md text-slate-900">Paid room</h2>

          <p class="text-sm text-slate-700">
            Subscribe with your wallet balance ({format_money(@wallet_balance)} {@room.currency} available).
            Price: {format_money(@room.price || Decimal.new(0))} {@room.currency} for 30 days.
          </p>

          <div class="flex flex-wrap gap-2">
            <%= if sufficient_for_paid_room?(@wallet_balance, @room.price) do %>
              <button
                type="button"
                phx-click="subscribe_paid_room"
                class="btn btn-primary btn-sm rounded-md"
                id="subscribe-paid-room"
              >
                Subscribe with wallet
              </button>
            <% else %>
              <.link
                navigate={~p"/wallet"}
                class="btn btn-primary btn-sm rounded-md"
                id="top-up-wallet-link"
              >
                Top up wallet
              </.link>
            <% end %>
            <.link navigate={~p"/rooms"} class="btn btn-ghost btn-sm rounded-md">
              Browse other rooms
            </.link>
          </div>
        </div>
      <% :membership_required -> %>
        <div
          class="rounded-lg border border-emerald-200 bg-emerald-50/60 p-6 space-y-3 shadow-civic-2"
          id="access-request-panel"
        >
          <h2 class="font-display text-headline-md text-slate-900">Membership required</h2>

          <p class="text-sm text-slate-700">
            This room is private or secret. Request access from the owner or a moderator, or use an
            invite link when your host shares one.
          </p>

          <ul class="text-sm text-slate-600 list-disc pl-5 space-y-1">
            <li>Owners can add members from the moderation tools (coming soon).</li>

            <li>If you were invited, accept the invite from your email or dashboard.</li>
          </ul>
          <.link navigate={~p"/rooms"} class="btn btn-outline btn-sm rounded-md">
            Back to directory
          </.link>
        </div>
      <% :secret_forbidden -> %>
        <div
          class="rounded-lg border border-red-200 bg-red-50 p-6 shadow-civic-2"
          id="access-secret-panel"
        >
          <p class="text-sm text-red-800">You do not have access to this secret room.</p>
          <.link navigate={~p"/rooms"} class="btn btn-ghost btn-sm rounded-md mt-3">Leave</.link>
        </div>
    <% end %>
    """
  end

  defp presence_label(_uid, %{metas: [%{username: u} | _]}) when is_binary(u), do: u
  defp presence_label(uid, _), do: String.slice(uid, 0, 8) <> "…"

  # True when any of the member's presence metas marks them as currently in
  # the LiveKit video room.
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

  # Re-fetch the user from the database so that a ban issued mid-session
  # cannot keep the LiveView acting on behalf of an authorised user.
  # `socket.assigns.current_user` was populated at socket-connect time
  # from the cookie token and is not refreshed by `assign_new` callbacks
  # on every event. This helper is the per-event guard called from
  # `handle_event/3` for any mutating action.
  #
  # Returns `{:ok, %User{}}` for an active user, or `{:error, reason}` if
  # the user no longer exists, has been banned, or the room access check
  # now fails (e.g. paid subscription expired mid-session).
  #
  # See SECURITY_REVIEW.md P1 #7.
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
        |> put_flash(:error, "Your account is no longer authorised to perform this action.")
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
        socket
        |> put_flash(:error, "Action not permitted.")
    end
  end
end
