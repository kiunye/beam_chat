defmodule BeamChatWeb.RadioLive.Index do
  @moduledoc """
  The listener-facing radio lineup: the platform's active stations as a
  card grid, with a LiveKit audio player per station.

  Listening needs no special permission — any signed-in member can join.
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
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Radio")
      |> assign(:active_nav, :radio)
      |> assign(:active_station_id, nil)
      |> assign(:player_state, :idle)

    {:ok, stream_stations(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6" id="radio-page">
      <div class="space-y-1">
        <p class="text-label-sm uppercase tracking-[0.12em] text-base-content/50">
          Live audio
        </p>

        <h1 class="text-headline-lg">Radio</h1>

        <p class="text-sm text-base-content/50">
          Stations streaming live over LiveKit. One station plays at a time.
        </p>
      </div>

      <div
        class="grid gap-4 sm:grid-cols-2 xl:grid-cols-3"
        id="station-rows"
        phx-update="stream"
      >
        <%!-- Streams have no native empty state — the only:block trick
             shows this card when the stream has no items. --%>
        <div
          id="station-rows-empty"
          class="hidden only:block sm:col-span-2 xl:col-span-3 rounded-box border border-base-300 bg-white shadow-panel"
        >
          <div class="flex flex-col items-center gap-2 py-12 text-center">
            <.icon name="hero-signal" class="size-8 text-base-content/30" />
            <p class="text-headline-sm">Nothing on air right now</p>
            <p class="text-sm text-base-content/50">
              No stations are live. Check back soon.
            </p>
          </div>
        </div>

        <article
          :for={{id, station} <- @streams.stations}
          id={id}
          class="card bg-white border border-base-300 shadow-panel rounded-box transition-shadow hover:shadow-raised"
        >
          <div class="card-body gap-4">
            <div class="flex items-start justify-between gap-3">
              <h2 class="text-headline-sm truncate">{station.name}</h2>
              <.station_status_badge status={station.status} />
            </div>

            <p :if={station.description} class="text-sm text-base-content/50 line-clamp-2">
              {station.description}
            </p>

            <%!-- Player controls live inside the RadioPlayer hook's
                 container: the hook creates and attaches a hidden <audio>
                 element here when the station connects. Keep the ids and
                 the data-room / phx-hook wiring exactly as the hook
                 expects (assets/js/hooks/radio_player.js). --%>
            <div class="flex items-center justify-end border-t border-base-200 pt-3">
              <div
                id={"player-#{station.id}"}
                phx-hook="RadioPlayer"
                data-room={room_name(station)}
                class="flex items-center gap-2"
              >
                <button
                  :if={@active_station_id != station.id}
                  type="button"
                  phx-click="listen"
                  phx-value-id={station.id}
                  class="btn btn-primary btn-sm gap-1.5"
                  id={"listen-#{station.id}"}
                >
                  <.icon name="hero-play" class="size-4" /> Listen
                </button>

                <span
                  :if={@active_station_id == station.id && @player_state == :connecting}
                  class="text-label-sm text-base-content/50"
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
                  class="text-label-sm text-error"
                  id={"player-error-#{station.id}"}
                >
                  Could not connect
                </span>

                <button
                  :if={@active_station_id == station.id}
                  type="button"
                  phx-click="stop_listen"
                  class="btn btn-ghost btn-sm gap-1.5"
                  id={"stop-#{station.id}"}
                >
                  <.icon name="hero-stop" class="size-4" /> Stop
                </button>
              </div>
            </div>
          </div>
        </article>
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

  defp stream_stations(socket) do
    stations = Streaming.list_active_stations()

    socket
    |> assign(:stations_list, stations)
    |> stream(:stations, stations, dom_id: &"station-#{&1.id}", reset: true)
  end

  # Streamed items do not re-render when other assigns change; the player
  # controls live inside the streamed rows, so every player-state change
  # must re-stream the items (AGENTS.md LiveView streams).
  defp restream_stations(socket), do: stream_stations(socket)

  defp find_active_station(socket, station_id),
    do: Enum.find(socket.assigns.stations_list, &(&1.id == station_id))

  defp station_gone(socket) do
    socket
    |> put_flash(:error, "That station is no longer available.")
    |> stream_stations()
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
