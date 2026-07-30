defmodule BeamChatWeb.RoomLive.Index do
  use BeamChatWeb, :live_view

  alias BeamChat.Rooms

  @impl true
  def mount(_params, _session, socket) do
    categories = Rooms.list_categories()
    form = to_form(%{"q" => "", "category_id" => ""}, as: :filter)

    {:ok,
     socket
     |> assign(:page_title, "Rooms")
     |> assign(:categories, categories)
     |> assign(:form, form)
     |> assign(:rooms, [])
     |> assign(:room_list_meta, %{
       total_count: 0,
       page: 1,
       limit: 50,
       page_count: 1
     })}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    q = params["q"] || ""
    category_id = params["category_id"] || ""

    result =
      Rooms.list_rooms_for_index(socket.assigns.current_user, %{
        search: q,
        category_id: category_id,
        page: params["page"]
      })

    form = to_form(%{"q" => q, "category_id" => category_id}, as: :filter)

    {:noreply,
     socket
     |> assign(:rooms, result.rooms)
     |> assign(:room_list_meta, Map.take(result, [:total_count, :page, :limit, :page_count]))
     |> assign(:form, form)}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    params = %{
      "q" => filter["q"] || "",
      "category_id" => filter["category_id"] || ""
    }

    {:noreply, push_patch(socket, to: ~p"/rooms?#{params}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div class="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h1 class="font-display text-2xl font-semibold tracking-tight text-base-content">Rooms</h1>
          
          <p class="text-sm text-base-content/70 mt-1">
            Browse public and member-visible spaces. Secret rooms only appear when you belong.
          </p>
        </div>
        
        <.link
          navigate={~p"/messages"}
          class="btn btn-outline btn-sm shrink-0"
          id="nav-direct-messages"
        >
          Direct messages
        </.link>
      </div>
      
      <.form
        for={@form}
        id="room-filter-form"
        phx-change="filter"
        class="flex flex-col gap-3 sm:flex-row sm:flex-wrap sm:items-end"
      >
        <div class="flex-1 min-w-[12rem]">
          <.input
            field={@form[:q]}
            type="text"
            label="Search"
            placeholder="Name or slug"
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
      
      <div
        :if={@rooms == []}
        class="rounded-box border border-base-300 bg-base-200/40 p-8 text-center"
      >
        <p class="text-base-content/80 font-medium">No rooms match your filters</p>
        
        <p class="text-sm text-base-content/60 mt-2">Try clearing search or pick another category.</p>
      </div>
      
      <ul :if={@rooms != []} class="grid gap-3 sm:grid-cols-2" id="room-list">
        <li :for={room <- @rooms} id={"room-#{room.id}"}>
          <.link
            navigate={~p"/rooms/#{room.slug}"}
            class={[
              "block rounded-box border border-base-300 bg-base-100 p-4 shadow-sm",
              "hover:border-primary/40 hover:shadow-md motion-safe:transition-all motion-safe:duration-200"
            ]}
          >
            <div class="flex items-start justify-between gap-2">
              <div class="min-w-0">
                <p class="font-display font-semibold text-base-content truncate">{room.name}</p>
                
                <p class="text-xs text-base-content/55 truncate">@{room.slug}</p>
              </div>
              
              <span :if={room.type != "public"} class="badge badge-sm badge-ghost shrink-0">
                {room.type}
              </span>
            </div>
            
            <p :if={room.category} class="text-xs text-base-content/60 mt-2">{room.category.name}</p>
          </.link>
        </li>
      </ul>
      
      <div
        :if={@room_list_meta.total_count > @room_list_meta.limit}
        class="flex flex-wrap items-center justify-center gap-3 pt-4 text-sm text-base-content/70"
      >
        <span>
          Page {@room_list_meta.page} of {@room_list_meta.page_count}
          <span class="text-base-content/50">({@room_list_meta.total_count} rooms)</span>
        </span>
        <div class="flex gap-2">
          <.link
            :if={@room_list_meta.page > 1}
            patch={~p"/rooms?#{rooms_page_params(@form, @room_list_meta.page - 1)}"}
            class="btn btn-sm btn-ghost"
          >
            Previous
          </.link>
          <.link
            :if={@room_list_meta.page < @room_list_meta.page_count}
            patch={~p"/rooms?#{rooms_page_params(@form, @room_list_meta.page + 1)}"}
            class="btn btn-sm btn-ghost"
          >
            Next
          </.link>
        </div>
      </div>
    </div>
    """
  end

  defp rooms_page_params(form, page) do
    q = (form[:q] && form[:q].value) || ""
    category_id = (form[:category_id] && form[:category_id].value) || ""

    params =
      %{}
      |> maybe_put_rooms_param("q", q, &(String.trim(&1) != ""))
      |> maybe_put_rooms_param("category_id", category_id, &(String.trim(&1) != ""))

    if page > 1 do
      Map.put(params, "page", Integer.to_string(page))
    else
      params
    end
  end

  defp maybe_put_rooms_param(map, key, value, pred) do
    if pred.(value), do: Map.put(map, key, value), else: map
  end
end
