defmodule BeamChatWeb.RoomLive.Index do
  @moduledoc """
  Room directory for the active tenant: stats strip, visibility tabs,
  search, the grouped room-card grid, and pagination.
  """
  use BeamChatWeb, :live_view

  alias BeamChat.Rooms

  # Directory tabs map what the design calls "Administrative / Sectoral /
  # Paid / Secret" groupings onto the room visibility types the schema and
  # RLS already carry.
  @directory_tabs [
    {nil, "All rooms"},
    {"public", "Open"},
    {"private", "Members-only"},
    {"paid", "Paid advisory"},
    {"secret", "Secret committees"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    categories = Rooms.list_categories()
    form = to_form(%{"q" => "", "category_id" => "", "type" => ""}, as: :filter)

    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Room directory")
     |> assign(:active_tab, :rooms)
     |> assign(:categories, categories)
     |> assign(:directory_tabs, @directory_tabs)
     |> assign(:type_counts, Rooms.count_rooms_by_type(user))
     |> assign(:form, form)
     |> assign(:rooms, [])
     |> assign(:member_counts, %{})
     |> assign(:room_list_meta, %{total_count: 0, page: 1, limit: 50, page_count: 1})}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    q = params["q"] || ""
    category_id = params["category_id"] || ""
    type = normalize_tab_type(params["type"])

    result =
      Rooms.list_rooms_for_index(socket.assigns.current_user, %{
        search: q,
        category_id: category_id,
        type: type,
        page: params["page"]
      })

    form = to_form(%{"q" => q, "category_id" => category_id, "type" => type || ""}, as: :filter)

    {:noreply,
     socket
     |> assign(:rooms, result.rooms)
     |> assign(:member_counts, result.member_counts)
     |> assign(:room_list_meta, Map.take(result, [:total_count, :page, :limit, :page_count]))
     |> assign(:form, form)}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply,
     push_patch(socket,
       to: rooms_path(filter["q"], filter["category_id"], filter["type"])
     )}
  end

  def handle_event("set-type", %{"type" => type}, socket) do
    form = socket.assigns.form

    {:noreply,
     push_patch(socket,
       to: rooms_path(form_value(form, :q), form_value(form, :category_id), type)
     )}
  end

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6" id="rooms-directory">
      <!-- Eyebrow + headline + live state -->
      <div class="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
        <div class="space-y-1">
          <p class="text-label-sm uppercase tracking-[0.12em] text-slate-500">
            Tenant directory
          </p>

          <h1 class="font-display text-headline-lg tracking-tight text-slate-900">
            {tenant_name(assigns[:active_tenant])} room directory
          </h1>

          <p class="text-sm text-slate-600">
            Role-based county mesh hierarchy. Secret rooms only appear when you belong.
          </p>
        </div>

        <div class="flex items-center gap-2">
          <span class="civic-chip" data-state="on">
            <span class="size-1.5 rounded-full bg-emerald-500" /> Live sync · LiveView
          </span>
          <.link navigate={~p"/messages"} class="civic-chip" id="nav-direct-messages">
            Direct messages
          </.link>
        </div>
      </div>
      
    <!-- Type tabs with live counts -->
      <div class="flex flex-wrap gap-1.5" role="tablist" aria-label="Room visibility">
        <button
          :for={{type, label} <- @directory_tabs}
          type="button"
          role="tab"
          aria-selected={current_tab(assigns) == type}
          phx-click="set-type"
          phx-value-type={type}
          class={[
            "inline-flex items-center gap-2 rounded-md px-3 py-1.5 text-sm font-medium transition-colors",
            current_tab(assigns) == type && "bg-emerald-600 text-white",
            current_tab(assigns) != type &&
              "bg-white text-slate-600 border border-slate-200 hover:bg-slate-100"
          ]}
        >
          {label}
          <span class={[
            "rounded-full px-1.5 text-label-sm",
            current_tab(assigns) == type && "bg-emerald-500/30 text-emerald-50",
            current_tab(assigns) != type && "bg-slate-100 text-slate-600"
          ]}>
            {type_count(@type_counts, type)}
          </span>
        </button>
      </div>
      
    <!-- Search + category filters -->
      <.form
        for={@form}
        id="room-filter-form"
        phx-change="filter"
        class="flex flex-col gap-3 sm:flex-row sm:flex-wrap sm:items-end"
      >
        <div class="flex-1 min-w-[14rem]">
          <.input
            field={@form[:q]}
            type="text"
            label="Search"
            placeholder="Name or slug of a room…"
            phx-debounce="400"
          />
        </div>

        <div class="w-full sm:w-56">
          <.input
            field={@form[:category_id]}
            type="select"
            label="Category"
            prompt="All categories"
            options={Enum.map(@categories, fn c -> {c.name, c.id} end)}
          />
        </div>
      </.form>
      
    <!-- Grid + aside -->
      <div class="grid gap-6 lg:grid-cols-[19rem_minmax(0,1fr)] items-start">
        <aside class="space-y-4" id="directory-aside">
          <div class="rounded-lg border border-slate-200 bg-white p-4 shadow-civic-2">
            <h2 class="text-headline-sm text-slate-900 flex items-center gap-2">
              <.icon name="hero-map" class="size-4 text-emerald-600" /> Structure
            </h2>

            <p class="mt-1 text-body-md text-slate-600">
              {total_rooms(@type_counts)} rooms · {type_count(@type_counts, "private")} members-only
            </p>

            <ul class="mt-3 space-y-1.5" id="structure-tree">
              <li :for={room <- grouped_rooms(@rooms)} class="space-y-0.5">
                <.link
                  navigate={~p"/rooms/#{room.slug}"}
                  class="flex items-center gap-2 rounded-md px-2 py-1 text-sm text-slate-700 hover:bg-slate-100"
                >
                  <.icon name="hero-folder" class="size-4 text-slate-400" />
                  <span class="truncate">{room.name}</span>
                  <span class="ml-auto text-label-sm text-slate-400">
                    {@member_counts[room.id] || 0}
                  </span>
                </.link>
              </li>
            </ul>
          </div>

          <div class="rounded-lg border border-slate-200 bg-white p-4 shadow-civic-2">
            <h2 class="text-headline-sm text-slate-900">Demographics</h2>

            <dl class="mt-3 space-y-2 text-body-md">
              <div class="flex items-center justify-between">
                <dt class="text-slate-600">Rooms on mesh</dt>

                <dd class="tnum font-semibold text-slate-900">{total_rooms(@type_counts)}</dd>
              </div>
              <div class="flex items-center justify-between">
                <dt class="text-slate-600">Paid advisory</dt>

                <dd class="tnum font-semibold text-slate-900">{type_count(@type_counts, "paid")}</dd>
              </div>
              <div class="flex items-center justify-between">
                <dt class="text-slate-600">Secret committees</dt>

                <dd class="tnum font-semibold text-slate-900">
                  {type_count(@type_counts, "secret")}
                </dd>
              </div>
              <div class="flex items-center justify-between">
                <dt class="text-slate-600">Members-only</dt>

                <dd class="tnum font-semibold text-slate-900">
                  {type_count(@type_counts, "private")}
                </dd>
              </div>
            </dl>
          </div>
        </aside>

        <div class="space-y-6">
          <!-- Empty state -->
          <div
            :if={@rooms == []}
            class="rounded-lg border border-slate-200 bg-white p-8 text-center shadow-civic-2"
          >
            <p class="text-slate-700 font-medium">No rooms match your filters</p>

            <p class="text-sm text-slate-500 mt-2">
              Try clearing search or switch to another visibility tab.
            </p>
          </div>
          
    <!-- Card grid -->
          <div
            :if={@rooms != []}
            class="grid gap-4 md:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-3"
            id="room-list"
          >
            <article
              :for={room <- @rooms}
              id={"room-#{room.id}"}
              class={[
                "flex flex-col rounded-lg border bg-white p-4 shadow-civic-2 transition-shadow hover:shadow-civic-3",
                card_tone(row_tone(room))
              ]}
            >
              <div class="flex items-center justify-between gap-2">
                <span class={[
                  "rounded-full px-2 py-0.5 text-label-sm font-semibold",
                  type_pill(room.type)
                ]}>
                  {type_label(room.type)}
                </span>

                <span :if={room.category} class="text-label-sm text-slate-500">
                  {room.category.name}
                </span>
              </div>

              <h2 class="mt-3 font-display text-headline-sm text-slate-900 leading-snug">
                {room.name}
              </h2>

              <p :if={room.description} class="mt-1 text-sm text-slate-600 line-clamp-2">
                {room.description}
              </p>

              <div class="mt-3 flex items-center justify-between gap-2 text-xs text-slate-500">
                <span class="truncate">@{room.slug}</span>
                <span>
                  <.icon name="hero-users" class="size-3.5 inline-block align-[-2px] text-slate-400" />
                  <span class="tnum">{@member_counts[room.id] || 0} members</span>
                </span>
              </div>

              <div class="mt-4 flex items-center justify-between border-t border-slate-100 pt-3">
                <span class="text-label-sm text-slate-500">
                  Updated {relative_time(room.updated_at)}
                </span>

                <%= cond do %>
                  <% room.type == "paid" && room.is_paid -> %>
                    <.link
                      navigate={~p"/rooms/#{room.slug}"}
                      class="rounded-md bg-amber-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-amber-700"
                    >
                      Subscribe for {money(room.price)}{room.currency}
                    </.link>
                  <% room.type == "secret" -> %>
                    <span class="inline-flex items-center gap-1 rounded-md bg-red-50 px-3 py-1.5 text-sm font-semibold text-red-700">
                      <.icon name="hero-lock-closed" class="size-3.5" /> Restricted
                    </span>
                  <% true -> %>
                    <.link
                      navigate={~p"/rooms/#{room.slug}"}
                      class="rounded-md bg-emerald-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-emerald-700"
                    >
                      Enter room
                    </.link>
                <% end %>
              </div>
            </article>
          </div>
          
    <!-- Pagination -->
          <div
            :if={@room_list_meta.total_count > @room_list_meta.limit}
            class="flex flex-wrap items-center justify-center gap-3 pt-2 text-sm text-slate-600"
          >
            <span>
              Page {@room_list_meta.page} of {@room_list_meta.page_count}
              <span class="text-slate-400">· {@room_list_meta.total_count} rooms</span>
            </span>

            <div class="flex gap-2">
              <.link
                :if={@room_list_meta.page > 1}
                patch={~p"/rooms?#{rooms_page_params(@form, @room_list_meta.page - 1)}"}
                class="rounded-md border border-slate-300 bg-white px-3 py-1.5 font-medium text-slate-700 hover:bg-slate-50"
              >
                Previous
              </.link>
              <.link
                :if={@room_list_meta.page < @room_list_meta.page_count}
                patch={~p"/rooms?#{rooms_page_params(@form, @room_list_meta.page + 1)}"}
                class="rounded-md border border-slate-300 bg-white px-3 py-1.5 font-medium text-slate-700 hover:bg-slate-50"
              >
                Next
              </.link>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp rooms_path(nil, nil, nil), do: ~p"/rooms"

  defp rooms_path(q, category_id, type) do
    params =
      %{}
      |> maybe_put("q", q)
      |> maybe_put("category_id", category_id)
      |> maybe_put("type", type)

    if map_size(params) == 0, do: ~p"/rooms", else: ~p"/rooms?#{params}"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_tab_type(nil), do: nil
  defp normalize_tab_type(""), do: nil
  defp normalize_tab_type(type) when type in ["public", "private", "paid", "secret"], do: type
  defp normalize_tab_type(_other), do: nil

  defp current_tab(assigns), do: normalize_tab_type(assigns.form[:type].value)

  defp type_count(counts, nil), do: counts |> Map.values() |> Enum.sum()

  defp type_count(counts, type) when is_binary(type),
    do: Map.get(counts, type, 0)

  defp total_rooms(counts) do
    Enum.sum(Map.values(counts))
  rescue
    _ -> 0
  end

  defp grouped_rooms(rooms) do
    Enum.sort_by(Enum.filter(rooms, &is_nil(&1.parent_id)), & &1.name) ++
      Enum.sort_by(Enum.reject(rooms, &is_nil(&1.parent_id)), & &1.name)
  end

  defp tenant_name(%{name: name}) when is_binary(name), do: name
  defp tenant_name(_), do: "Workspace"

  defp relative_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%d %b %Y %H:%M")
  end

  defp relative_time(_), do: ""

  defp card_tone("paid"), do: "border-amber-200"
  defp card_tone("secret"), do: "border-red-200"
  defp card_tone("private"), do: "border-emerald-200"
  defp card_tone(_), do: "border-slate-200"

  defp row_tone(%{type: type}), do: type

  defp type_label("public"), do: "Open"
  defp type_label("private"), do: "Members-only"
  defp type_label("paid"), do: "Paid advisory"
  defp type_label("secret"), do: "Secret committee"
  defp type_label(other), do: other

  defp type_pill("public"), do: "bg-emerald-50 text-emerald-700 border border-emerald-200"
  defp type_pill("private"), do: "bg-slate-100 text-slate-700 border border-slate-200"
  defp type_pill("paid"), do: "bg-amber-50 text-amber-800 border border-amber-200"
  defp type_pill("secret"), do: "bg-red-50 text-red-700 border border-red-200"
  defp type_pill(_), do: "bg-slate-100 text-slate-700 border border-slate-200"

  defp money(%Decimal{} = d), do: Decimal.round(d, 2) |> Decimal.to_string(:normal)
  defp money(_), do: "0.00"

  defp form_value(form, key), do: (form[key] && form[key].value) || ""

  defp rooms_page_params(form, page) do
    params =
      %{}
      |> maybe_put("q", form_value(form, :q))
      |> maybe_put("category_id", form_value(form, :category_id))
      |> maybe_put("type", form_value(form, :type))

    if page > 1, do: Map.put(params, "page", Integer.to_string(page)), else: params
  end
end
