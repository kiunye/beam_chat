defmodule BeamChatWeb.RadioAdminLive do
  @moduledoc """
  Radio station management for users holding the `:radio_manage`
  permission (tenant admins, global admins).

  The route is gated by the `{:require_permission, :radio_manage}`
  `on_mount` hook in the router's `:radio_manage` live session; every
  mutating handler still goes through the permission-checked context
  functions in `BeamChat.Streaming`, which enforce `:radio_manage`
  against the station's own tenant.
  """

  use BeamChatWeb, :live_view

  alias BeamChat.Repo
  alias BeamChat.Streaming
  alias BeamChat.Streaming.RadioStation
  alias BeamChat.Tenants

  @impl true
  def mount(params, session, socket) do
    user = socket.assigns.current_user
    tenants = Tenants.list_tenants_for_user(user)
    active_id = params["tenant"] || session["active_tenant_id"]
    tenant = Enum.find(tenants, &(&1.id == active_id)) || List.first(tenants)

    socket =
      socket
      |> assign(:page_title, "Radio")
      |> assign(:tenants, tenants)
      |> assign(:tenant, tenant)
      |> assign(:tenant_form, to_form(%{"tenant_id" => tenant && tenant.id}, as: :switcher))
      |> assign(:show_create, false)
      |> assign(draft_assigns(new_draft()))

    {:ok, stream_stations(socket, tenant, user)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      case params["tenant"] do
        nil ->
          socket

        tenant_id ->
          tenant = Enum.find(socket.assigns.tenants, &(&1.id == tenant_id))

          if tenant do
            # Keep the process tenant context in sync with the tenant this
            # view renders (same reasoning as RoomTreeLive's handle_params).
            Repo.set_tenant_context(tenant.id, socket.assigns.current_user.id)

            socket
            |> assign(:tenant, tenant)
            |> assign(:tenant_form, to_form(%{"tenant_id" => tenant.id}, as: :switcher))
            |> stream_stations(tenant, socket.assigns.current_user)
          else
            socket
          end
      end

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("tenant-selected", %{"switcher" => %{"tenant_id" => tenant_id}}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/radio?tenant=#{tenant_id}")}
  end

  def handle_event("toggle-create", _params, socket) do
    {:noreply, assign(socket, :show_create, not socket.assigns.show_create)}
  end

  def handle_event("validate", %{"station" => params}, socket) do
    draft = merge_draft(socket.assigns.draft, params)
    {:noreply, assign(socket, draft_assigns(draft))}
  end

  def handle_event("save", %{"station" => params}, socket) do
    user = socket.assigns.current_user
    tenant = socket.assigns.tenant
    draft = merge_draft(socket.assigns.draft, params)

    case Streaming.create_station(user, tenant, draft) do
      {:ok, _station} ->
        {:noreply,
         socket
         |> put_flash(:info, "Station \"#{draft["name"]}\" created.")
         |> assign(draft_assigns(new_draft()))
         |> assign(:show_create, false)
         |> stream_stations(tenant, user)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have access.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "No active tenant — cannot create a station.")}

      {:error, changeset} ->
        {:noreply, assign(socket, draft: draft, form: to_form(changeset, as: :station))}
    end
  end

  def handle_event("start", %{"id" => station_id}, socket) do
    user = socket.assigns.current_user
    tenant = socket.assigns.tenant

    case station_for_event(socket, station_id) do
      nil ->
        {:noreply, station_gone(socket)}

      station ->
        case Streaming.start_station(user, station) do
          {:ok, _started} ->
            {:noreply,
             socket
             |> put_flash(:info, "Station starting — status updates when the stream goes live.")
             |> stream_stations(tenant, user)}

          {:error, :already_active} ->
            {:noreply, stream_stations(socket, tenant, user)}

          {:error, :forbidden} ->
            {:noreply, put_flash(socket, :error, "You do not have access.")}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, "Could not start the station: #{inspect(reason)}")
             |> stream_stations(tenant, user)}
        end
    end
  end

  def handle_event("stop", %{"id" => station_id}, socket) do
    user = socket.assigns.current_user
    tenant = socket.assigns.tenant

    case station_for_event(socket, station_id) do
      nil ->
        {:noreply, station_gone(socket)}

      station ->
        case Streaming.stop_station(user, station) do
          {:ok, _stopped} ->
            {:noreply,
             socket
             |> put_flash(:info, "Station stopped.")
             |> stream_stations(tenant, user)}

          {:error, :forbidden} ->
            {:noreply, put_flash(socket, :error, "You do not have access.")}

          {:error, {:ingress_delete_failed, reason}} ->
            {:noreply,
             socket
             |> put_flash(:error, "LiveKit refused the stop: #{inspect(reason)}")
             |> stream_stations(tenant, user)}
        end
    end
  end

  def handle_event("delete", %{"id" => station_id}, socket) do
    user = socket.assigns.current_user
    tenant = socket.assigns.tenant

    case station_for_event(socket, station_id) do
      nil ->
        {:noreply, station_gone(socket)}

      station ->
        case Streaming.delete_station(user, station) do
          {:ok, _deleted} ->
            {:noreply,
             socket
             |> put_flash(:info, "Station deleted.")
             |> stream_stations(tenant, user)}

          {:error, :forbidden} ->
            {:noreply, put_flash(socket, :error, "You do not have access.")}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp station_for_event(socket, station_id) do
    Enum.find(socket.assigns.stations_list, &(&1.id == station_id))
  end

  defp station_gone(socket) do
    socket
    |> put_flash(:error, "That station no longer exists.")
    |> stream_stations(socket.assigns.tenant, socket.assigns.current_user)
  end

  # Streams are not enumerable, so the handlers keep a plain list around for
  # per-event station lookups (AGENTS.md LiveView streams).
  defp stream_stations(socket, nil, _user) do
    socket
    |> assign(:stations_list, [])
    |> assign(:station_count, 0)
    |> stream(:stations, [], reset: true)
  end

  defp stream_stations(socket, tenant, user) do
    stations = Streaming.list_stations(user, tenant)

    socket
    |> assign(:stations_list, stations)
    |> assign(:station_count, length(stations))
    |> stream(:stations, stations, dom_id: &"station-#{&1.id}", reset: true)
  end

  defp new_draft do
    %{"name" => "", "slug" => "", "description" => "", "source_type" => "url", "source_url" => ""}
  end

  defp merge_draft(draft, params) when is_map(params), do: Map.merge(draft, Map.new(params))

  defp draft_assigns(draft) do
    [draft: draft, form: draft_to_form(draft)]
  end

  defp draft_to_form(draft) do
    changeset =
      %RadioStation{}
      |> RadioStation.create_changeset(draft)

    to_form(changeset, as: :station)
  end

  defp tenant_options(tenants) do
    Enum.map(tenants, &{&1.name, &1.id})
  end

  defp status_badge(status) do
    case status do
      "live" -> "badge-success"
      "starting" -> "badge-warning"
      "error" -> "badge-error"
      _other -> "badge-ghost"
    end
  end

  defp source_label("url"), do: "Pull (HLS/SRT)"
  defp source_label("rtmp"), do: "Push (RTMP)"
  defp source_label("whip"), do: "Push (WHIP)"

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto space-y-4">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h1 class="text-xl font-display font-semibold text-base-content">Radio</h1>

        <div class="flex items-center gap-2">
          <.form
            for={@tenant_form}
            id="tenant-switcher"
            phx-change="tenant-selected"
            class="flex items-center gap-2"
          >
            <.input
              field={@tenant_form[:tenant_id]}
              type="select"
              options={tenant_options(@tenants)}
              label="Tenant"
            />
          </.form>

          <button
            :if={@tenant}
            type="button"
            phx-click="toggle-create"
            class="btn btn-primary btn-sm"
            id="toggle-create-button"
          >
            {if @show_create, do: "Close", else: "New station"}
          </button>
        </div>
      </div>

      <p :if={!@tenant} class="text-sm text-base-content/60">
        You are not a member of any tenant yet.
      </p>

      <div
        :if={@tenant && @show_create}
        class="rounded-box border border-base-300 bg-base-100 shadow-sm p-4"
      >
        <h2 class="text-sm font-semibold mb-2">New station</h2>
        <.form for={@form} id="station-form" phx-change="validate" phx-submit="save" class="space-y-3">
          <.input field={@form[:name]} type="text" label="Name" />
          <.input
            field={@form[:slug]}
            type="text"
            label="Slug (lowercase/numbers/hyphens — becomes the radio-<slug> room)"
          />
          <.input field={@form[:description]} type="text" label="Description" />
          <.input
            field={@form[:source_type]}
            type="select"
            label="Source"
            options={[
              {"Pull (HLS/SRT URL)", "url"},
              {"Push (RTMP)", "rtmp"},
              {"Push (WHIP / live show)", "whip"}
            ]}
          />
          <.input
            field={@form[:source_url]}
            type="text"
            label="Stream URL (required for pull sources)"
          />
          <div class="flex justify-end">
            <.button type="submit" class="btn btn-primary btn-sm">Create station</.button>
          </div>
        </.form>
      </div>

      <p :if={@tenant && @station_count == 0} class="text-sm text-base-content/60">
        No stations in this tenant yet.
      </p>

      <div
        :if={@tenant && @station_count > 0}
        class="rounded-box border border-base-300 bg-base-100 shadow-sm"
      >
        <table class="table">
          <thead>
            <tr class="text-base-content/60">
              <th class="text-xs uppercase tracking-wide font-semibold">Station</th>
              <th class="text-xs uppercase tracking-wide font-semibold">Status</th>
              <th class="text-xs uppercase tracking-wide font-semibold text-right">Actions</th>
            </tr>
          </thead>
          <tbody id="station-rows" phx-update="stream">
            <tr :for={{id, station} <- @streams.stations} id={id}>
              <td>
                <p class="font-medium text-sm">{station.name}</p>
                <p class="text-xs text-base-content/60">
                  {source_label(station.source_type)} · radio-{station.slug}
                </p>
                <p
                  :if={station.is_active and station.metadata["push_url"]}
                  class="text-xs text-base-content/50 mt-1"
                >
                  Push URL: {station.metadata["push_url"]}
                </p>
                <p
                  :if={station.is_active and station.metadata["stream_key"]}
                  class="text-xs text-base-content/50"
                >
                  Stream key: {station.metadata["stream_key"]}
                </p>
              </td>
              <td>
                <span class={["badge badge-sm", status_badge(station.status)]}>
                  {station.status}
                </span>
              </td>
              <td>
                <div class="flex items-center justify-end gap-2">
                  <button
                    :if={!station.is_active}
                    type="button"
                    phx-click="start"
                    phx-value-id={station.id}
                    class="btn btn-primary btn-xs"
                    id={"start-#{station.id}"}
                  >
                    Start
                  </button>
                  <button
                    :if={station.is_active}
                    type="button"
                    phx-click="stop"
                    phx-value-id={station.id}
                    class="btn btn-outline btn-xs"
                    id={"stop-#{station.id}"}
                  >
                    Stop
                  </button>
                  <button
                    type="button"
                    phx-click="delete"
                    phx-value-id={station.id}
                    class="btn btn-ghost btn-xs text-error"
                    id={"delete-#{station.id}"}
                  >
                    Delete
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
