defmodule BeamChat.Rooms do
  @moduledoc """
  Room listing, visibility, membership (via `BeamChatWeb.RoomPresence`), and
  room PubSub broadcasts for typing indicators and new messages.
  """

  import Ecto.Query
  import Ecto.Changeset

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
    Repo.scoped(fn ->
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
    end)
  end

  defp dispatch_after_moderation(data) do
    with {:ok, validated} <- Validator.validate(data) do
      case RuleEngine.apply_rules(validated) do
        {:blocked, _msg, reason} -> {:error, {:blocked, reason}}
        {:flagged, msg, _reason} -> persist_and_broadcast(msg)
        msg when is_map(msg) -> persist_and_broadcast(msg)
      end
    end
  end

  defp persist_and_broadcast(msg) do
    with {:ok, %Message{} = row} <- Persister.persist_and_preload(msg) do
      broadcast_new_message(row)
      {:ok, row}
    else
      {:error, _reason} = err -> err
      {:ok, other} -> {:error, {:persist_failed, {:unexpected_row, other}}}
    end
  end

  def list_categories do
    Repo.scoped(fn ->
      from(c in RoomCategory, order_by: [asc: c.name])
      |> Repo.all()
    end)
  end

  @doc """
  Lists non-archived rooms visible to the user on the index (excludes secret rooms
  unless the user is the owner or a member).

  Returns a map with `:rooms`, `:total_count`, `:page`, `:limit`, and `:page_count`
  for server-side pagination.
  """
  def list_rooms_for_index(%BeamChat.Accounts.User{} = user, opts \\ %{}) do
    Repo.scoped(fn ->
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
    end)
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
    Repo.scoped(fn ->
      from(r in Room,
        where: r.slug == ^slug and r.is_archived == false,
        preload: [:category, :owner]
      )
      |> Repo.one!()
    end)
  end

  def get_room_by_slug(slug) do
    Repo.scoped(fn ->
      from(r in Room,
        where: r.slug == ^slug and r.is_archived == false,
        preload: [:category, :owner]
      )
      |> Repo.one()
    end)
  end

  @doc """
  Membership and active subscription for a room in a single database round trip.

  Used by `BeamChat.Rooms.AccessPolicy` to avoid separate `room_member?` /
  `active_subscription?` queries on the hot path.
  """
  def room_access_flags(room_id, user_id) when is_binary(room_id) and is_binary(user_id) do
    Repo.scoped(fn ->
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
    end)
  end

  defp uuid_param(uuid) when is_binary(uuid) do
    # UUID-as-binary is 16 bytes; UUID strings are typically 36 bytes.
    # Ecto.UUID.dump!/1 converts UUID strings to the 16-byte representation.
    if byte_size(uuid) == 16, do: uuid, else: Ecto.UUID.dump!(uuid)
  end

  def room_member?(room_id, user_id) do
    Repo.scoped(fn ->
      from(rm in RoomMember,
        where: rm.room_id == ^room_id and rm.user_id == ^user_id,
        select: 1
      )
      |> Repo.exists?()
    end)
  end

  def active_subscription?(room_id, user_id) do
    Repo.scoped(fn ->
      now = DateTime.utc_now(:second)

      from(s in GroupSubscription,
        where:
          s.room_id == ^room_id and s.user_id == ^user_id and s.status == "active" and
            s.expires_at > ^now,
        select: 1
      )
      |> Repo.exists?()
    end)
  end

  def list_recent_messages(room_id, limit \\ 100) do
    Repo.scoped(fn ->
      from(m in BeamChat.Messages.Message,
        where: m.room_id == ^room_id and m.is_deleted == false,
        order_by: [asc: m.inserted_at],
        limit: ^limit,
        preload: [:sender]
      )
      |> Repo.all()
    end)
  end

  defp present?(v) when is_binary(v), do: String.trim(v) != ""
  defp present?(_), do: false

  # ---------------------------------------------------------------------------
  # Recursive room-tree helpers (CATEGORY_REDESIGN.md §4.4)
  # ---------------------------------------------------------------------------

  @doc """
  Direct (one level) children of the given parent room id. Returns full `Room`
  structs ordered by name.
  """
  @spec list_child_rooms(Ecto.UUID.t() | nil) :: [Room.t()]
  def list_child_rooms(parent_id) do
    Repo.scoped(fn ->
      base =
        if is_nil(parent_id) do
          from(r in Room, where: is_nil(r.parent_id))
        else
          from(r in Room, where: r.parent_id == ^parent_id)
        end

      from(r in base, order_by: [asc: r.name])
      |> Repo.all()
    end)
  end

  @doc """
  The room itself plus every nested descendant, as full `Room` structs. Uses a
  recursive CTE so it is a single query regardless of tree depth.
  """
  @spec room_descendants(Ecto.UUID.t()) :: [Room.t()]
  def room_descendants(room_id) do
    Repo.scoped(fn ->
      from(r in Room,
        where:
          r.id in fragment(
            "(WITH RECURSIVE tree AS (SELECT id FROM rooms WHERE id = ?::uuid UNION ALL SELECT r2.id FROM rooms r2 INNER JOIN tree t ON r2.parent_id = t.id) SELECT id FROM tree)",
            type(^room_id, :string)
          ),
        order_by: [asc: r.name]
      )
      |> Repo.all()
    end)
  end

  @doc """
  All ancestors of the room up to the root, as full `Room` structs. The room
  itself is excluded. Uses a recursive CTE walking `parent_id` upward.
  """
  @spec room_ancestors(Ecto.UUID.t()) :: [Room.t()]
  def room_ancestors(room_id) do
    Repo.scoped(fn ->
      from(r in Room,
        where:
          r.id in fragment(
            "(WITH RECURSIVE anc AS (SELECT id, parent_id FROM rooms WHERE id = ?::uuid UNION ALL SELECT r2.id, r2.parent_id FROM rooms r2 INNER JOIN anc a ON r2.id = a.parent_id) SELECT id FROM anc WHERE id <> ?::uuid)",
            type(^room_id, :string),
            type(^room_id, :string)
          ),
        order_by: [asc: r.name]
      )
      |> Repo.all()
    end)
  end

  @doc """
  Breadcrumb from the root down to (and including) the given room, as a list of
  `Room` structs with the root first and the room last. Walks `parent_id`
  upward via repeated `Repo.get`; safe because tree depth is small.
  """
  @spec room_path(Ecto.UUID.t()) :: [Room.t()]
  def room_path(room_id) do
    Repo.scoped(fn ->
      case Repo.get(Room, room_id) do
        nil -> []
        %Room{} = room -> walk_up(room, [])
      end
    end)
  end

  defp walk_up(%Room{parent_id: nil} = room, acc), do: [room | acc]

  defp walk_up(%Room{parent_id: parent_id} = room, acc) do
    case Repo.get(Room, parent_id) do
      nil -> [room | acc]
      %Room{} = parent -> walk_up(parent, [room | acc])
    end
  end

  @doc """
  Re-parent `room` under `new_parent_id` (or to the root when `new_parent_id`
  is `nil`). Prevents cycles / illegal moves:

  - returns `{:error, :cycle}` if `new_parent_id == room.id` (self-parent),
  - returns `{:error, :cycle}` if `new_parent_id` is a descendant of `room`
    (would create a loop),
  - returns `{:error, :cycle}` if `new_parent_id` belongs to a different tenant
    (or does not exist).

  On success returns `{:ok, room}`; if the underlying update fails validation
  it returns `{:error, changeset}`.

  ## Tenancy
  This function performs a write and **must** be invoked inside
  `BeamChat.Repo.with_tenant(tenant_id, user_id, fn -> ... end)` so the
  PostgreSQL RLS update policies see the correct GUCs. The originating caller
  owns the transaction.
  """
  @spec move_room(Room.t(), Ecto.UUID.t() | nil) ::
          {:ok, Room.t()} | {:error, :cycle} | {:error, Ecto.Changeset.t()}
  def move_room(%Room{} = room, new_parent_id) do
    Repo.scoped(fn ->
      cond do
        new_parent_id == room.id ->
          {:error, :cycle}

        not is_nil(new_parent_id) and parent_tenant_mismatch?(room, new_parent_id) ->
          {:error, :cycle}

        not is_nil(new_parent_id) and MapSet.member?(descendant_ids(room.id), new_parent_id) ->
          {:error, :cycle}

        true ->
          room
          |> change(parent_id: new_parent_id)
          |> Repo.update()
      end
    end)
  end

  defp parent_tenant_mismatch?(room, new_parent_id) do
    case Repo.get(Room, new_parent_id) do
      nil -> true
      %Room{tenant_id: tid} -> tid != room.tenant_id
    end
  end

  defp descendant_ids(room_id) do
    room_descendants(room_id)
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  @doc """
  Build a `Room` from `attrs` (which must include `tenant_id` and `owner_id`),
  insert it, and create an owning `RoomMember` (role `"owner"`) so the creator
  can see and manage the room.

  Returns `{:ok, room}`, `{:error, :missing_tenant}` when `tenant_id` is absent
  from `attrs`, or `{:error, changeset}` if validation / insert fails. If the
  `RoomMember` insert fails the whole operation rolls back (the caller's
  `with_tenant` transaction).

  ## Tenancy
  This function performs writes and **must** be invoked inside
  `BeamChat.Repo.with_tenant(tenant_id, owner_id, fn -> ... end)` so the
  PostgreSQL RLS insert policies pass. The originating caller owns the
  transaction.
  """
  @spec create_room(map()) ::
          {:ok, Room.t()} | {:error, :missing_tenant} | {:error, Ecto.Changeset.t()}
  def create_room(attrs) when is_map(attrs) do
    Repo.scoped(fn ->
      tenant_id = Map.get(attrs, :tenant_id) || Map.get(attrs, "tenant_id")

      if is_nil(tenant_id) do
        {:error, :missing_tenant}
      else
        insert_room_with_owner(attrs)
      end
    end)
  end

  defp insert_room_with_owner(attrs) do
    with {:ok, room} <-
           %Room{} |> Room.changeset(attrs) |> Repo.insert(),
         {:ok, _member} <-
           %RoomMember{}
           |> RoomMember.changeset(%{
             room_id: room.id,
             user_id: room.owner_id,
             tenant_id: room.tenant_id,
             role: "owner"
           })
           |> Repo.insert() do
      {:ok, room}
    end
  end
end
