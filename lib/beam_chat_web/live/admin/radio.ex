defmodule BeamChatWeb.AdminLive.Radio do
  @moduledoc """
  The platform-admin radio console: create stations, start/stop their
  LiveKit Ingress, and read the push credentials a running station hands
  to an external encoder.

  The route is gated by the `:admin` live_session
  (`require_permission :settings_access`), and every mutation is
  re-checked by `BeamChat.Streaming` against `:radio_manage` at the
  point of action — a demoted admin receives `{:error, :forbidden}`,
  surfaced here as a flash.
  """

  use BeamChatWeb, :live_view

  alias BeamChat.Streaming
  alias BeamChat.Streaming.RadioStation

  # Form-only fields; runtime state (status, ingress_id, metadata) is
  # owned by BeamChat.Streaming and the LiveKit webhook stream.
  @create_fields ~w(name slug description source_type source_url)
  @source_types ~w(url rtmp whip)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Radio console")
     |> assign(:active_nav, :admin_radio)
     |> assign(:source_type_options, Enum.map(@source_types, &{source_label(&1), &1}))
     |> assign(:form, station_form())
     |> refresh_stations()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6" id="admin-radio-page">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="space-y-1">
          <p class="text-label-sm uppercase tracking-[0.12em] text-base-content/50">
            Admin console
          </p>

          <h1 class="text-headline-lg">Radio console</h1>

          <p class="text-sm text-base-content/50">
            Provision stations and their LiveKit Ingress. Started stations expose a push
            URL and stream key for external encoders.
          </p>
        </div>

        <button
          type="button"
          phx-click="refresh"
          class="btn btn-ghost btn-sm gap-1.5"
          id="stations-refresh"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Refresh
        </button>
      </div>

      <%!-- Create form ------------------------------------------------------- --%>
      <section
        class="card bg-white border border-base-300 shadow-panel rounded-box"
        id="station-create"
      >
        <div class="card-body gap-4">
          <div class="flex items-center gap-2">
            <.icon name="hero-broadcast-pin" class="size-4 text-primary" />
            <h2 class="text-headline-sm">Create a station</h2>
          </div>

          <.form
            for={@form}
            id="station-form"
            phx-change="validate"
            phx-submit="save"
            class="grid gap-3 sm:grid-cols-2"
          >
            <.input
              field={@form[:name]}
              type="text"
              label="Name"
              placeholder="Horn FM"
              required
            />

            <div>
              <.input
                field={@form[:slug]}
                type="text"
                label="Slug"
                placeholder="horn-fm"
                required
              />
              <p class="text-label-sm text-base-content/50">
                Sets the permanent LiveKit room name (radio-slug).
              </p>
            </div>

            <.input
              field={@form[:source_type]}
              type="select"
              label="Source type"
              options={@source_type_options}
            />

            <%!-- Pull sources need the URL LiveKit Ingress fetches; push
                 sources get their endpoint FROM LiveKit on start. --%>
            <.input
              :if={url_source?(@form)}
              field={@form[:source_url]}
              type="text"
              label="Source URL"
              placeholder="https://example.com/stream"
              required
            />

            <div class="sm:col-span-2">
              <.input
                field={@form[:description]}
                type="text"
                label="Description"
                placeholder="What listeners will hear…"
              />
            </div>

            <div class="flex justify-end sm:col-span-2">
              <button type="submit" class="btn btn-primary gap-1.5" id="station-form-submit">
                <.icon name="hero-plus" class="size-4" /> Create station
              </button>
            </div>
          </.form>
        </div>
      </section>

      <%!-- Stations list ------------------------------------------------------ --%>
      <section
        class="card bg-white border border-base-300 shadow-panel rounded-box"
        id="stations-list"
      >
        <div class="flex flex-wrap items-center justify-between gap-3 border-b border-base-200 px-5 py-4">
          <div class="space-y-0.5">
            <h2 class="text-headline-sm">Stations</h2>
            <p class="text-sm text-base-content/50">
              <span class="tnum">{@station_count}</span>
              total · <span class="tnum">{@live_count}</span>
              on air
            </p>
          </div>
        </div>

        <div id="admin-station-rows" phx-update="stream" class="divide-y divide-base-200">
          <%!-- Streams have no native empty state — the only:block trick
               shows this card when the stream has no items. --%>
          <div id="admin-station-rows-empty" class="hidden only:block px-5 py-10 text-center">
            <.icon name="hero-signal" class="size-8 mx-auto text-base-content/30" />
            <p class="mt-2 text-sm text-base-content/50">
              No stations yet — create the first one above.
            </p>
          </div>

          <div :for={{id, station} <- @streams.stations} id={id} class="space-y-3 px-5 py-4">
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div class="min-w-0 space-y-1">
                <div class="flex flex-wrap items-center gap-2">
                  <p class="text-headline-sm truncate">{station.name}</p>
                  <span class="text-label-sm text-base-content/50 truncate">
                    @{station.slug}
                  </span>
                </div>

                <p :if={station.description} class="text-sm text-base-content/50">
                  {station.description}
                </p>

                <p class="text-label-sm text-base-content/50">
                  {source_label(station.source_type)}
                  <span
                    :if={station.source_type == "url" and station.source_url}
                    class="font-mono text-code-sm text-base-content/60"
                  >
                    {station.source_url}
                  </span>
                </p>
              </div>

              <div class="flex shrink-0 items-center gap-2">
                <.station_status_badge status={station.status} />

                <button
                  :if={not station.is_active}
                  type="button"
                  phx-click="start"
                  phx-value-id={station.id}
                  class="btn btn-primary btn-sm gap-1.5"
                  id={"start-#{station.id}"}
                >
                  <.icon name="hero-play" class="size-4" /> Start
                </button>

                <button
                  :if={station.is_active}
                  type="button"
                  phx-click="stop"
                  phx-value-id={station.id}
                  class="btn btn-outline btn-sm gap-1.5"
                  data-confirm={"Stop #{station.name}?"}
                  id={"stop-#{station.id}"}
                >
                  <.icon name="hero-stop" class="size-4" /> Stop
                </button>

                <button
                  type="button"
                  phx-click="delete"
                  phx-value-id={station.id}
                  class="btn btn-ghost btn-sm gap-1.5 text-error"
                  data-confirm={"Delete #{station.name}? This cannot be undone."}
                  id={"delete-#{station.id}"}
                >
                  <.icon name="hero-trash" class="size-4" /> Delete
                </button>
              </div>
            </div>

            <%!-- Admin-only: the push credentials LiveKit provisioned for
                 this station's Ingress (never exposed to listeners). --%>
            <div
              :if={has_ingress_details?(station)}
              class="space-y-2 rounded-box border border-base-200 bg-base-200/50 p-3"
              id={"ingress-#{station.id}"}
            >
              <p class="text-label-sm uppercase tracking-[0.08em] text-base-content/50">
                Ingress push details — admin only
              </p>

              <div class="grid gap-3 sm:grid-cols-2">
                <div class="min-w-0">
                  <p class="text-label-sm text-base-content/50">{push_url_label(station)}</p>
                  <p class="font-mono text-code-sm tnum break-all" id={"push-url-#{station.id}"}>
                    {station.metadata["push_url"]}
                  </p>
                </div>

                <div class="min-w-0">
                  <p class="text-label-sm text-base-content/50">Stream key</p>
                  <p class="font-mono text-code-sm tnum break-all" id={"stream-key-#{station.id}"}>
                    {station.metadata["stream_key"]}
                  </p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"station" => params}, socket) do
    changeset =
      params
      |> Map.take(@create_fields)
      |> station_changeset()
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :station))}
  end

  def handle_event("save", %{"station" => params}, socket) do
    case Streaming.create_station(socket.assigns.current_user, Map.take(params, @create_fields)) do
      {:ok, _station} ->
        {:noreply,
         socket
         |> put_flash(:info, "Station created. Start it when the source is ready.")
         |> assign(:form, station_form())
         |> refresh_stations()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, forbidden_flash())}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, changeset_form(changeset))}
    end
  end

  def handle_event("start", %{"id" => station_id}, socket) do
    {:noreply, with_station(socket, station_id, &start_requested/2)}
  end

  def handle_event("stop", %{"id" => station_id}, socket) do
    {:noreply, with_station(socket, station_id, &stop_requested/2)}
  end

  def handle_event("delete", %{"id" => station_id}, socket) do
    {:noreply, with_station(socket, station_id, &delete_requested/2)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, refresh_stations(socket)}
  end

  # ---------------------------------------------------------------------------
  # Station lifecycle
  # ---------------------------------------------------------------------------

  defp start_requested(socket, station) do
    case Streaming.start_station(socket.assigns.current_user, station) do
      {:ok, _updated} ->
        socket
        |> put_flash(:info, "#{station.name} is starting.")
        |> refresh_stations()

      {:error, :forbidden} ->
        put_flash(socket, :error, forbidden_flash())

      {:error, :already_active} ->
        put_flash(socket, :error, "#{station.name} is already running.")

      {:error, _reason} ->
        put_flash(
          socket,
          :error,
          "#{station.name} could not start — check the LiveKit configuration."
        )
    end
  end

  defp stop_requested(socket, station) do
    case Streaming.stop_station(socket.assigns.current_user, station) do
      {:ok, _updated} ->
        socket
        |> put_flash(:info, "#{station.name} stopped.")
        |> refresh_stations()

      {:error, :forbidden} ->
        put_flash(socket, :error, forbidden_flash())

      {:error, {:ingress_delete_failed, _reason}} ->
        put_flash(socket, :error, teardown_failed_flash(station))
    end
  end

  defp delete_requested(socket, station) do
    case Streaming.delete_station(socket.assigns.current_user, station) do
      {:ok, _deleted} ->
        socket
        |> put_flash(:info, "#{station.name} deleted.")
        |> refresh_stations()

      {:error, :forbidden} ->
        put_flash(socket, :error, forbidden_flash())

      {:error, {:ingress_delete_failed, _reason}} ->
        put_flash(socket, :error, teardown_failed_flash(station))
    end
  end

  # ---------------------------------------------------------------------------
  # Stations list
  # ---------------------------------------------------------------------------

  defp refresh_stations(socket) do
    stations = Streaming.list_stations()

    socket
    |> assign(:station_count, Enum.count(stations))
    |> assign(:live_count, Enum.count(stations, & &1.is_active))
    |> stream(:stations, stations, dom_id: &"station-#{&1.id}", reset: true)
  end

  # The station may have been deleted by another admin since the list was
  # rendered — fetch it fresh instead of trusting the streamed copy.
  defp with_station(socket, station_id, action) do
    case Streaming.get_station(station_id) do
      nil -> missing_station(socket)
      station -> action.(socket, station)
    end
  end

  defp missing_station(socket) do
    socket
    |> put_flash(:error, "That station no longer exists.")
    |> refresh_stations()
  end

  defp forbidden_flash, do: "You do not have permission to manage radio stations."

  defp teardown_failed_flash(station) do
    "LiveKit could not tear down #{station.name}'s Ingress — it was left untouched. Try again."
  end

  # ---------------------------------------------------------------------------
  # Create form
  # ---------------------------------------------------------------------------

  defp station_changeset(attrs \\ %{}) do
    %RadioStation{}
    |> RadioStation.create_changeset(attrs)
  end

  defp station_form, do: to_form(station_changeset(), as: :station)

  # create_station returns a changeset with no action set when the slug
  # pre-check fails — set :insert so the errors render on the form.
  defp changeset_form(changeset),
    do: to_form(Map.put(changeset, :action, :insert), as: :station)

  defp url_source?(form), do: form[:source_type] && form[:source_type].value == "url"

  # ---------------------------------------------------------------------------
  # Ingress details (admin-only)
  # ---------------------------------------------------------------------------

  defp has_ingress_details?(%RadioStation{is_active: true, metadata: metadata}) do
    is_map(metadata) and is_binary(metadata["push_url"]) and metadata["push_url"] != ""
  end

  defp has_ingress_details?(_station), do: false

  defp push_url_label(%RadioStation{source_type: "whip"}), do: "WHIP endpoint"
  defp push_url_label(_station), do: "RTMP push URL"
end
