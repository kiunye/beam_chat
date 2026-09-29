defmodule BeamChat.Authorization do
  @moduledoc """
  The single application-layer authorization point (PRD §4.5).

  With multi-tenancy gone there is no RLS backstop, so every access
  decision lives here. Two invariants keep the one layer honest:

  - Sensitive checks (ban status, room membership, wallet ownership) are
    re-verified against the database at the point of action, never trusted
    from what was loaded at login or mount.
  - Admin-only surfaces are gated by platform role at the point of entry,
    not inferred from what a LiveView happens to render.
  """

  alias BeamChat.Accounts.User
  alias BeamChat.Authorization.Roles
  alias BeamChat.Authorization.Scope
  alias BeamChat.Rooms

  @type room_context :: %{room: Rooms.Room.t()}

  @doc """
  Global permission check against the acting scope's platform role.
  """
  @spec can?(Scope.t() | nil, Roles.permission()) :: boolean()
  def can?(nil, _permission), do: false

  # Anonymous scope (a signed-out visitor): no permissions at all.
  def can?(%Scope{user: nil}, _permission), do: false

  def can?(%Scope{user: %User{role: role}}, permission),
    do: permission in Roles.global_permissions(role)

  @doc """
  Room-scoped permission check: the actor's platform permissions unioned
  with whatever their room role (owner/moderator of this specific room)
  adds.

  The room role is resolved with a fresh database lookup per call, so a
  role revoked a moment ago takes effect immediately.
  """
  @spec can?(Scope.t() | nil, Roles.permission(), room_context()) :: boolean()
  def can?(scope, permission, %{room: room}) do
    global_ok? = can?(scope, permission)

    room_ok? =
      with %Scope{user: %User{id: user_id}} <- scope,
           room_role when not is_nil(room_role) <- Rooms.room_member_role(room.id, user_id),
           true <- permission in Roles.room_role_permissions(room_role) do
        true
      else
        _ -> false
      end

    global_ok? or room_ok?
  end

  @doc """
  Every permission the scope's platform role grants, ignoring room context.
  """
  @spec permissions(Scope.t() | nil) :: [Roles.permission()]
  def permissions(nil), do: []

  def permissions(%Scope{user: nil}), do: []

  def permissions(%Scope{user: %User{role: role}}),
    do: Roles.global_permissions(role)

  @doc """
  Context-side guard: `:ok` when the actor's platform role grants
  `permission`, `{:error, :forbidden}` otherwise.
  """
  @spec ensure_permission(User.t() | nil, Roles.permission()) ::
          :ok | {:error, :forbidden}
  def ensure_permission(%User{} = actor, permission) do
    if can?(Scope.for_user(actor), permission), do: :ok, else: {:error, :forbidden}
  end

  def ensure_permission(nil, _permission), do: {:error, :forbidden}
end
