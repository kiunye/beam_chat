defmodule BeamChat.Authorization do
  @moduledoc """
  Central permission checks for the application.

  The single entry point is `can?/2`, which answers whether the acting
  `BeamChat.Authorization.Scope` holds a permission. All authorization
  decisions — router pipelines, LiveView `on_mount` hooks, event
  handlers, context functions — should go through this module instead of
  comparing role strings at the call site.

  `can?/2` is a pure lookup over the roles carried by the scope: the
  membership role resolution happens once, when the scope is built (see
  `BeamChat.Authorization.Scope.for_user/2`), so permission checks never
  touch the database on the hot path.

  Permission composition is a union: the acting user holds the permissions
  of their global role plus those of their role in the active tenant.
  """

  alias BeamChat.Accounts.User
  alias BeamChat.Authorization.Roles
  alias BeamChat.Authorization.Scope
  alias BeamChat.Rooms
  alias BeamChat.Rooms.Room
  alias BeamChat.Tenants

  @doc """
  Whether `scope` holds `permission`.

  Guest scopes and scopes without a user hold nothing. Unknown
  permissions are denied rather than raising, so a typo'd permission
  atom fails closed instead of crashing the request.
  """
  @spec can?(Scope.t() | nil, Roles.permission()) :: boolean()
  def can?(nil, _permission), do: false
  def can?(%Scope{user: nil}, _permission), do: false

  def can?(%Scope{} = scope, permission) when is_atom(permission),
    do: permission in permissions(scope)

  @doc """
  Context-aware check for permissions that depend on a specific room.

      can?(scope, :room_message_delete, %{room: room})

  Resolves the acting user's `room_members.role` for `room` and unions
  the room-level permissions (`BeamChat.Authorization.Roles.room_permissions/1`)
  with the scope's own global/tenant permissions — the same additive-union
  semantics as `can?/2`.

  Room membership is read from the database under the request's tenant
  context, so this variant is for per-action checks (deleting a message,
  opening a member-management dialog), not hot paths.

  Without a `:room` in the context this degrades to `can?/2`.
  """
  @spec can?(Scope.t() | nil, Roles.permission(), %{room: Room.t()}) :: boolean()
  def can?(nil, _permission, _context), do: false
  def can?(%Scope{user: nil}, _permission, _context), do: false

  def can?(%Scope{} = scope, permission, %{room: %Room{} = room})
      when is_atom(permission) do
    room_role = Rooms.room_member_role(room.id, Scope.user_id(scope))

    can?(scope, permission) or permission in Roles.room_permissions(room_role)
  end

  @doc """
  The union of permissions held by `scope`: global role permissions plus
  tenant role permissions (when the scope carries an active tenant).
  """
  @spec permissions(Scope.t() | nil) :: [Roles.permission()]
  def permissions(nil), do: []
  def permissions(%Scope{user: nil}), do: []

  def permissions(%Scope{} = scope) do
    scope
    |> global_and_tenant_permissions()
    |> Enum.uniq()
  end

  defp global_and_tenant_permissions(%Scope{} = scope) do
    Roles.global_permissions(scope.user.role) ++
      Roles.tenant_permissions(scope.tenant_role)
  end

  # -- guarded entry points ----------------------------------------------------

  @doc """
  Require `actor` to hold a global (platform-level) `permission`, such as
  `:user_ban` or `:wallet_credit`.

  Returns `:ok` or `{:error, :forbidden}`. This and
  `ensure_tenant_permission/3` are the only sanctioned ways contexts
  should gate privileged actions — keeping the "who may act" contract in
  one module instead of per-context copies.
  """
  @spec ensure_permission(User.t(), Roles.permission()) :: :ok | {:error, :forbidden}
  def ensure_permission(%User{} = actor, permission) do
    if can?(Scope.for_user(actor, nil), permission) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  @doc """
  Fetch `tenant_or_id` and require `actor` to hold `permission` in it.

  Every tenant-scoped mutation starts with this exact step (fetch the
  tenant, build the scope against it, check the permission), so it lives
  here once. Returns `{:ok, tenant}` — the tenant struct the caller needs
  for its `Repo.with_tenant/3` — or `{:error, :not_found | :forbidden}`.
  """
  @spec ensure_tenant_permission(User.t(), struct() | Ecto.UUID.t(), Roles.permission()) ::
          {:ok, Tenants.Tenant.t()} | {:error, :not_found | :forbidden}
  def ensure_tenant_permission(%User{} = actor, tenant_or_id, permission) do
    case Tenants.get_tenant(id_of(tenant_or_id)) do
      nil ->
        {:error, :not_found}

      %Tenants.Tenant{} = tenant ->
        if can?(Scope.for_user(actor, tenant), permission) do
          {:ok, tenant}
        else
          {:error, :forbidden}
        end
    end
  end

  @doc """
  The id of a struct-or-id argument (user, tenant, station, ...).

  The canonical resolver for actor/target plumbing — contexts and
  policies share it instead of carrying private near-copies.
  """
  @spec id_of(struct() | Ecto.UUID.t() | nil) :: Ecto.UUID.t() | nil
  def id_of(nil), do: nil
  def id_of(%{id: id}), do: id
  def id_of(id) when is_binary(id), do: id
end
