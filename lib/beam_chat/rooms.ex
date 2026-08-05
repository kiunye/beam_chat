defmodule BeamChat.Rooms do
  @moduledoc """
  Room listing, visibility, membership (via `BeamChatWeb.RoomPresence`), and
  room PubSub broadcasts for typing indicators and new messages.
  """

  import Ecto.Query

  alias BeamChat.Messages.Message
  alias BeamChat.Messages.Persister
  alias BeamChat.Messages.Validator
  alias BeamChat.Moderation.RuleEngine
  alias BeamChat.Pagination
  alias BeamChat.Payments.GroupSubscription
  alias BeamChat.Repo
  alias BeamChat.Rooms.Room
  alias BeamChat.Rooms.RoomCategory
  alias BeamChat.Rooms.RoomMember

  @spec set_typing(Ecto.UUID.t(), Ecto.UUID.t(), boolean()) :: :ok
  def set_typing(room_id, user_id, is_typing) do
    event = if is_typing, do: :user_typing, else: :user_stopped_typing

    Phoenix.PubSub.broadcast(
      BeamChat.PubSub,
      "room:#{room_id}",
      {event, %{room_id: room_id, data: user_id, timestamp: System.system_time(:millisecond)}}
    )

    :ok
  end

  @spec broadcast_new_message(Message.t()) :: :ok
  def broadcast_new_message(%BeamChat.Messages.Message{} = msg) do
    Phoenix.PubSub.broadcast(BeamChat.PubSub, "room:#{msg.room_id}", {:new_message, msg})
    :ok
  end

  @doc """
  Validates, moderates, persists and broadcasts a room message synchronously.

  Returns `{:ok, %Message{}}` (already broadcast on `room:<id>`) or
  `{:error, reason}` where `reason` is `:empty_content`,
  `{:blocked, reason}` (moderation rejection), a validator error atom, or
  `{:persist_failed, reason}`.
  """
  @spec send_message(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, Message.t()} | {:error, term()}
  def send_message(room_id, sender_id, content)
      when is_binary(room_id) and is_binary(sender_id) do
    trimmed = String.trim(content || "")

    if trimmed == "" do
      {:error, :empty_content}
    else
      message = %{
        kind: :room,
        room_id: room_id,
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
        {:flagged, msg, _reason} -> persist_room_message(msg)
        msg when is_map(msg) -> persist_room_message(msg)
      end
    end
  end

  defp persist_room_message(data) do
    case Persister.persist_ordered([data]) do
      [{:ok, %Message{} = row}] ->
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

  def list_categories do
    from(c in RoomCategory, order_by: [asc: c.name])
    |> Repo.all()
  end

  @doc """
  Lists non-archived rooms visible to the user on the index (excludes secret rooms
  unless the user is the owner or a member).

  Returns a map with `:rooms`, `:total_count`, `:page`, `:limit`, and `:page_count`
  for server-side pagination.
  """
  def list_rooms_for_index(%BeamChat.Accounts.User{} = user, opts \\ %{}) do
    limit = Pagination.normalize_limit(Map.get(opts, :limit), 50)
    page = Pagination.normalize_page(Map.get(opts, :page))
    offset = (page - 1) * limit

    base =
      user
      |> filtered_rooms_base_query()
      |> maybe_filter_search(opts[:search])
      |> maybe_filter_category(normalize_category_id(opts[:category_id]))

    rooms =
      from(r in base,
        order_by: [asc: r.name],
        preload: [:category, :owner],
        limit: ^limit,
        offset: ^offset
      )
      |> Repo.all()

    total = Repo.aggregate(base, :count, :id)

    %{
      rooms: rooms,
      total_count: total,
      page: page,
      limit: limit,
      page_count: Pagination.page_count(total, limit)
    }
  end

  defp normalize_category_id(nil), do: nil
  defp normalize_category_id(""), do: nil
  defp normalize_category_id(id), do: id

  defp filtered_rooms_base_query(user) do
    secret_ok = secret_visibility_dynamic(user.id)

    from r in Room,
      as: :room,
      where: r.is_archived == false,
      where: ^secret_ok
  end

  defp secret_visibility_dynamic(user_id) do
    dynamic(
      [r],
      r.type != "secret" or r.owner_id == ^user_id or
        exists(
          from rm in RoomMember,
            where: rm.room_id == parent_as(:room).id and rm.user_id == ^user_id,
            select: 1
        )
    )
  end

  defp maybe_filter_search(q, search) do
    if present?(search) do
      term = "%" <> String.trim(search) <> "%"
      from r in q, where: ilike(r.name, ^term) or ilike(r.slug, ^term)
    else
      q
    end
  end

  defp maybe_filter_category(q, nil), do: q

  defp maybe_filter_category(q, category_id) do
    from r in q, where: r.category_id == ^category_id
  end

  def get_room_by_slug!(slug) do
    from(r in Room,
      where: r.slug == ^slug and r.is_archived == false,
      preload: [:category, :owner]
    )
    |> Repo.one!()
  end

  def get_room_by_slug(slug) do
    from(r in Room,
      where: r.slug == ^slug and r.is_archived == false,
      preload: [:category, :owner]
    )
    |> Repo.one()
  end

  @doc """
  Membership and active subscription for a room in a single database round trip.

  Used by `BeamChat.Rooms.AccessPolicy` to avoid separate `room_member?` /
  `active_subscription?` queries on the hot path.
  """
  def room_access_flags(room_id, user_id) when is_binary(room_id) and is_binary(user_id) do
    now = DateTime.utc_now(:second)

    # `room_id` / `user_id` come from Ecto structs as UUID strings in this app.
    # When we bind them to Postgres `::uuid` parameters, Postgrex expects the
    # 16-byte UUID binary representation.
    room_id = uuid_param(room_id)
    user_id = uuid_param(user_id)

    %Postgrex.Result{rows: [[member?, active_sub?]]} =
      Repo.query!(
        """
        SELECT
          EXISTS(
            SELECT 1 FROM room_members rm
            WHERE rm.room_id = $1::uuid AND rm.user_id = $2::uuid
          ),
          EXISTS(
            SELECT 1 FROM group_subscriptions s
            WHERE s.room_id = $1::uuid AND s.user_id = $2::uuid
              AND s.status = 'active'
              AND s.expires_at > $3::timestamptz
          )
        """,
        [room_id, user_id, now]
      )

    %{member: member?, active_subscription: active_sub?}
  end

  defp uuid_param(uuid) when is_binary(uuid) do
    # UUID-as-binary is 16 bytes; UUID strings are typically 36 bytes.
    # Ecto.UUID.dump!/1 converts UUID strings to the 16-byte representation.
    if byte_size(uuid) == 16, do: uuid, else: Ecto.UUID.dump!(uuid)
  end

  def room_member?(room_id, user_id) do
    from(rm in RoomMember,
      where: rm.room_id == ^room_id and rm.user_id == ^user_id,
      select: 1
    )
    |> Repo.exists?()
  end

  def active_subscription?(room_id, user_id) do
    now = DateTime.utc_now(:second)

    from(s in GroupSubscription,
      where:
        s.room_id == ^room_id and s.user_id == ^user_id and s.status == "active" and
          s.expires_at > ^now,
      select: 1
    )
    |> Repo.exists?()
  end

  def list_recent_messages(room_id, limit \\ 100) do
    from(m in BeamChat.Messages.Message,
      where: m.room_id == ^room_id and m.is_deleted == false,
      order_by: [asc: m.inserted_at],
      limit: ^limit,
      preload: [:sender]
    )
    |> Repo.all()
  end

  defp present?(v) when is_binary(v), do: String.trim(v) != ""
  defp present?(_), do: false
end
