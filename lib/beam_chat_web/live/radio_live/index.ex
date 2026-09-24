defmodule BeamChatWeb.RadioLive.Index do
  @moduledoc """
  The listener-facing radio lineup: the active stations of the tenant,
  with a LiveKit audio player per station.

  Listening needs no special permission — any tenant member can join.
  The token issued per listen click is **subscribe-only**
  (`BeamChat.Video.TokenService.generate_listener_token/3`), so listeners
  can never publish into a station's room.

  One station plays at a time: starting a second station first
  disconnects the current one (the hook for the previous room receives a
  `radio_disconnect` push event).
  """

  use BeamChatWeb, :live_view

  alias BeamChat.Streaming
  alias BeamChat.Video.TokenService

  @impl true
  def mount(params, session, socket) do
    socket =
      socket
      |> assign(:page_title, "Radio")
      |> assign_active_tenant(params, session)
      |> assign(:active_station_id, nil)
      |> assign(:player_state, :idle)

    {:ok, stream_stations(socket, socket.assigns.current_user, socket.assigns.tenant)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto space-y-4">
      <h1 class="text-xl font-display font-semibold text-base-content">Radio</h1>

      <div
        class="rounded-box border border-base-300 bg-base-100 shadow-sm"
        id="station-rows"
        phx-update="stream"
      >
        <p id="station-rows-empty" class="hidden only:block text-sm text-base-content/60 p-4">
          No stations are live in this tenant right now.
        </p>

        <div
          :for={{id, station} <- @streams.stations}
          id={id}
          class="flex items-center justify-between gap-3 p-4 border-b border-base-200 last:border-b-0"
        >
          <div class="min-w-0">
            <p class="font-medium text-sm truncate">{station.name}</p>
            <p :if={station.description} class="text-xs text-base-content/60 truncate">
              {station.description}
            </p>
          </div>

          <div class="flex items-center gap-2 shrink-0">
            <.station_status_badge status={station.status} />

            <div id={"player-#{station.id}"} phx-hook="RadioPlayer" data-room={room_name(station)}>
              <button
                :if={@active_station_id != station.id}
                type="button"
                phx-click="listen"
                phx-value-id={station.id}
                class="btn btn-primary btn-xs"
                id={"listen-#{station.id}"}
              >
                Listen
              </button>

              <span
                :if={@active_station_id == station.id && @player_state == :connecting}
                class="text-xs text-base-content/60"
                id={"connecting-#{station.id}"}
              >
                Connecting…
              </span>

              <span
                :if={@active_station_id == station.id && @player_state == :listening}
                class="badge badge-success badge-sm"
                id={"listening-#{station.id}"}
              >
                On air
              </span>

              <span
                :if={@active_station_id == station.id && @player_state == :error}
                class="text-xs text-error"
                id={"player-error-#{station.id}"}
              >
                Could not connect
              </span>

              <button
                :if={@active_station_id == station.id}
                type="button"
                phx-click="stop_listen"
                class="btn btn-ghost btn-xs"
                id={"stop-#{station.id}"}
              >
                Stop
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("listen", %{"id" => station_id}, socket) do
    user = socket.assigns.current_user

    case find_active_station(socket, station_id) do
      nil ->
        {:noreply, station_gone(socket)}

      station ->
        socket = disconnect_active(socket)
        room = room_name(station)

        case TokenService.generate_listener_token(user, room) do
          {:ok, %{token: token, url: url}} ->
            {:noreply,
             socket
             |> assign(:active_station_id, station.id)
             |> assign(:player_state, :connecting)
             |> push_event("radio_connect", %{room: room, token: token, url: url})
             |> restream_stations()}

          {:error, :not_configured} ->
            {:noreply,
             socket
             |> assign(:player_state, :error)
             |> put_flash(:error, "Radio is not configured on this server.")}
        end
    end
  end

  def handle_event("stop_listen", _params, socket) do
    {:noreply,
     socket
     |> disconnect_active()
     |> assign(:player_state, :idle)
     |> restream_stations()}
  end

  def handle_event("radio_connected", _params, socket) do
    {:noreply,
     socket
     |> assign(:player_state, :listening)
     |> restream_stations()}
  end

  def handle_event("radio_disconnected", _params, socket) do
    {:noreply,
     socket
     |> assign(:active_station_id, nil)
     |> assign(:player_state, :idle)
     |> restream_stations()}
  end

  def handle_event("radio_error", _params, socket) do
    {:noreply,
     socket
     |> assign(:player_state, :error)
     |> restream_stations()}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp stream_stations(socket, _user, nil) do
    socket
    |> assign(:stations_list, [])
    |> stream(:stations, [], reset: true)
  end

  defp stream_stations(socket, user, tenant) do
    stations = Streaming.list_active_stations(user, tenant)

    socket
    |> assign(:stations_list, stations)
    |> stream(:stations, stations, dom_id: &"station-#{&1.id}", reset: true)
  end

  # Streamed items do not re-render when other assigns change; the player
  # controls live inside the streamed rows, so every player-state change
  # must re-stream the items (AGENTS.md LiveView streams).
  defp restream_stations(socket) do
    stream_stations(socket, socket.assigns.current_user, socket.assigns.tenant)
  end

  defp find_active_station(socket, station_id) do
    Enum.find(socket.assigns.stations_list, &(&1.id == station_id))
  end

  defp station_gone(socket) do
    socket
    |> put_flash(:error, "That station is no longer available.")
    |> stream_stations(socket.assigns.current_user, socket.assigns.tenant)
  end

  # One station at a time: disconnect_active is nil-safe, so starting a new
  # station first tears down the previous stream (if any).
  defp disconnect_active(socket) do
    case find_active_station(socket, socket.assigns.active_station_id) do
      nil ->
        socket

      station ->
        socket
        |> assign(:active_station_id, nil)
        |> push_event("radio_disconnect", %{room: room_name(station)})
    end
  end

  defp room_name(%{} = station), do: Streaming.livekit_room_name(station)
end
