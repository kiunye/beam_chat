defmodule BeamChatWeb.ChatLive.Private do
  @moduledoc """
  Direct messages: the DM inbox (/messages) and a 1:1 thread view
  (/messages/:id) for any pair of members.

  The v2 app shell (sidebar + flash group) is provided by the layout —
  this LiveView renders page content only and marks the Messages nav
  entry active. Conversation listing is paginated and batch-loaded via
  `BeamChat.Direct`; threads stream over PubSub with the ChatScroll hook
  keeping the pane pinned to the newest message.
  """

  use BeamChatWeb, :live_view

  alias BeamChat.Accounts.User
  alias BeamChat.Direct
  alias BeamChat.Direct.DirectMessage
  alias BeamChat.Repo

  # Per-user limit for thread GETs (`/messages/:id`). The URL is a UUID, so
  # the attack surface is tiny in theory — but an attacker who has learned
  # a UUID (e.g. from a leaked log) can otherwise enumerate by hammering
  # the endpoint and watching the flash string. 60 requests / minute gives
  # plenty of headroom for normal use (refresh, multiple tabs, mobile
  # reconnect) while making mass-enumeration uneconomic.
  #
  # See SECURITY_REVIEW.md P1 #11.
  @thread_view_limit 60
  @thread_view_period_ms :timer.minutes(1)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_nav, :messages)
     |> assign(:page_title, "Messages")
     |> assign(:conversation, nil)
     |> assign(:other_user, nil)
     |> assign(:unread_count, 0)
     |> assign(:inbox_meta, %{
       total_count: 0,
       page: 1,
       limit: 30,
       page_count: 1
     })
     |> assign(:compose_form, to_form(%{"user_id" => ""}, as: :compose))
     |> assign(:message_form, to_form(%{"content" => ""}, as: :message))
     |> stream(:conversations, [], reset: true)
     |> stream(:messages, [], reset: true)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :index -> {:noreply, assign_inbox(socket, params)}
      :show -> {:noreply, handle_show(socket, params)}
    end
  end

  defp handle_show(socket, params) do
    case thread_view_allowed?(socket.assigns.current_user) do
      :ok -> assign_thread(socket, params["id"])
      {:error, _} -> reject_rate_limited(socket)
    end
  end

  defp assign_inbox(socket, params) do
    socket = unsubscribe_if_direct_subscribed(socket)
    user = socket.assigns.current_user

    result = Direct.list_conversations_for(user, %{page: params["page"]})

    rows =
      Enum.map(result.rows, fn {conv, other, last} ->
        %{id: conv.id, other_user: other, last_message: last}
      end)

    socket
    |> assign(:page_title, "Direct messages")
    |> assign(:unread_count, Direct.unread_count(user.id))
    |> assign(:inbox_meta, Map.take(result, [:total_count, :page, :limit, :page_count]))
    |> assign(:conversation, nil)
    |> assign(:other_user, nil)
    |> assign(:topic, nil)
    |> stream(:conversations, rows, dom_id: &inbox_row_dom_id/1, reset: true)
    |> stream(:messages, [], reset: true)
  end

  defp inbox_row_dom_id(%{id: id}), do: "conv-row-#{id}"

  defp assign_thread(socket, id) do
    case Direct.get_conversation(id) do
      nil ->
        socket
        |> put_flash(:error, "Conversation not found.")
        |> push_navigate(to: ~p"/messages")

      conv ->
        assign_thread_for_conversation(socket, conv)
    end
  end

  defp assign_thread_for_conversation(socket, conv) do
    user = socket.assigns.current_user

    if Direct.participant?(conv, user.id) do
      mount_participant_thread(socket, conv, user)
    else
      socket
      |> put_flash(:error, "You are not part of this conversation.")
      |> push_navigate(to: ~p"/messages")
    end
  end

  defp mount_participant_thread(socket, conv, %User{} = user) do
    socket = unsubscribe_if_direct_subscribed(socket)

    other_id = if conv.user_low_id == user.id, do: conv.user_high_id, else: conv.user_low_id
    other = Repo.get(User, other_id)
    messages = Direct.list_messages(conv.id)
    message_form = to_form(%{"content" => ""}, as: :message)

    socket =
      socket
      |> assign(:page_title, "Chat with " <> sender_label(other))
      |> assign(:conversation, conv)
      |> assign(:other_user, other)
      |> assign(:message_form, message_form)
      |> assign(:topic, Direct.topic(conv.id))
      |> stream(:messages, messages, dom_id: &dm_dom_id/1, reset: true)

    # The thread is being shown — flip the other participant's unread
    # messages to read so the inbox unread count stays honest.
    Direct.mark_conversation_read(conv, user.id)

    socket =
      if connected?(socket) do
        Direct.subscribe(conv.id)
        socket
      else
        socket
      end

    socket
  end

  defp unsubscribe_if_direct_subscribed(socket) do
    if connected?(socket) do
      case socket.assigns[:conversation] do
        %{id: id} when is_binary(id) -> Direct.unsubscribe(id)
        _ -> :ok
      end
    end

    socket
  end

  defp dm_dom_id(%DirectMessage{id: id, inserted_at: at}) do
    "dm-#{id}-#{DateTime.to_iso8601(at)}"
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:conversation] && socket.assigns[:topic] do
      Direct.unsubscribe(socket.assigns.conversation.id)
    end

    :ok
  end

  @impl true
  def handle_info({:new_direct_message, %DirectMessage{} = msg}, socket) do
    if socket.assigns[:conversation] && msg.conversation_id == socket.assigns.conversation.id do
      # A message from the other participant is being displayed live on
      # an open thread — mark the thread read so it never shows up as
      # unread in the inbox afterwards.
      if msg.sender_id != socket.assigns.current_user.id do
        Direct.mark_conversation_read(socket.assigns.conversation, socket.assigns.current_user.id)
      end

      {:noreply, stream_insert(socket, :messages, msg)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("open_compose", %{"compose" => %{"user_id" => user_id}}, socket) do
    user_id = String.trim(user_id)

    # `Ecto.UUID.cast/1` guards the lookup: `Repo.get(User, "not-a-uuid")`
    # would raise `Ecto.Query.CastError` on a binary_id primary key, so
    # free-form input must be cast first (same pattern as
    # `Direct.get_conversation/1`).
    with {:ok, user_id} <- Ecto.UUID.cast(user_id),
         %User{} = other <- Repo.get(User, user_id),
         true <- other.id != socket.assigns.current_user.id do
      conv = Direct.get_or_create_conversation!(socket.assigns.current_user, other)

      {:noreply, push_patch(socket, to: ~p"/messages/#{conv.id}")}
    else
      :error ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "That doesn't look like a user id — paste the member's UUID (e.g. from their profile)."
         )}

      nil ->
        {:noreply, put_flash(socket, :error, "No member found with that user id.")}

      false ->
        {:noreply, put_flash(socket, :error, "You can't start a conversation with yourself.")}

      _ ->
        {:noreply,
         put_flash(socket, :error, "Enter another member's user id (UUID) to start chatting.")}
    end
  end

  def handle_event("send_dm", %{"message" => %{"content" => content}}, socket) do
    conv = socket.assigns.conversation
    user = socket.assigns.current_user

    case Direct.send_message(conv.id, user.id, content) do
      {:ok, _row} ->
        {:noreply, assign(socket, :message_form, to_form(%{"content" => ""}, as: :message))}

      {:error, {:blocked, reason}} ->
        {:noreply, put_flash(socket, :error, "Message blocked: #{reason}")}

      {:error, :banned} ->
        {:noreply,
         put_flash(socket, :error, "Your account is banned and can no longer send messages.")}

      {:error, :not_participant} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You are no longer a participant in this conversation."
         )}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "This conversation no longer exists.")}

      {:error, :empty_content} ->
        {:noreply, put_flash(socket, :error, "Type a message first.")}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, "Could not send that message.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= case @live_action do %>
      <% :index -> %>
        <div class="space-y-5" id="dm-inbox">
          <header class="flex flex-wrap items-end justify-between gap-3" id="dm-inbox-header">
            <div class="space-y-1">
              <h1 class="text-headline-lg tracking-tight" id="dm-inbox-title">Direct messages</h1>
              <p class="text-sm text-base-content/60">
                Private 1:1 conversations, delivered live.
              </p>
            </div>

            <span
              :if={@unread_count > 0}
              class="beam-chip"
              data-state="on"
              id="dm-unread-chip"
            >
              <span class="size-1.5 rounded-full bg-primary" />
              {@unread_count} unread
            </span>
          </header>

          <section
            class="card bg-white border border-base-300 shadow-panel rounded-box p-4 sm:p-5"
            id="dm-compose"
          >
            <h2 class="text-headline-sm flex items-center gap-2">
              <.icon name="hero-user-plus" class="size-4 text-primary" /> Start a conversation
            </h2>
            <p class="mt-1 text-sm text-base-content/60">
              Paste another member's user id (the UUID from their profile) to open — or reopen — a private thread.
            </p>

            <.form
              for={@compose_form}
              id="dm-compose-form"
              phx-submit="open_compose"
              class="mt-4 flex flex-col gap-3 sm:flex-row sm:items-end"
            >
              <div class="flex-1">
                <.input
                  field={@compose_form[:user_id]}
                  type="text"
                  label="Member user id"
                  placeholder="00000000-0000-0000-0000-000000000000"
                  autocomplete="off"
                  class="input input-primary w-full font-mono text-sm"
                />
              </div>
              <button type="submit" class="btn btn-primary gap-2 sm:mb-2" id="dm-compose-submit">
                Open chat <.icon name="hero-paper-airplane" class="size-4" />
              </button>
            </.form>
          </section>

          <ul class="space-y-2" id="conversation-list" phx-update="stream" role="list">
            <li id="conversation-list-empty" class="hidden only:block">
              <div class="card bg-white border border-base-300 shadow-panel rounded-box flex flex-col items-center gap-2 px-6 py-12 text-center">
                <.icon
                  name="hero-chat-bubble-left-ellipsis"
                  class="size-8 text-base-content/30"
                />
                <p class="text-headline-sm">No conversations yet</p>
                <p class="text-sm text-base-content/60">
                  Start a private thread with the form above.
                </p>
              </div>
            </li>

            <li :for={{cid, row} <- @streams.conversations} id={cid}>
              <.link
                navigate={~p"/messages/#{row.id}"}
                id={"conv-link-" <> row.id}
                class="group flex items-center gap-3 rounded-box border border-base-300 bg-white p-4 shadow-panel transition duration-200 hover:border-primary/40 hover:shadow-raised"
              >
                <span class="flex size-10 shrink-0 items-center justify-center rounded-full bg-base-200 text-sm font-semibold uppercase text-base-content/70">
                  {Layouts.initials(row.other_user)}
                </span>

                <span class="min-w-0 flex-1">
                  <span class="flex items-baseline justify-between gap-2">
                    <span class="truncate font-medium">{sender_label(row.other_user)}</span>
                    <span
                      :if={row.last_message}
                      class="tnum text-label-sm whitespace-nowrap text-base-content/50"
                    >
                      {relative_time(row.last_message.inserted_at)}
                    </span>
                  </span>
                  <span class="mt-0.5 block truncate text-sm text-base-content/60">
                    {last_message_preview(row.last_message, @current_user.id)}
                  </span>
                </span>

                <.icon
                  name="hero-chevron-right"
                  class="size-4 shrink-0 text-base-content/30 transition group-hover:translate-x-0.5 group-hover:text-primary"
                />
              </.link>
            </li>
          </ul>

          <div
            :if={@inbox_meta.total_count > @inbox_meta.limit}
            class="flex flex-wrap items-center justify-between gap-3 pt-1"
            id="dm-inbox-pagination"
          >
            <p class="text-sm text-base-content/60">
              Page {@inbox_meta.page} of {@inbox_meta.page_count}
              <span class="text-base-content/40">· {@inbox_meta.total_count} conversations</span>
            </p>
            <div class="flex gap-2">
              <.link
                :if={@inbox_meta.page > 1}
                patch={~p"/messages?#{dm_inbox_page_params(@inbox_meta.page - 1)}"}
                class="btn btn-outline btn-sm gap-2"
                id="dm-inbox-prev"
              >
                <.icon name="hero-chevron-left" class="size-4" /> Previous
              </.link>
              <.link
                :if={@inbox_meta.page < @inbox_meta.page_count}
                patch={~p"/messages?#{dm_inbox_page_params(@inbox_meta.page + 1)}"}
                class="btn btn-outline btn-sm gap-2"
                id="dm-inbox-next"
              >
                Next <.icon name="hero-chevron-right" class="size-4" />
              </.link>
            </div>
          </div>
        </div>
      <% :show -> %>
        <div class="flex flex-col gap-4" id="dm-thread">
          <header class="flex flex-wrap items-center gap-3" id="dm-thread-header">
            <.link navigate={~p"/messages"} class="btn btn-ghost btn-sm gap-2" id="back-to-inbox">
              <.icon name="hero-arrow-left" class="size-4" /> Inbox
            </.link>

            <span class="flex size-10 shrink-0 items-center justify-center rounded-full bg-base-200 text-sm font-semibold uppercase text-base-content/70">
              {Layouts.initials(@other_user)}
            </span>

            <div class="min-w-0">
              <h1 class="text-headline-md tracking-tight truncate">{sender_label(@other_user)}</h1>
              <p class="text-label-sm text-base-content/50" id="dm-thread-status">
                Private conversation · synced live
              </p>
            </div>
          </header>

          <section
            class="card bg-white border border-base-300 shadow-panel rounded-box flex flex-col min-h-[30rem] overflow-hidden"
            id="dm-thread-panel"
          >
            <div
              class="flex-1 space-y-3 overflow-y-auto scroll-smooth px-4 py-4"
              id="chat-scroll"
              phx-hook="ChatScroll"
              phx-update="stream"
            >
              <div
                id="dm-messages-empty"
                class="hidden only:block py-12 text-center text-sm text-base-content/50"
              >
                No messages yet — say hello.
              </div>

              <div
                :for={{mid, msg} <- @streams.messages}
                id={mid}
                class={["flex", msg.sender_id == @current_user.id && "justify-end"]}
              >
                <div class={[
                  "flex max-w-[85%] flex-col",
                  msg.sender_id == @current_user.id && "items-end"
                ]}>
                  <div class={[
                    "whitespace-pre-wrap break-words rounded-2xl px-3.5 py-2 text-sm",
                    msg.sender_id == @current_user.id &&
                      "rounded-br-md bg-primary text-primary-content",
                    msg.sender_id != @current_user.id &&
                      "rounded-bl-md bg-base-200 text-base-content"
                  ]}>
                    {msg.content}
                  </div>
                  <span class="tnum text-label-sm mt-1 px-1 text-base-content/40">
                    {Calendar.strftime(msg.inserted_at, "%H:%M")}
                  </span>
                </div>
              </div>
            </div>

            <.form
              for={@message_form}
              id="dm-message-form"
              phx-submit="send_dm"
              phx-hook=".DmComposerSubmit"
              class="flex items-end gap-2 border-t border-base-300 bg-white p-3"
            >
              <.input
                field={@message_form[:content]}
                type="textarea"
                class="textarea textarea-primary w-full flex-1 min-h-[3.25rem] resize-none"
                placeholder={"Message " <> sender_label(@other_user)}
                rows="2"
                autocomplete="off"
              />
              <button
                type="submit"
                class="btn btn-primary mb-2 gap-2 phx-submit-loading:pointer-events-none phx-submit-loading:opacity-60"
                id="send-dm"
              >
                <.icon
                  name="hero-paper-airplane"
                  class="size-4 phx-submit-loading:hidden"
                />
                <.icon
                  name="hero-arrow-path"
                  class="size-4 hidden motion-safe:animate-spin phx-submit-loading:block"
                /> Send
              </button>
            </.form>
          </section>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".DmComposerSubmit">
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
    <% end %>
    """
  end

  # Display helpers shared by the inbox rows and the thread header.

  defp sender_label(nil), do: "Unknown user"

  defp sender_label(%{full_name: name}) when is_binary(name) and name != "", do: name

  defp sender_label(%{username: u}), do: "@#{u || "unknown"}"

  # Inbox preview line: prefixes own last messages with "You: " so the
  # sender is unambiguous at a glance.
  defp last_message_preview(nil, _current_user_id), do: "No messages yet"

  defp last_message_preview(
         %DirectMessage{sender_id: sender_id, content: content},
         current_user_id
       ) do
    if sender_id == current_user_id, do: "You: " <> (content || ""), else: content || ""
  end

  # Compact relative time for inbox rows — stdlib only, recomputed on
  # every inbox render so it never goes too stale.
  defp relative_time(%DateTime{} = at) do
    seconds_ago = DateTime.diff(DateTime.utc_now(), at, :second)

    cond do
      seconds_ago < 60 -> "just now"
      seconds_ago < 3600 -> "#{div(seconds_ago, 60)}m ago"
      seconds_ago < 86_400 -> "#{div(seconds_ago, 3600)}h ago"
      seconds_ago < 604_800 -> "#{div(seconds_ago, 86_400)}d ago"
      true -> Calendar.strftime(at, "%d %b")
    end
  end

  defp dm_inbox_page_params(page) when page > 1, do: %{"page" => Integer.to_string(page)}
  defp dm_inbox_page_params(_page), do: %{}

  # Returns `:ok` if the user is under the per-minute thread-view limit,
  # `{:error, :rate_limited}` otherwise. We use an ETS table keyed by user
  # id to keep the counter out of the database — acceptable because we are
  # bounding *attempts*, not aggregating *quota*, and a small over-count
  # is harmless.
  @table :beam_chat_dm_thread_rate

  defp thread_view_allowed?(%User{id: uid}) do
    ensure_table!()

    now = System.monotonic_time(:millisecond)
    key = {uid, now}
    cutoff = now - @thread_view_period_ms

    :ets.insert(@table, {key, now})
    prune_older_than(uid, cutoff)

    case count_in_window(uid, cutoff) do
      n when n > @thread_view_limit -> {:error, :rate_limited}
      _ -> :ok
    end
  end

  defp thread_view_allowed?(nil), do: {:error, :no_user}

  defp ensure_table! do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
    end

    :ok
  end

  defp prune_older_than(uid, cutoff) do
    match_spec = [{{{:"$1", :"$2"}, :_}, [{:==, :"$1", uid}, {:<, :"$2", cutoff}], [true]}]
    :ets.select_delete(@table, match_spec)
  end

  defp count_in_window(uid, cutoff) do
    match_spec = [{{{:"$1", :"$2"}, :_}, [{:==, :"$1", uid}, {:>=, :"$2", cutoff}], [true]}]
    :ets.select_count(@table, match_spec)
  end

  defp reject_rate_limited(socket) do
    socket
    |> put_flash(:error, "You're loading that conversation too quickly. Try again in a moment.")
    |> push_navigate(to: ~p"/messages")
  end
end
