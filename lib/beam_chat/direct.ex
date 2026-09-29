defmodule BeamChat.Direct do
  @moduledoc """
  Direct conversations and messages (1:1).

  A conversation is identified by the ordered pair of its two
  participants, so the same two users always land in the same
  conversation regardless of who started it, and a user cannot open a
  conversation with themselves (PRD §2.5). Sends follow the same single
  pipeline as room messages: fresh ban check, participant check, content
  validation, moderation with same-operation logging, synchronous
  persist, broadcast.

  ## Security — UUID-entropy assumption

  The DM topic key is the conversation UUID (`conversation:<uuid>`).
  Anyone who knows the UUID of a conversation they are not a participant
  of can subscribe to that PubSub topic and receive the message stream.
  `ChatLive.Private` enforces `Direct.participant?/2` at mount time, so
  the application surface is safe — but the underlying PubSub topic is
  not access-controlled. We rely on the unguessability of UUIDv4
  conversation ids as the boundary, and per-user rate limiting on
  `/messages/:id` bounds enumeration attempts.
  """

  import Ecto.Query

  alias BeamChat.Accounts
  alias BeamChat.Accounts.User
  alias BeamChat.Direct.Conversation
  alias BeamChat.Direct.DirectMessage
  alias BeamChat.Messages.Pipeline
  alias BeamChat.Messages.Validator
  alias BeamChat.Pagination
  alias BeamChat.PubSub
  alias BeamChat.Repo

  @topic_prefix "conversation:"

  def topic(conversation_id), do: @topic_prefix <> conversation_id

  def subscribe(conversation_id) do
    Phoenix.PubSub.subscribe(PubSub, topic(conversation_id))
  end

  def unsubscribe(conversation_id) do
    Phoenix.PubSub.unsubscribe(PubSub, topic(conversation_id))
  end

  @spec broadcast_new_message(DirectMessage.t()) :: :ok
  def broadcast_new_message(%DirectMessage{} = msg) do
    Phoenix.PubSub.broadcast(PubSub, topic(msg.conversation_id), {:new_direct_message, msg})
    :ok
  end

  @doc """
  Lists conversations for a user with the other participant and last
  message loaded. Uses a constant number of queries (conversations, batch
  users, batch last messages) instead of N+1 per conversation. Returns a
  map with `:rows`, `:total_count`, `:page`, `:limit`, and `:page_count`.
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

  def get_conversation!(id), do: Repo.get!(Conversation, id)

  def get_conversation(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Conversation, uuid)
      :error -> nil
    end
  end

  def participant?(%Conversation{} = c, user_id) do
    is_binary(user_id) and user_id in [c.user_low_id, c.user_high_id]
  end

  @doc """
  Gets (or creates) the one conversation for this pair. The ordered-pair
  normalization makes (A,B) and (B,A) resolve to the same row; the unique
  index is the hard guarantee, so a concurrent insert race is retried
  rather than raised.
  """
  def get_or_create_conversation!(%User{id: a}, %User{id: b}) when a != b do
    {low, high} = Conversation.ordered_pair(a, b)

    case Repo.get_by(Conversation, user_low_id: low, user_high_id: high) do
      %Conversation{} = c ->
        c

      nil ->
        insert_conversation!(low, high)
    end
  end

  defp insert_conversation!(low, high) do
    %Conversation{}
    |> Conversation.changeset(%{user_low_id: low, user_high_id: high})
    |> Repo.insert()
    |> case do
      {:ok, c} ->
        c

      {:error, %Ecto.Changeset{errors: errors}} ->
        retry_conversation_insert!(errors, low, high)
    end
  end

  # A concurrent insert race is retried rather than raised; any other
  # changeset error is not recoverable here.
  defp retry_conversation_insert!(errors, low, high) do
    if unique_pair_violation?(errors) do
      Repo.get_by!(Conversation, user_low_id: low, user_high_id: high)
    else
      raise Ecto.InvalidChangesetError, action: :insert, changeset: %{errors: errors}
    end
  end

  defp unique_pair_violation?(errors) do
    Enum.any?(errors, fn
      {:user_low_id, {_, [constraint: :unique, constraint_name: _]}} -> true
      _ -> false
    end)
  end

  @doc """
  The conversation's most recent messages, returned oldest-first for
  display-order streaming.
  """
  def list_messages(conversation_id, limit \\ 200) when is_integer(limit) and limit > 0 do
    from(m in DirectMessage,
      where: m.conversation_id == ^conversation_id and m.is_deleted == false,
      order_by: [desc: m.inserted_at, desc: m.id],
      limit: ^limit,
      preload: [:sender]
    )
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc """
  Marks every message from the other participant as read (batch update).
  """
  def mark_conversation_read(%Conversation{} = conversation, user_id) do
    other_id = other_participant_id(conversation, user_id)

    from(m in DirectMessage,
      where:
        m.conversation_id == ^conversation.id and m.sender_id == ^other_id and
          m.is_read == false and m.is_deleted == false
    )
    |> Repo.update_all(set: [is_read: true])
  end

  @doc "How many unread DMs the user has across all conversations."
  @spec unread_count(Ecto.UUID.t()) :: non_neg_integer()
  def unread_count(user_id) do
    from(m in DirectMessage,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where:
        m.is_read == false and m.is_deleted == false and m.sender_id != ^user_id and
          (c.user_low_id == ^user_id or c.user_high_id == ^user_id),
      select: count(m.id)
    )
    |> Repo.one()
  end

  @doc """
  Sends a DM along the single send path: fresh ban check on the sender,
  participant check, content validation, moderation (with same-operation
  logging), synchronous persist, broadcast. A blocked message is rejected
  with the reason shown to the sender; a flagged message is stored but
  marked for review.
  """
  @spec send_message(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, DirectMessage.t()} | {:error, term()}
  def send_message(conversation_id, sender_id, content)
      when is_binary(conversation_id) and is_binary(sender_id) and is_binary(content) do
    trimmed = String.trim(content)

    with {:ok, sender} <- fetch_active_sender(sender_id),
         {:ok, conversation} <- fetch_conversation(conversation_id),
         :ok <- ensure_participant(conversation, sender.id),
         {:ok, validated} <-
           Validator.validate(%{
             kind: :direct,
             conversation_id: conversation.id,
             user_id: sender.id,
             content: trimmed
           }),
         {:ok, %DirectMessage{} = row} <- Pipeline.run(validated) do
      broadcast_new_message(row)
      {:ok, row}
    end
  end

  defp ensure_participant(conversation, sender_id) do
    if participant?(conversation, sender_id),
      do: :ok,
      else: {:error, :not_participant}
  end

  defp fetch_conversation(conversation_id) do
    case get_conversation(conversation_id) do
      %Conversation{} = conversation -> {:ok, conversation}
      nil -> {:error, :not_found}
    end
  end

  # Fresh, per-send database check (PRD §2.2) — a session that outlives a
  # ban must never keep write privileges.
  defp fetch_active_sender(sender_id) do
    case Accounts.get_user(sender_id) do
      %User{is_banned: true} -> {:error, :banned}
      %User{} = user -> {:ok, user}
      nil -> {:error, :unknown_sender}
    end
  end
end
