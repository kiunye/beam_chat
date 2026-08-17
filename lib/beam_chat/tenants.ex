defmodule BeamChat.Tenants do
  @moduledoc """
  Tenant (county/org) context for the multi-tenant hierarchical room redesign.

  Provides tenant CRUD plus membership management and the `admin?/2` check
  that backs both Row Level Security and UI gating (CATEGORY_REDESIGN.md §4.2).
  """
  import Ecto.Query, warn: false

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
  Remove a user's membership from a tenant. Returns `{:ok, member}` on
  success, `{:error, :not_found}` if no such membership exists, or
  `{:error, changeset}` if the delete fails.
  """
  def remove_member(tenant_or_id, user_or_id) do
    tenant_id = resolve_id(tenant_or_id)
    user_id = resolve_id(user_or_id)

    case Repo.get_by(TenantMember, tenant_id: tenant_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      member ->
        Repo.delete(member)
    end
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
