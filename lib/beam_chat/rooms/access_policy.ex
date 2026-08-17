defmodule BeamChat.Rooms.AccessPolicy do
  @moduledoc """
  Decides whether a user may enter a room LiveView and participate in chat.

  Paid rooms require an active `group_subscriptions` row (or membership/owner
  shortcuts). Users without a subscription see the upgrade flow and can pay
  from their wallet once funded.
  """

  import Ecto.Query

  alias BeamChat.Accounts.User
  alias BeamChat.Repo
  alias BeamChat.Rooms
  alias BeamChat.Rooms.Room
  alias BeamChat.Rooms.RoomMember
  alias BeamChat.Tenants

  @type outcome ::
          :ok
          | {:blocked, :upgrade_required}
          | {:blocked, :membership_required}
          | {:blocked, :secret_forbidden}

  @spec check(struct(), struct() | nil) :: outcome()
  def check(%Room{} = room, %User{id: user_id}) do
    flags = Rooms.room_access_flags(room.id, user_id)
    check_authenticated(room, user_id, flags)
  end

  def check(%Room{type: "secret"}, nil), do: {:blocked, :secret_forbidden}

  def check(%Room{type: type}, nil) when type in ~w(private paid) do
    {:blocked, :membership_required}
  end

  def check(%Room{type: "public"}, nil), do: :ok

  def check(%Room{type: "paid", is_paid: true}, nil), do: {:blocked, :upgrade_required}

  def check(%Room{type: "paid"}, nil), do: :ok

  defp check_authenticated(%Room{} = room, user_id, flags) do
    cond do
      owner_or_member?(room, user_id, flags) -> :ok
      public_room?(room) -> :ok
      free_paid_room?(room) -> :ok
      paid_room_needs_subscription?(room) -> paid_subscription_outcome(flags)
      private_or_secret?(room) -> {:blocked, :membership_required}
      true -> {:blocked, :membership_required}
    end
  end

  defp owner_or_member?(%Room{} = r, user_id, flags),
    do: r.owner_id == user_id or flags.member

  defp public_room?(%Room{type: "public"}), do: true
  defp public_room?(%Room{}), do: false

  defp free_paid_room?(%Room{type: "paid", is_paid: false}), do: true
  defp free_paid_room?(%Room{}), do: false

  defp paid_room_needs_subscription?(%Room{type: "paid", is_paid: true}), do: true
  defp paid_room_needs_subscription?(%Room{}), do: false

  defp private_or_secret?(%Room{type: type}) when type in ~w(private secret), do: true
  defp private_or_secret?(%Room{}), do: false

  defp paid_subscription_outcome(%{active_subscription: true}), do: :ok
  defp paid_subscription_outcome(_flags), do: {:blocked, :upgrade_required}

  # ---------------------------------------------------------------------------
  # Role-based visibility (CATEGORY_REDESIGN.md §4.5 / D5)
  # ---------------------------------------------------------------------------

  @doc """
  List the rooms visible to `user` within `tenant`.

  - Tenant admins see the entire tenant tree (`Room` rows scoped by
    `tenant_id`).
  - Everyone else sees only the rooms they hold an explicit `room_members` grant
    for (no automatic down-tree cascade).

  Both branches run inside `Repo.with_tenant/3` so PostgreSQL RLS applies.
  """
  @spec list_visible_rooms(struct() | Ecto.UUID.t(), struct() | Ecto.UUID.t()) :: [Room.t()]
  def list_visible_rooms(user, tenant) do
    tenant_id = id_of(tenant)
    user_id = id_of(user)

    if Tenants.admin?(tenant, user) do
      Repo.with_tenant(tenant_id, user_id, fn ->
        from(r in Room, where: r.tenant_id == ^tenant_id, order_by: [asc: r.name])
        |> Repo.all()
      end)
    else
      Repo.with_tenant(tenant_id, user_id, fn ->
        from(r in Room,
          join: rm in RoomMember,
          on: rm.room_id == r.id,
          where: r.tenant_id == ^tenant_id and rm.user_id == ^user_id,
          distinct: true,
          order_by: [asc: r.name]
        )
        |> Repo.all()
      end)
    end
  end

  @doc """
  Whether `user` may view `room`. True when the user is an admin of
  `room.tenant_id` or holds a `room_members` row for that room. Wrapped in
  `Repo.with_tenant/3` so RLS applies.
  """
  @spec can_view?(struct() | Ecto.UUID.t(), Room.t()) :: boolean()
  def can_view?(user, %Room{tenant_id: tenant_id} = room) do
    user_id = id_of(user)

    Repo.with_tenant(tenant_id, user_id, fn ->
      Tenants.admin?(tenant_id, user_id) or
        Repo.exists?(
          from(rm in RoomMember,
            where: rm.room_id == ^room.id and rm.user_id == ^user_id
          )
        )
    end)
  end

  defp id_of(%{id: id}), do: id
  defp id_of(id) when is_binary(id), do: id

  @doc """
  Whether `user` may join the LiveKit audio/video session for `room`.

  Reuses the same rules as `check/2`: only authenticated members of a room
  get a LiveKit token. Banned users never get a token; secret rooms always
  require membership.
  """
  @spec can_video?(struct(), struct() | nil) :: boolean()
  def can_video?(%Room{}, %User{is_banned: true}), do: false
  def can_video?(%Room{}, nil), do: false

  def can_video?(%Room{} = room, %User{id: uid, is_banned: false}) do
    match?(:ok, check(room, %User{id: uid, is_banned: false}))
  end
end
