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
  alias BeamChat.Repo
  alias BeamChat.Streaming.IngressClient
  alias BeamChat.Streaming.RadioStation
  alias BeamChat.Tenants

  @type station :: RadioStation.t()

  # Reads pass the acting user's id as the GUC user for parity with the
  # write paths; the radio_stations policies consult only the tenant GUC.
  @doc """
  List the radio stations of `tenant`, ordered by name. RLS confines the
  query to the tenant, so a caller cannot enumerate another tenant's
  stations even with a forged id.
  """
  @spec list_stations(struct() | Ecto.UUID.t(), struct() | Ecto.UUID.t()) :: [station()]
  def list_stations(user_or_id, tenant_or_id) do
    tenant_id = Authorization.id_of(tenant_or_id)

    Repo.with_tenant(tenant_id, Authorization.id_of(user_or_id), fn ->
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
    Repo.with_tenant(tenant_id, Authorization.id_of(user_or_id), fn ->
      Repo.get(RadioStation, station_id)
    end)
  end

  @doc "Fetch one station by slug, inside the tenant's RLS context."
  @spec get_station_by_slug(struct() | Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          station() | nil
  def get_station_by_slug(user_or_id, tenant_id, slug) do
    Repo.with_tenant(tenant_id, Authorization.id_of(user_or_id), fn ->
      Repo.get_by(RadioStation, slug: slug)
    end)
  end

  @doc """
  The tenant's *active* stations — the listener-facing lineup. Inactive
  stations are excluded so the public player never lists dead sources.
  """
  @spec list_active_stations(struct() | Ecto.UUID.t(), struct() | Ecto.UUID.t()) :: [station()]
  def list_active_stations(user_or_id, tenant_or_id) do
    list_stations(user_or_id, tenant_or_id)
    |> Enum.filter(& &1.is_active)
  end

  @doc """
  Create a station in `tenant`. The actor must hold `:radio_manage`.

  Returns `{:ok, station}`, `{:error, :forbidden | :not_found}`, or
  `{:error, changeset}`.
  """
  @spec create_station(User.t(), struct() | Ecto.UUID.t(), map()) ::
          {:ok, station()} | {:error, :forbidden | :not_found | Ecto.Changeset.t()}
  def create_station(%User{} = actor, tenant_or_id, attrs) do
    with {:ok, tenant} <-
           Authorization.ensure_tenant_permission(actor, tenant_or_id, :radio_manage) do
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
    with {:ok, _tenant} <-
           Authorization.ensure_tenant_permission(actor, station.tenant_id, :radio_manage) do
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
    with {:ok, _tenant} <-
           Authorization.ensure_tenant_permission(actor, station.tenant_id, :radio_manage) do
      Repo.with_tenant(station.tenant_id, actor.id, fn -> remove_station(station, actor) end)
    end
  end

  defp remove_station(station, actor) do
    with {:ok, deleted} <- Repo.delete(station),
         {:ok, _} <- Audit.log(actor, "radio_station.deleted", deleted, %{}) do
      {:ok, deleted}
    end
  end

  # -- stream lifecycle --------------------------------------------------------

  @doc """
  The LiveKit room a station publishes into. Derived from the (immutable)
  slug so station rooms are predictable and human-readable.
  """
  @spec livekit_room_name(station()) :: String.t()
  def livekit_room_name(%RadioStation{slug: slug}), do: "radio-" <> slug

  @doc """
  Activate a station: provision a LiveKit Ingress for its source.

  The actor must hold `:radio_manage` for the station's tenant. On
  success the station flips to `is_active: true` / `status: "starting"`,
  and the webhook stream (`ingress_started`) later moves it to
  `"live"`. The Ingress call happens *outside* the database transaction —
  external side effects must never sit inside one; the follow-up update
  and audit are transactional together.

  Returns `{:ok, station}`, `{:error, :forbidden | :already_active | :not_found}`
  or `{:error, reason}` when provisioning failed (the station is then
  marked `status: "error"`).
  """
  @spec start_station(User.t(), station()) ::
          {:ok, station()}
          | {:error, :forbidden | :already_active | :not_found | term()}
  def start_station(%User{} = actor, %RadioStation{} = station) do
    with {:ok, _tenant} <-
           Authorization.ensure_tenant_permission(actor, station.tenant_id, :radio_manage),
         :ok <- ensure_not_active(station) do
      case IngressClient.create_ingress(ingress_attrs(station)) do
        {:ok, info} -> mark_started(actor, station, info)
        {:error, reason} -> mark_start_failed(actor, station, reason)
      end
    end
  end

  @doc """
  Deactivate a station: tear down its LiveKit Ingress and return it to
  `"offline"`. Idempotent — stopping an already-offline station just
  re-writes the same local state.

  If the remote delete fails the station is left untouched and
  `{:error, {:ingress_delete_failed, reason}}` is returned: local state
  must never claim "stopped" while a live Ingress could still be feeding
  the room.
  """
  @spec stop_station(User.t(), station()) ::
          {:ok, station()}
          | {:error, :forbidden | :not_found | {:ingress_delete_failed, term()}}
  def stop_station(%User{} = actor, %RadioStation{} = station) do
    with {:ok, _tenant} <-
           Authorization.ensure_tenant_permission(actor, station.tenant_id, :radio_manage),
         :ok <- delete_remote_ingress(station) do
      mark_stopped(actor, station)
    end
  end

  @doc """
  Apply an Ingress lifecycle event from a LiveKit webhook:
  `ingress_started` → `"live"`, `ingress_ended` → `"offline"`,
  `ingress_failed` → `"error"`.

  Idempotent, and safe against out-of-order arrival: a station an admin
  already stopped (`is_active: false`) ignores events from its stale
  Ingress resource. Returns `:ok` or `{:error, :not_found}` for an
  unknown ingress id.
  """
  @spec apply_ingress_event(String.t(), String.t()) :: :ok | {:error, :not_found}
  def apply_ingress_event(ingress_id, event) when is_binary(ingress_id) and is_binary(event) do
    with {:ok, station} <- find_station_by_ingress_id(ingress_id) do
      apply_ingress_status(station, status_for_event(event))
    end
  end

  defp apply_ingress_status(%RadioStation{is_active: false}, _status), do: :ok
  defp apply_ingress_status(%RadioStation{} = _station, nil), do: :ok

  defp apply_ingress_status(%RadioStation{} = station, status) do
    if station.status == status do
      :ok
    else
      changeset = RadioStation.status_changeset(station, status)

      # The tenant id doubles as the (inert) GUC user: the radio_stations
      # policies consult only the tenant GUC, and webhooks carry no user.
      Repo.with_tenant(station.tenant_id, station.tenant_id, fn ->
        {:ok, _updated} = Repo.update(changeset)
        :ok
      end)
    end
  end

  defp status_for_event("ingress_started"), do: "live"
  defp status_for_event("ingress_ended"), do: "offline"
  defp status_for_event("ingress_failed"), do: "error"
  defp status_for_event(_other), do: nil

  # `radio_stations` is RLS-protected and webhooks arrive without tenant
  # context, so the station is located by scanning the (small, RLS-free)
  # tenants table and querying under each tenant's GUCs. Ingress state
  # events are rare; a denormalized lookup table can replace this if the
  # tenant count ever makes the scan matter.
  defp find_station_by_ingress_id(ingress_id) do
    Enum.reduce_while(Tenants.list_tenants(), {:error, :not_found}, fn tenant, acc ->
      found =
        Repo.with_tenant(tenant.id, tenant.id, fn ->
          Repo.get_by(RadioStation, ingress_id: ingress_id)
        end)

      case found do
        nil -> {:cont, acc}
        station -> {:halt, {:ok, station}}
      end
    end)
  end

  defp ensure_not_active(%RadioStation{is_active: true}), do: {:error, :already_active}
  defp ensure_not_active(%RadioStation{}), do: :ok

  defp delete_remote_ingress(%RadioStation{ingress_id: nil}), do: :ok

  defp delete_remote_ingress(%RadioStation{ingress_id: ingress_id}) do
    case IngressClient.delete_ingress(ingress_id) do
      :ok -> :ok
      {:error, reason} -> {:error, {:ingress_delete_failed, reason}}
    end
  end

  defp ingress_attrs(%RadioStation{} = station) do
    %{
      input_type: input_type_for(station.source_type),
      name: station.name,
      room_name: livekit_room_name(station),
      participant_identity: "radio-" <> station.slug,
      participant_name: station.name,
      url: station.source_url
    }
  end

  defp input_type_for("url"), do: :URL_INPUT
  defp input_type_for("rtmp"), do: :RTMP_INPUT
  defp input_type_for("whip"), do: :WHIP_INPUT

  defp mark_started(actor, station, info) do
    metadata =
      Map.merge(station.metadata, %{"push_url" => info.url, "stream_key" => info.stream_key})

    changeset =
      Ecto.Changeset.change(station,
        is_active: true,
        status: "starting",
        ingress_id: info.ingress_id,
        metadata: metadata
      )

    Repo.with_tenant(station.tenant_id, actor.id, fn ->
      with {:ok, updated} <- Repo.update(changeset),
           {:ok, _} <-
             Audit.log(actor, "radio_station.started", updated, %{ingress_id: info.ingress_id}) do
        {:ok, updated}
      end
    end)
  end

  defp mark_start_failed(actor, station, reason) do
    changeset = Ecto.Changeset.change(station, status: "error")

    Repo.with_tenant(station.tenant_id, actor.id, fn ->
      with {:ok, updated} <- Repo.update(changeset),
           {:ok, _} <-
             Audit.log(actor, "radio_station.start_failed", updated, %{reason: inspect(reason)}) do
        {:ok, updated}
      end
    end)

    {:error, reason}
  end

  defp mark_stopped(actor, station) do
    changeset =
      Ecto.Changeset.change(station,
        is_active: false,
        status: "offline",
        ingress_id: nil,
        metadata: %{}
      )

    Repo.with_tenant(station.tenant_id, actor.id, fn ->
      with {:ok, updated} <- Repo.update(changeset),
           {:ok, _} <- Audit.log(actor, "radio_station.stopped", updated, %{}) do
        {:ok, updated}
      end
    end)
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
end
