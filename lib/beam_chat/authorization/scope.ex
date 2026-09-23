defmodule BeamChat.Authorization.Scope do
  @moduledoc """
  The authorization scope for the current request / LiveView mount.

  A scope bundles everything the permission check needs into a single
  value that is resolved once per request (or LiveView mount) and then
  reused, so `BeamChat.Authorization.can?/2` is a pure lookup with no
  database access on the hot path:

    * `user` — the acting user (nil for guests)
    * `tenant` — the active tenant, if one was resolved
    * `tenant_role` — the user's `tenant_members.role` in the active tenant

  Scopes are built by the `BeamChatWeb.TenantContext` plug (controllers)
  and `on_mount` hook (LiveViews), and stashed as `:current_scope` so
  every later check reads the same snapshot.

  A scope is immutable and single-purpose: it answers "who is acting and
  where". It never carries permissions itself — those come from
  `BeamChat.Authorization.Roles`, keyed by the roles on the scope.
  """

  alias BeamChat.Accounts.User
  alias BeamChat.Tenants
  alias BeamChat.Tenants.Tenant

  defstruct user: nil,
            tenant: nil,
            tenant_role: nil

  @type t :: %__MODULE__{
          user: User.t() | nil,
          tenant: Tenant.t() | nil,
          tenant_role: String.t() | nil
        }

  @doc """
  Build the scope for `user`, optionally resolved against `tenant`.

  The tenant membership role is looked up once here; callers that pass
  `tenant: nil` (e.g. global platform actions such as banning a user)
  simply carry no tenant permissions.
  """
  @spec for_user(User.t() | nil, Tenant.t() | nil) :: t()
  def for_user(nil, _tenant), do: %__MODULE__{}
  def for_user(%User{} = user, nil), do: %__MODULE__{user: user}

  def for_user(%User{} = user, %Tenant{} = tenant),
    do: %__MODULE__{user: user, tenant: tenant, tenant_role: Tenants.member_role(tenant, user)}

  @doc "The id of the acting user, or nil for a guest scope."
  @spec user_id(t()) :: Ecto.UUID.t() | nil
  def user_id(%__MODULE__{user: %User{id: id}}), do: id
  def user_id(%__MODULE__{user: nil}), do: nil
end
