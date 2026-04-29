defmodule BeamChat.Rooms do
  @moduledoc """
  Room listing, visibility, and distributed `RoomServer` lifecycle helpers.
  """

  import Ecto.Query

  alias BeamChat.Payments.GroupSubscription
  alias BeamChat.Repo
  alias BeamChat.Rooms.Room
  alias BeamChat.Rooms.RoomCategory
  alias BeamChat.Rooms.RoomMember
  alias BeamChat.Rooms.RoomServer

  @doc """
  Starts a `RoomServer` under the Horde supervisor if one is not already running.
  """
  def ensure_room_server_started(room_id) when is_binary(room_id) do
    spec = %{
      id: {:room, room_id},
      restart: :temporary,
      start: {RoomServer, :start_link, [room_id]},
      type: :worker
    }

    case Horde.DynamicSupervisor.start_child(BeamChat.RoomSupervisor, spec) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, {:already_registered, _pid}} ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.warning(
          "rooms.ensure_room_server_started failed room_id=#{room_id} reason=#{inspect(reason)}"
        )

        :ok
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
    limit = normalize_room_page_limit(Map.get(opts, :limit, 50))
    page = normalize_room_page(Map.get(opts, :page, 1))
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
      page_count: room_index_page_count(total, limit)
    }
  end

  defp normalize_room_page_limit(n) when is_integer(n), do: n |> max(1) |> min(100)

  defp normalize_room_page_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> normalize_room_page_limit(n)
      :error -> 50
    end
  end

  defp normalize_room_page_limit(_), do: 50

  defp normalize_room_page(n) when is_integer(n), do: max(1, n)

  defp normalize_room_page(s) when is_binary(s) do
    case Integer.parse(s) do
      {p, _} -> normalize_room_page(p)
      :error -> 1
    end
  end

  defp normalize_room_page(_), do: 1

  defp room_index_page_count(_total, limit) when limit < 1, do: 1

  defp room_index_page_count(total, limit) do
    max(1, div(total + limit - 1, limit))
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
