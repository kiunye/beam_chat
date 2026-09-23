defmodule BeamChat.Authorization.Roles do
  @moduledoc """
  Static catalogue mapping roles to permission atoms.

  Permissions are the vocabulary; roles are the bundles. Callers ask
  `BeamChat.Authorization.can?/2` for a permission and never match on role
  names, so adding a capability means changing this module only.

  Roles exist at three levels today, and they compose by union — a user
  holds the permissions of their global role plus those of their role in
  the active tenant, and room-level permissions additionally apply when a
  check passes a room context (see `BeamChat.Authorization.can?/3`):

    * global (`users.role`) — platform-wide staff powers
    * tenant (`tenant_members.role`) — per-tenant administration
    * room (`room_members.role`) — powers inside one room, resolved
      per-check against the room in question

  ## Permission vocabulary

    * `:moderation_configure` — manage moderation rules
    * `:room_create`          — create rooms in a tenant
    * `:room_update`          — edit room settings
    * `:room_delete`          — delete rooms
    * `:room_manage_members`  — grant/revoke room membership and roles
    * `:room_message_delete`  — delete messages in a room
    * `:tenant_manage`        — manage tenant members and their roles
    * `:user_ban`             — ban or unban platform users
    * `:user_manage_roles`    — change a user's global role
    * `:wallet_credit`        — manually credit a user's wallet

  `:room_message_delete` is room-scoped: it is granted by the room
  roles below (and to tenant admins inside their tenant), never by global
  roles alone — platform staff fight abuse through the moderation rule
  engine instead of per-room message surgery.

  The catalogue is deliberately static in-code. A database-driven
  catalogue (roles/role_permissions tables with a cache) is a known
  extension path, but only worth its complexity once roles must be
  configurable at runtime; until then a compile-time map keeps the
  permission graph greppable and testable.
  """

  @global_permissions %{
    "admin" => [
      :moderation_configure,
      :room_create,
      :room_delete,
      :room_manage_members,
      :room_update,
      :tenant_manage,
      :user_ban,
      :user_manage_roles,
      :wallet_credit
    ],
    "moderator" => [:moderation_configure, :user_ban],
    "member" => []
  }

  @tenant_permissions %{
    "admin" => [
      :room_create,
      :room_delete,
      :room_manage_members,
      :room_message_delete,
      :room_update,
      :tenant_manage
    ],
    "member" => []
  }

  @room_permissions %{
    "owner" => [
      :room_delete,
      :room_manage_members,
      :room_message_delete,
      :room_update
    ],
    "moderator" => [
      :room_manage_members,
      :room_message_delete,
      :room_update
    ],
    "member" => []
  }

  @type permission ::
          :moderation_configure
          | :room_create
          | :room_delete
          | :room_manage_members
          | :room_message_delete
          | :room_update
          | :tenant_manage
          | :user_ban
          | :user_manage_roles
          | :wallet_credit

  @doc "Permissions held by a global role. Unknown roles hold nothing."
  @spec global_permissions(String.t() | nil) :: [permission()]
  def global_permissions(role) when is_binary(role),
    do: Map.get(@global_permissions, role, [])

  def global_permissions(nil), do: []

  @doc "Permissions held by a tenant role. Unknown or absent roles hold nothing."
  @spec tenant_permissions(String.t() | nil) :: [permission()]
  def tenant_permissions(role) when is_binary(role),
    do: Map.get(@tenant_permissions, role, [])

  def tenant_permissions(nil), do: []

  @doc "Permissions held by a room role. Unknown or absent roles hold nothing."
  @spec room_permissions(String.t() | nil) :: [permission()]
  def room_permissions(role) when is_binary(role),
    do: Map.get(@room_permissions, role, [])

  def room_permissions(nil), do: []

  @doc "Every permission any role can hold, for documentation and tests."
  @spec all_permissions() :: [permission()]
  def all_permissions do
    global = List.flatten(Map.values(@global_permissions))
    tenant = List.flatten(Map.values(@tenant_permissions))
    room = List.flatten(Map.values(@room_permissions))

    (global ++ tenant ++ room)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
