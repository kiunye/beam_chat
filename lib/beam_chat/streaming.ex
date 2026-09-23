defmodule BeamChat.Streaming do
  @moduledoc """
  Radio station management for the LiveKit streaming feature.

  Stations are tenant-scoped and administered only by users holding the
  `:radio_manage` permission (tenant admins, global admins — see
  `BeamChat.Authorization.Roles`). Listeners never touch this context's
  admin functions; the public player reads stations and asks
  `BeamChat.Video.TokenService` for a subscribe-only LiveKit token.

  Every mutation:

    * re-checks the permission with a scope built against the station's
      own tenant (a global admin stays authorized, a demoted tenant
      admin does not), and
    * writes an audit row (`radio_station.*`).

  Reads run inside `Repo.with_tenant/3` so PostgreSQL RLS confines every
  query to the tenant in question.
  """

  import Ecto.Query

  alias BeamChat.Accounts.User
  alias BeamChat.Audit
  alias BeamChat.Authorization
  alias BeamChat.Authorization.Scope
  alias BeamChat.Repo
  alias BeamChat.Streaming.RadioStation
  alias BeamChat.Tenants

  @type station :: RadioStation.t()

  @doc """
  List the radio stations of `tenant`, ordered by name. RLS confines the
  query to the tenant, so a caller cannot enumerate another tenant's
  stations even with a forged id.
  """
  @spec list_stations(struct() | Ecto.UUID.t(), struct() | Ecto.UUID.t()) :: [station()]
  def list_stations(user_or_id, tenant_or_id) do
    tenant_id = id_of(tenant_or_id)

    Repo.with_tenant(tenant_id, id_of(user_or_id), fn ->
      from(s in RadioStation,
        where: s.tenant_id == ^tenant_id,
        order_by: [asc: s.name]
      )
      |> Repo.all()
    end)
  end

  @doc "Fetch one station by id, inside the tenant's RLS context."
  @spec get_station(struct() | Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: station() | nil
  def get_station(user_or_id, tenant_id, station_id) do
    Repo.with_tenant(tenant_id, id_of(user_or_id), fn ->
      Repo.get(RadioStation, station_id)
    end)
  end

  @doc "Fetch one station by slug, inside the tenant's RLS context."
  @spec get_station_by_slug(struct() | Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          station() | nil
  def get_station_by_slug(user_or_id, tenant_id, slug) do
    Repo.with_tenant(tenant_id, id_of(user_or_id), fn ->
      Repo.get_by(RadioStation, slug: slug)
    end)
  end

  @doc """
  Create a station in `tenant`. The actor must hold `:radio_manage`.

  Returns `{:ok, station}`, `{:error, :forbidden | :not_found}`, or
  `{:error, changeset}`.
  """
  @spec create_station(User.t(), struct() | Ecto.UUID.t(), map()) ::
          {:ok, station()} | {:error, :forbidden | :not_found | Ecto.Changeset.t()}
  def create_station(%User{} = actor, tenant_or_id, attrs) do
    with {:ok, tenant} <- fetch_tenant(tenant_or_id),
         :ok <- ensure_can_manage(actor, tenant) do
      changeset =
        %RadioStation{tenant_id: tenant.id, status: "offline", is_active: false}
        |> RadioStation.create_changeset(attrs)

      Repo.with_tenant(tenant.id, actor.id, fn -> insert_station(changeset, actor) end)
    end
  end

  defp insert_station(changeset, actor) do
    with :ok <- ensure_slug_available(changeset),
         {:ok, station} <- Repo.insert(changeset),
         {:ok, _} <- Audit.log(actor, "radio_station.created", station, %{}) do
      {:ok, station}
    end
  end

  @doc """
  Update a station's editable fields. The actor must hold `:radio_manage`
  for the station's tenant. LiveKit runtime fields (`status`, `ingress_id`,
  `metadata`) are never editable here.
  """
  @spec update_station(User.t(), station(), map()) ::
          {:ok, station()} | {:error, :forbidden | Ecto.Changeset.t()}
  def update_station(%User{} = actor, %RadioStation{} = station, attrs) do
    with {:ok, tenant} <- fetch_tenant(station.tenant_id),
         :ok <- ensure_can_manage(actor, tenant) do
      changeset = RadioStation.update_changeset(station, attrs)

      Repo.with_tenant(station.tenant_id, actor.id, fn ->
        apply_station_update(changeset, actor)
      end)
    end
  end

  defp apply_station_update(changeset, actor) do
    with {:ok, updated} <- Repo.update(changeset),
         {:ok, _} <- Audit.log(actor, "radio_station.updated", updated, %{}) do
      {:ok, updated}
    end
  end

  @doc """
  Delete a station. The actor must hold `:radio_manage` for the
  station's tenant.
  """
  @spec delete_station(User.t(), station()) ::
          {:ok, station()} | {:error, :forbidden | Ecto.Changeset.t()}
  def delete_station(%User{} = actor, %RadioStation{} = station) do
    with {:ok, tenant} <- fetch_tenant(station.tenant_id),
         :ok <- ensure_can_manage(actor, tenant) do
      Repo.with_tenant(station.tenant_id, actor.id, fn -> remove_station(station, actor) end)
    end
  end

  defp remove_station(station, actor) do
    with {:ok, deleted} <- Repo.delete(station),
         {:ok, _} <- Audit.log(actor, "radio_station.deleted", deleted, %{}) do
      {:ok, deleted}
    end
  end

  # -- shared plumbing ---------------------------------------------------------

  defp fetch_tenant(tenant_or_id) do
    case Tenants.get_tenant(id_of(tenant_or_id)) do
      %Tenants.Tenant{} = tenant -> {:ok, tenant}
      nil -> {:error, :not_found}
    end
  end

  defp ensure_can_manage(%User{} = actor, tenant) do
    if Authorization.can?(Scope.for_user(actor, tenant), :radio_manage) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  # Slug availability is pre-checked (instead of relying on the unique
  # index surfacing through `unique_constraint/1`) because a database-level
  # constraint violation inside `Repo.with_tenant/3` — a savepoint under the
  # SQL sandbox — rolls the savepoint back and degrades to `{:error, :rollback}`
  # before the changeset can be returned. The unique index remains the
  # last line of defence for the (rare) concurrent-create race.
  defp ensure_slug_available(changeset) do
    slug = Ecto.Changeset.get_field(changeset, :slug)

    if slug && Repo.get_by(RadioStation, slug: slug) do
      {:error, Ecto.Changeset.add_error(changeset, :slug, "has already been taken")}
    else
      :ok
    end
  end

  defp id_of(%{id: id}), do: id
  defp id_of(id) when is_binary(id), do: id
end
