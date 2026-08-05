defmodule BeamChatWeb.ChatLive.Private do
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
     |> assign(:page_title, "Messages")
     |> assign(:conversation, nil)
     |> assign(:other_user, nil)
     |> assign(:conversation_rows, [])
     |> assign(:inbox_meta, %{
       total_count: 0,
       page: 1,
       limit: 30,
       page_count: 1
     })
     |> assign(:compose_form, to_form(%{"user_id" => ""}, as: :compose))
     |> assign(:message_form, to_form(%{"content" => ""}, as: :message))
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

    result =
      Direct.list_conversations_for(socket.assigns.current_user, %{
        page: params["page"]
      })

    socket
    |> assign(:page_title, "Direct messages")
    |> assign(:conversation_rows, result.rows)
    |> assign(:inbox_meta, Map.take(result, [:total_count, :page, :limit, :page_count]))
    |> assign(:conversation, nil)
    |> assign(:other_user, nil)
    |> assign(:topic, nil)
    |> stream(:messages, [], reset: true)
  end

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
      |> assign(:page_title, "Chat with #{other && other.username}")
      |> assign(:conversation, conv)
      |> assign(:other_user, other)
      |> assign(:message_form, message_form)
      |> assign(:topic, Direct.topic(conv.id))
      |> stream(:messages, messages, dom_id: &dm_dom_id/1, reset: true)

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
      {:noreply, stream_insert(socket, :messages, msg)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("open_compose", %{"compose" => %{"user_id" => user_id}}, socket) do
    user_id = String.trim(user_id)

    with true <- user_id != "",
         other when not is_nil(other) <- Repo.get(User, user_id),
         true <- other.id != socket.assigns.current_user.id do
      conv = Direct.get_or_create_conversation!(socket.assigns.current_user, other)
      {:noreply, push_navigate(socket, to: ~p"/messages/#{conv.id}")}
    else
      _ ->
        {:noreply,
         put_flash(socket, :error, "Enter another member’s user id (UUID) to start chatting.")}
    end
  end

  def handle_event("send_dm", %{"message" => %{"content" => content}}, socket) do
    conv = socket.assigns.conversation
    user = socket.assigns.current_user

    case Direct.send_message(conv.id, user.id, content) do
      {:error, {:blocked, reason}} ->
        {:noreply, put_flash(socket, :error, "Message blocked: #{reason}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not send that message.")}

      {:ok, _row} ->
        {:noreply, assign(socket, :message_form, to_form(%{"content" => ""}, as: :message))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= case @live_action do %>
      <% :index -> %>
        <div class="space-y-6">
          <div class="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <h1 class="font-display text-2xl font-semibold tracking-tight text-base-content">
                Direct messages
              </h1>

              <p class="text-sm text-base-content/70 mt-1">
                Private 1:1 threads — persisted to your conversations.
              </p>
            </div>

            <.link navigate={~p"/rooms"} class="btn btn-ghost btn-sm" id="nav-rooms-from-dm">
              Rooms
            </.link>
          </div>

          <div class="rounded-box border border-base-300 bg-base-200/30 p-4 space-y-3">
            <h2 class="text-sm font-semibold text-base-content">Start a conversation</h2>

            <p class="text-xs text-base-content/65">
              Paste another member’s user id (UUID from profile/admin tools). A richer people picker
              ships later.
            </p>

            <.form
              for={@compose_form}
              id="dm-compose-form"
              phx-submit="open_compose"
              class="flex flex-col sm:flex-row gap-2 sm:items-end"
            >
              <.input
                field={@compose_form[:user_id]}
                type="text"
                label="User id"
                placeholder="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
                class="input input-bordered flex-1 font-mono text-sm"
              />
              <button type="submit" class="btn btn-primary btn-sm" id="dm-compose-submit">
                Open chat
              </button>
            </.form>
          </div>

          <div :if={@conversation_rows == []} class="text-sm text-base-content/60 py-8 text-center">
            No conversations yet — start one above.
          </div>

          <ul :if={@conversation_rows != []} class="space-y-2" id="conversation-list">
            <li :for={{conv, other, last} <- @conversation_rows} id={"conv-row-" <> conv.id}>
              <.link
                navigate={~p"/messages/#{conv.id}"}
                class="block rounded-box border border-base-300 bg-base-100 p-4 hover:border-primary/40 motion-safe:transition-colors"
              >
                <div class="flex justify-between gap-2">
                  <span class="font-medium text-base-content">
                    {(other && other.username) || "Unknown user"}
                  </span>
                  <span :if={last} class="text-xs text-base-content/50">
                    {Calendar.strftime(last.inserted_at, "%d %b %H:%M")}
                  </span>
                </div>

                <p :if={last} class="text-sm text-base-content/70 truncate mt-1">{last.content}</p>
              </.link>
            </li>
          </ul>

          <div
            :if={@inbox_meta.total_count > @inbox_meta.limit}
            class="flex flex-wrap items-center justify-center gap-3 pt-4 text-sm text-base-content/70"
          >
            <span>
              Page {@inbox_meta.page} of {@inbox_meta.page_count}
              <span class="text-base-content/50">({@inbox_meta.total_count} conversations)</span>
            </span>
            <div class="flex gap-2">
              <.link
                :if={@inbox_meta.page > 1}
                patch={~p"/messages?#{dm_inbox_page_params(@inbox_meta.page - 1)}"}
                class="btn btn-sm btn-ghost"
                id="dm-inbox-prev"
              >
                Previous
              </.link>
              <.link
                :if={@inbox_meta.page < @inbox_meta.page_count}
                patch={~p"/messages?#{dm_inbox_page_params(@inbox_meta.page + 1)}"}
                class="btn btn-sm btn-ghost"
                id="dm-inbox-next"
              >
                Next
              </.link>
            </div>
          </div>
        </div>
      <% :show -> %>
        <div class="space-y-4" id="dm-thread">
          <div class="flex flex-wrap items-center gap-2">
            <.link navigate={~p"/messages"} class="btn btn-ghost btn-sm" id="back-to-inbox">
              ← Inbox
            </.link>
            <h1 class="font-display text-xl font-semibold">{@other_user && @other_user.username}</h1>
          </div>

          <section class="rounded-box border border-base-300 bg-base-100 flex flex-col min-h-[24rem]">
            <div
              id="dm-scroll"
              phx-hook="ChatScroll"
              phx-update="stream"
              class="flex-1 overflow-y-auto px-4 py-3 space-y-3"
            >
              <div
                id="dm-messages-empty"
                class="hidden only:block text-sm text-base-content/60 text-center py-10"
              >
                No messages yet.
              </div>

              <div :for={{mid, msg} <- @streams.messages} id={mid} class="text-sm flex gap-2">
                <span class="w-24 shrink-0 text-xs text-base-content/55 truncate">
                  {msg.sender && msg.sender.username}
                </span>
                <p class="flex-1 whitespace-pre-wrap break-words">{msg.content}</p>
              </div>
            </div>

            <.form
              for={@message_form}
              id="dm-message-form"
              phx-submit="send_dm"
              class="border-t border-base-300 p-3 flex gap-2"
            >
              <.input
                field={@message_form[:content]}
                type="textarea"
                class="textarea textarea-bordered flex-1 min-h-[3rem]"
                placeholder="Write a direct message…"
                rows="2"
              /> <button type="submit" class="btn btn-primary self-end" id="send-dm">Send</button>
            </.form>
          </section>
        </div>
    <% end %>
    """
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
