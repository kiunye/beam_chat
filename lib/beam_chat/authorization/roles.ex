defmodule BeamChat.Authorization.Roles do
  @moduledoc """
  Static platform role → permission catalogue.

  Two role layers exist and they compose (PRD §2.1):

  - **Platform role** (`users.role`): `member`, `moderator`, `admin`. Global.
  - **Room role** (`room_members.role`): `member`, `moderator`, `owner`.
    Room-scoped, layered under the platform role, and resolved per check by
    `BeamChat.Authorization.can?/3`.

  There is deliberately no per-category or per-node override of the
  platform role.
  """

  @typedoc "A permission atom, e.g. `:settings_access`."
  @type permission :: atom()

  @doc "All permissions a platform role grants, ignoring room context."
  @spec global_permissions(String.t() | nil) :: [permission()]

  def global_permissions("admin") do
    ~w(settings_access user_manage payments_configure structure_manage
       moderation_configure wallet_credit radio_manage room_create
       room_manage room_moderate member_manage message_delete)a
  end

  # A platform moderator acts on content in every room but can never reach
  # Settings: user management, payment configuration, and the
  # category/room structure are admin-only (PRD §2.1).
  def global_permissions("moderator") do
    ~w(room_create room_moderate member_manage message_delete)a
  end

  def global_permissions("member"), do: []

  def global_permissions(_), do: []

  @doc """
  Permissions a room role adds on top of the actor's platform permissions,
  scoped to that one room.

  A room `owner` manages their room (metadata, membership, moderation).
  A room `moderator` has content-moderation powers in that room only.
  """
  @spec room_role_permissions(String.t() | nil) :: [permission()]

  def room_role_permissions("owner") do
    ~w(room_manage member_manage room_moderate message_delete)a
  end

  def room_role_permissions("moderator"), do: ~w(room_moderate message_delete)a
  def room_role_permissions(_), do: []
end
