defmodule BeamChat.Direct do
  @moduledoc """
  Direct conversations and messages (1:1).
  """

  import Ecto.Query

  alias BeamChat.Accounts.User
  alias BeamChat.Direct.Conversation
  alias BeamChat.Direct.DirectMessage
  alias BeamChat.Repo

  @topic_prefix "conversation:"

  def topic(conversation_id), do: @topic_prefix <> conversation_id

  def subscribe(conversation_id) do
    Phoenix.PubSub.subscribe(BeamChat.PubSub, topic(conversation_id))
  end

  def unsubscribe(conversation_id) do
    Phoenix.PubSub.unsubscribe(BeamChat.PubSub, topic(conversation_id))
  end

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
    limit = normalize_dm_page_limit(Map.get(opts, :limit) || 30)
    page = normalize_dm_page(Map.get(opts, :page) || 1)
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
      page_count: dm_inbox_page_count(total, limit)
    }
  end

  defp normalize_dm_page_limit(n) when is_integer(n), do: n |> max(1) |> min(100)

  defp normalize_dm_page_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> normalize_dm_page_limit(n)
      :error -> 30
    end
  end

  defp normalize_dm_page_limit(_), do: 30

  defp normalize_dm_page(n) when is_integer(n), do: max(1, n)

  defp normalize_dm_page(s) when is_binary(s) do
    case Integer.parse(s) do
      {p, _} -> normalize_dm_page(p)
      :error -> 1
    end
  end

  defp normalize_dm_page(_), do: 1

  defp dm_inbox_page_count(_total, limit) when limit < 1, do: 1

  defp dm_inbox_page_count(total, limit) do
    max(1, div(total + limit - 1, limit))
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

  def send_message(conversation_id, sender_id, content) do
    content = String.trim(content)

    attrs = %{
      conversation_id: conversation_id,
      sender_id: sender_id,
      content: content,
      content_type: "text"
    }

    with {:ok, msg} <-
           %DirectMessage{}
           |> DirectMessage.changeset(attrs)
           |> Repo.insert() do
      msg = Repo.preload(msg, :sender)
      broadcast_new_message(msg)
      {:ok, msg}
    end
  end
end
