defmodule BeamChat.Tenants do
  @moduledoc """
  Tenant (county/org) context for the multi-tenant hierarchical room redesign.

  Provides tenant CRUD plus membership management and the `admin?/2` check
  that backs both Row Level Security and UI gating (CATEGORY_REDESIGN.md §4.2).
  """
  import Ecto.Query, warn: false

  alias BeamChat.Accounts.User
  alias BeamChat.Audit
  alias BeamChat.Authorization
  alias BeamChat.Authorization.Scope
  alias BeamChat.Repo
  alias BeamChat.Tenants.Tenant
  alias BeamChat.Tenants.TenantMember

  @doc "Create a tenant from attributes."
  def create_tenant(attrs \\ %{}) do
    %Tenant{}
    |> Tenant.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetch a tenant by id."
  def get_tenant(id), do: Repo.get(Tenant, id)

  @doc "Fetch a tenant by its unique slug."
  def get_tenant_by_slug(slug), do: Repo.get_by(Tenant, slug: slug)

  @doc "List all tenants."
  def list_tenants, do: Repo.all(Tenant)

  @doc """
  Add a user to a tenant with the given role (defaults to `"member"`).
  Returns `{:ok, member}` or `{:error, changeset}`.
  """
  def add_member(tenant_or_id, user_or_id, role \\ "member") do
    tenant_id = resolve_id(tenant_or_id)
    user_id = resolve_id(user_or_id)

    %TenantMember{}
    |> TenantMember.changeset(%{tenant_id: tenant_id, user_id: user_id, role: role})
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :user_id]
    )
    |> case do
      {:ok, %TenantMember{} = member} ->
        {:ok, member}

      # `on_conflict: :nothing` reports `{:ok, nil}` when the unique
      # (tenant_id, user_id) pair already existed; re-fetch the existing row so
      # callers always receive the membership struct (idempotent).
      {:ok, nil} ->
        {:ok, Repo.get_by!(TenantMember, tenant_id: tenant_id, user_id: user_id)}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Remove a user's membership from a tenant.

  The acting user must hold the `:tenant_manage` permission for the
  tenant (or globally). Returns `{:ok, member}` on success,
  `{:error, :forbidden}` when the actor lacks the permission,
  `{:error, :not_found}` if no such membership exists, or
  `{:error, changeset}` if the delete fails.

  Removing your own membership is allowed — a global admin can re-add you
  afterwards, so it is not a lockout risk.
  """
  def remove_member(%User{} = actor, tenant_or_id, user_or_id) do
    with {:ok, tenant} <- fetch_managed_tenant(tenant_or_id),
         :ok <- ensure_can_manage(actor, tenant) do
      do_remove_member(tenant_or_id, user_or_id, actor)
    end
  end

  defp do_remove_member(tenant_or_id, user_or_id, actor) do
    tenant_id = resolve_id(tenant_or_id)
    user_id = resolve_id(user_or_id)

    case Repo.get_by(TenantMember, tenant_id: tenant_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      member ->
        case Repo.delete(member) do
          {:ok, deleted} ->
            {:ok, _} =
              Audit.log(actor, "tenant_member.removed", deleted, %{
                tenant_id: tenant_id,
                user_id: user_id
              })

            {:ok, deleted}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  Change a member's role within a tenant (`"admin"` <-> `"member"`).

  The acting user must hold the `:tenant_manage` permission for the
  tenant (or globally). Tenant admins may demote themselves — the action
  is recoverable by a global admin, so self-demotion is a choice, not a
  lockout.

  Returns `{:ok, member}` or `{:error, :forbidden | :not_found | :invalid_role | changeset}`.
  """
  @spec set_member_role(struct(), struct() | Ecto.UUID.t(), struct() | Ecto.UUID.t(), String.t()) ::
          {:ok, TenantMember.t()}
          | {:error, :forbidden | :not_found | :invalid_role | Ecto.Changeset.t()}
  def set_member_role(%User{} = actor, tenant_or_id, user_or_id, role)
      when role in ~w(admin member) do
    with {:ok, tenant} <- fetch_managed_tenant(tenant_or_id),
         :ok <- ensure_can_manage(actor, tenant) do
      do_set_member_role(tenant_or_id, user_or_id, role, actor)
    end
  end

  def set_member_role(%User{}, _tenant_or_id, _user_or_id, _role), do: {:error, :invalid_role}

  defp do_set_member_role(tenant_or_id, user_or_id, role, actor) do
    tenant_id = resolve_id(tenant_or_id)
    user_id = resolve_id(user_or_id)

    case Repo.get_by(TenantMember, tenant_id: tenant_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      %TenantMember{} = member ->
        member
        |> TenantMember.changeset(%{role: role})
        |> Repo.update()
        |> case do
          {:ok, updated} = ok ->
            {:ok, _} =
              Audit.log(actor, "tenant_member.role_changed", updated, %{
                user_id: user_id,
                from: member.role,
                to: role
              })

            ok

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  List the members of a tenant with their user display fields, ordered by
  username. For the member-management admin UI.
  """
  @spec list_members(struct() | Ecto.UUID.t()) :: [map()]
  def list_members(tenant_or_id) do
    tenant_id = resolve_id(tenant_or_id)

    Repo.all(
      from(tm in TenantMember,
        join: u in User,
        on: u.id == tm.user_id,
        where: tm.tenant_id == ^tenant_id,
        order_by: [asc: u.username],
        select: %{
          id: tm.id,
          user_id: u.id,
          username: u.username,
          full_name: u.full_name,
          role: tm.role,
          is_banned: u.is_banned,
          joined_at: tm.inserted_at
        }
      )
    )
  end

  # Load the tenant struct for a permission check; :not_found keeps the
  # error uniform with the membership lookups below.
  defp fetch_managed_tenant(tenant_or_id) do
    case get_tenant(resolve_id(tenant_or_id)) do
      %Tenant{} = tenant -> {:ok, tenant}
      nil -> {:error, :not_found}
    end
  end

  defp ensure_can_manage(%User{} = actor, %Tenant{} = tenant) do
    if Authorization.can?(Scope.for_user(actor, tenant), :tenant_manage) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  @doc """
  The user's membership role in the tenant (`"admin"` | `"member"`), or
  `nil` when the user is not a member. Accepts either structs or raw ids
  for either argument.

  Unlike `admin?/2` this returns the role itself, so callers (e.g.
  `BeamChat.Authorization.Scope.for_user/2`) can resolve the full
  permission bundle rather than a single boolean.
  """
  @spec member_role(struct() | Ecto.UUID.t(), struct() | Ecto.UUID.t()) :: String.t() | nil
  def member_role(tenant_or_id, user_or_id) do
    tenant_id = resolve_id(tenant_or_id)
    user_id = resolve_id(user_or_id)

    Repo.one(
      from(tm in TenantMember,
        where: tm.tenant_id == ^tenant_id and tm.user_id == ^user_id,
        select: tm.role
      )
    )
  end

  @doc """
  Boolean check: is the given user an `admin` of the given tenant?
  Accepts either structs or raw ids for either argument.
  """
  def admin?(tenant_or_id, user_or_id) do
    tenant_id = resolve_id(tenant_or_id)
    user_id = resolve_id(user_or_id)

    Repo.exists?(
      from(tm in TenantMember,
        where:
          tm.tenant_id == ^tenant_id and
            tm.user_id == ^user_id and
            tm.role == "admin"
      )
    )
  end

  @doc """
  List the tenants a given user is a member of. Accepts a user struct or id.
  """
  def list_tenants_for_user(user_or_id) do
    user_id = resolve_id(user_or_id)

    Repo.all(
      from(t in Tenant,
        join: tm in TenantMember,
        on: tm.tenant_id == t.id,
        where: tm.user_id == ^user_id,
        distinct: true
      )
    )
  end

  @doc "A changeset for forms (empty tenant by default)."
  def change_tenant(tenant \\ %Tenant{}), do: Tenant.changeset(tenant, %{})

  # Accept either a struct (with an `:id` field) or a raw id.
  defp resolve_id(%{id: id}), do: id
  defp resolve_id(id) when not is_struct(id), do: id
end
