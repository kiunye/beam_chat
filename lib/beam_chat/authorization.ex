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

  alias BeamChat.Authorization.Roles
  alias BeamChat.Authorization.Scope
  alias BeamChat.Rooms
  alias BeamChat.Rooms.Room

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
end
