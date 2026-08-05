defmodule BeamChat.Direct do
  @moduledoc """
  Direct conversations and messages (1:1).

  ## Security — UUID-entropy assumption (SECURITY_REVIEW.md P1 #11)

  The DM topic key is the conversation UUID (`conversation:<uuid>`).
  Anyone who knows the UUID of a conversation they are not a participant
  of can subscribe to that PubSub topic and receive the message stream.

  `ChatLive.Private.assign_thread/2` enforces `Direct.participant?/2` at
  mount time, so the application surface is safe — but the underlying
  PubSub topic is not access-controlled.

  We rely on the **unguessability of conversation UUIDs** (UUIDv4 —
  122 bits of entropy) as the security boundary for this. Operators and
  contributors must:

    - Not weaken the UUID shape (do not switch to sequential or otherwise
      enumerable identifiers).
    - Not log conversation UUIDs at INFO level or higher.
    - Not include conversation UUIDs in URLs that are sent off-platform
      (e.g. email notifications) without an additional auth check.

  Defence in depth: per-user rate limiting on `/messages/:id` is enforced
  by `BeamChatWeb.ChatLive.Private.handle_show/2` to bound enumeration
  attempts.
  """

  import Ecto.Query

  alias BeamChat.Accounts.User
  alias BeamChat.Direct.Conversation
  alias BeamChat.Direct.DirectMessage
  alias BeamChat.Messages.Persister
  alias BeamChat.Messages.Validator
  alias BeamChat.Moderation.RuleEngine
  alias BeamChat.Pagination
  alias BeamChat.Repo

  @topic_prefix "conversation:"

  def topic(conversation_id), do: @topic_prefix <> conversation_id

  def subscribe(conversation_id) do
    Phoenix.PubSub.subscribe(BeamChat.PubSub, topic(conversation_id))
  end

  def unsubscribe(conversation_id) do
    Phoenix.PubSub.unsubscribe(BeamChat.PubSub, topic(conversation_id))
  end

  @spec broadcast_new_message(DirectMessage.t()) :: :ok
  def broadcast_new_message(%DirectMessage{} = msg) do
    Phoenix.PubSub.broadcast(
      BeamChat.PubSub,
      topic(msg.conversation_id),
      {:new_direct_message, msg}
    )
  end

  @doc """
  Lists conversations for a user with the other participant and last message loaded.

  Uses a constant number of queries (conversations, batch users, batch last messages)
  instead of N+1 per conversation.

  Returns a map with `:rows`, `:total_count`, `:page`, `:limit`, and `:page_count` for
  server-side pagination (same shape as `BeamChat.Rooms.list_rooms_for_index/2`).
  """
  def list_conversations_for(%User{id: user_id}, opts \\ %{}) do
    limit = Pagination.normalize_limit(Map.get(opts, :limit), 30)
    page = Pagination.normalize_page(Map.get(opts, :page))
    offset = (page - 1) * limit

    base =
      from(c in Conversation,
        where: c.user_low_id == ^user_id or c.user_high_id == ^user_id
      )

    convs =
      from(c in base,
        order_by: [desc: c.inserted_at],
        limit: ^limit,
        offset: ^offset
      )
      |> Repo.all()

    total = Repo.aggregate(base, :count, :id)

    rows =
      case convs do
        [] -> []
        [_ | _] -> conversation_inbox_rows(convs, user_id)
      end

    %{
      rows: rows,
      total_count: total,
      page: page,
      limit: limit,
      page_count: Pagination.page_count(total, limit)
    }
  end

  defp conversation_inbox_rows(convs, user_id) do
    other_ids =
      convs
      |> Enum.map(&other_participant_id(&1, user_id))
      |> Enum.uniq()

    users_by_id =
      from(u in User, where: u.id in ^other_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    conv_ids = Enum.map(convs, & &1.id)
    last_by_conv = last_messages_by_conversation_ids(conv_ids)

    Enum.map(convs, fn c ->
      oid = other_participant_id(c, user_id)
      {c, Map.get(users_by_id, oid), Map.get(last_by_conv, c.id)}
    end)
  end

  defp other_participant_id(%Conversation{} = c, user_id) do
    if c.user_low_id == user_id, do: c.user_high_id, else: c.user_low_id
  end

  defp last_messages_by_conversation_ids([]) do
    %{}
  end

  defp last_messages_by_conversation_ids(conv_ids) do
    from(m in DirectMessage,
      where: m.conversation_id in ^conv_ids and m.is_deleted == false,
      distinct: [asc: m.conversation_id],
      order_by: [asc: m.conversation_id, desc: m.inserted_at],
      preload: [:sender]
    )
    |> Repo.all()
    |> Map.new(&{&1.conversation_id, &1})
  end

  def get_conversation!(id) do
    Repo.get!(Conversation, id)
  end

  def get_conversation(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Conversation, uuid)
      :error -> nil
    end
  end

  def participant?(%Conversation{} = c, user_id) do
    user_id in [c.user_low_id, c.user_high_id]
  end

  def get_or_create_conversation!(%User{id: a}, %User{id: b}) when a != b do
    {low, high} = Conversation.ordered_pair(a, b)

    case Repo.get_by(Conversation, user_low_id: low, user_high_id: high) do
      %Conversation{} = c ->
        c

      nil ->
        {:ok, c} =
          %Conversation{}
          |> Conversation.changeset(%{user_low_id: low, user_high_id: high})
          |> Repo.insert()

        c
    end
  end

  def list_messages(conversation_id, limit \\ 200) do
    from(m in DirectMessage,
      where: m.conversation_id == ^conversation_id and m.is_deleted == false,
      order_by: [asc: m.inserted_at],
      limit: ^limit,
      preload: [:sender]
    )
    |> Repo.all()
  end

  @doc """
  Validates, moderates, persists and broadcasts a direct message synchronously.

  Returns `{:ok, %DirectMessage{}}` (already broadcast on
  `Direct.topic(conversation_id)`) or `{:error, reason}` where `reason` is
  `:empty_content`, `{:blocked, reason}` (moderation rejection), a validator
  error atom, or `{:persist_failed, reason}`.
  """
  @spec send_message(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, DirectMessage.t()} | {:error, term()}
  def send_message(conversation_id, sender_id, content)
      when is_binary(conversation_id) and is_binary(sender_id) do
    trimmed = String.trim(content || "")

    if trimmed == "" do
      {:error, :empty_content}
    else
      message = %{
        kind: :direct,
        conversation_id: conversation_id,
        user_id: sender_id,
        content: trimmed,
        inserted_at: nil
      }

      dispatch_after_moderation(message)
    end
  end

  defp dispatch_after_moderation(data) do
    with {:ok, validated} <- Validator.validate(data) do
      case RuleEngine.apply_rules(validated) do
        {:blocked, _msg, reason} -> {:error, {:blocked, reason}}
        {:flagged, msg, _reason} -> persist_dm_message(msg)
        msg when is_map(msg) -> persist_dm_message(msg)
      end
    end
  end

  defp persist_dm_message(data) do
    case Persister.persist_ordered([data]) do
      [{:ok, %DirectMessage{} = row}] ->
        row = Repo.preload(row, :sender)
        broadcast_new_message(row)

        :telemetry.execute(
          [:beam_chat, :message_pipeline, :persisted],
          %{count: 1, failed_count: 0},
          %{}
        )

        {:ok, row}

      [{:error, reason} | _] ->
        :telemetry.execute(
          [:beam_chat, :message_pipeline, :failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        {:error, {:persist_failed, reason}}
    end
  end
end
