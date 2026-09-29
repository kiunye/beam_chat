defmodule BeamChat.Streaming do
  @moduledoc """
  Radio station management for the LiveKit streaming feature.

  Stations are platform-wide (no tenant boundary in v2) and administered
  only by platform admins (the `:radio_manage` permission). Listeners
  never touch this context's admin functions; the public player reads
  stations and asks `BeamChat.Video.TokenService` for a subscribe-only
  LiveKit token.

  Every mutation re-checks the permission against the actor's platform
  role — a demoted admin loses radio powers immediately (PRD §4.5:
  sensitive checks are re-verified at the point of action).
  """

  import Ecto.Query

  alias BeamChat.Accounts.User
  alias BeamChat.Authorization
  alias BeamChat.Repo
  alias BeamChat.Streaming.IngressClient
  alias BeamChat.Streaming.RadioStation

  @type station :: RadioStation.t()

  ## Reads

  @doc "All radio stations, ordered by name."
  @spec list_stations() :: [station()]
  def list_stations do
    from(s in RadioStation, order_by: [asc: s.name])
    |> Repo.all()
  end

  @doc "Fetch one station by id."
  @spec get_station(Ecto.UUID.t()) :: station() | nil
  def get_station(station_id), do: Repo.get(RadioStation, station_id)

  @doc "Fetch one station by slug."
  @spec get_station_by_slug(String.t()) :: station() | nil
  def get_station_by_slug(slug) when is_binary(slug),
    do: Repo.get_by(RadioStation, slug: slug)

  @doc """
  The platform's *active* stations — the listener-facing lineup. Inactive
  stations are excluded so the public player never lists dead sources.
  """
  @spec list_active_stations() :: [station()]
  def list_active_stations do
    from(s in RadioStation,
      where: s.is_active == true,
      order_by: [asc: s.name]
    )
    |> Repo.all()
  end

  ## Mutations (admin-only)

  @doc """
  Create a station. The actor must hold `:radio_manage` (platform admin).

  Returns `{:ok, station}`, `{:error, :forbidden}`, or
  `{:error, changeset}`.
  """
  @spec create_station(User.t(), map()) ::
          {:ok, station()} | {:error, :forbidden | Ecto.Changeset.t()}
  def create_station(%User{} = actor, attrs) when is_map(attrs) do
    with :ok <- ensure_radio_manage(actor) do
      changeset =
        %RadioStation{status: "offline", is_active: false}
        |> RadioStation.create_changeset(attrs)

      with :ok <- ensure_slug_available(changeset) do
        Repo.insert(changeset)
      end
    end
  end

  @doc """
  Update a station's editable fields. The actor must hold
  `:radio_manage`. LiveKit runtime fields (`status`, `ingress_id`,
  `metadata`) are never editable here.
  """
  @spec update_station(User.t(), station(), map()) ::
          {:ok, station()} | {:error, :forbidden | Ecto.Changeset.t()}
  def update_station(%User{} = actor, %RadioStation{} = station, attrs) when is_map(attrs) do
    with :ok <- ensure_radio_manage(actor) do
      station
      |> RadioStation.update_changeset(attrs)
      |> Repo.update()
    end
  end

  @doc """
  Delete a station. The actor must hold `:radio_manage`. A running
  station is torn down first so no Ingress outlives its station row.
  """
  @spec delete_station(User.t(), station()) ::
          {:ok, station()} | {:error, :forbidden | {:ingress_delete_failed, term()}}
  def delete_station(%User{} = actor, %RadioStation{} = station) do
    with :ok <- ensure_radio_manage(actor),
         :ok <- delete_remote_ingress(station) do
      Repo.delete(station)
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

  The actor must hold `:radio_manage`. On success the station flips to
  `is_active: true` / `status: "starting"`, and the webhook stream
  (`ingress_started`) later moves it to `"live"`. The Ingress call
  happens *outside* the database transaction — external side effects
  must never sit inside one.

  Returns `{:ok, station}`, `{:error, :forbidden | :already_active}`, or
  `{:error, reason}` when provisioning failed (the station is then
  marked `status: "error"`).
  """
  @spec start_station(User.t(), station()) ::
          {:ok, station()} | {:error, :forbidden | :already_active | term()}
  def start_station(%User{} = actor, %RadioStation{} = station) do
    with :ok <- ensure_radio_manage(actor),
         :ok <- ensure_not_active(station) do
      case IngressClient.create_ingress(ingress_attrs(station)) do
        {:ok, info} -> mark_started(station, info)
        {:error, reason} -> mark_start_failed(station, reason)
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
          {:ok, station()} | {:error, :forbidden | {:ingress_delete_failed, term()}}
  def stop_station(%User{} = actor, %RadioStation{} = station) do
    with :ok <- ensure_radio_manage(actor),
         :ok <- delete_remote_ingress(station) do
      mark_stopped(station)
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
    case Repo.get_by(RadioStation, ingress_id: ingress_id) do
      nil -> {:error, :not_found}
      station -> apply_ingress_status(station, status_for_event(event))
    end
  end

  defp apply_ingress_status(%RadioStation{is_active: false}, _status), do: :ok
  defp apply_ingress_status(%RadioStation{} = _station, nil), do: :ok

  defp apply_ingress_status(%RadioStation{} = station, status) do
    if station.status == status do
      :ok
    else
      changeset = RadioStation.status_changeset(station, status)
      {:ok, _updated} = Repo.update(changeset)
      :ok
    end
  end

  defp status_for_event("ingress_started"), do: "live"
  defp status_for_event("ingress_ended"), do: "offline"
  defp status_for_event("ingress_failed"), do: "error"
  defp status_for_event(_other), do: nil

  defp ensure_radio_manage(%User{} = actor) do
    Authorization.ensure_permission(actor, :radio_manage)
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

  defp mark_started(%RadioStation{} = station, info) do
    metadata =
      Map.merge(station.metadata, %{"push_url" => info.url, "stream_key" => info.stream_key})

    changeset =
      Ecto.Changeset.change(station,
        is_active: true,
        status: "starting",
        ingress_id: info.ingress_id,
        metadata: metadata
      )

    Repo.update(changeset)
  end

  defp mark_start_failed(%RadioStation{} = station, reason) do
    changeset = Ecto.Changeset.change(station, status: "error")
    {:ok, _updated} = Repo.update(changeset)
    {:error, reason}
  end

  defp mark_stopped(%RadioStation{} = station) do
    changeset =
      Ecto.Changeset.change(station,
        is_active: false,
        status: "offline",
        ingress_id: nil,
        metadata: %{}
      )

    Repo.update(changeset)
  end

  # Slug availability is pre-checked (instead of relying on the unique
  # index surfacing through `unique_constraint/1`) so the admin form gets
  # a friendly field error; the unique index remains the last line of
  # defence for the (rare) concurrent-create race.
  defp ensure_slug_available(changeset) do
    slug = Ecto.Changeset.get_field(changeset, :slug)

    if slug && Repo.get_by(RadioStation, slug: slug) do
      {:error, Ecto.Changeset.add_error(changeset, :slug, "has already been taken")}
    else
      :ok
    end
  end
end
