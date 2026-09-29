defmodule BeamChatWeb.RoomLive.Index do
  @moduledoc """
  The room directory (PRD §2.3): the admin-managed category tree on the
  left (hidden categories visible only to staff), room-type tabs with live
  counts, search, and paginated room cards honoring room-type visibility.
  """

  use BeamChatWeb, :live_view

  alias BeamChat.Categories
  alias BeamChat.Rooms
  alias BeamChat.Settings

  @per_page 12
  @types ~w(all public private paid secret)

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Rooms")
     |> assign(:active_nav, :rooms)
     |> assign(:category_tree, Categories.visible_tree(user))
     |> assign(:type_counts, Rooms.count_rooms_by_type(user))
     |> assign(:can_create_room, Rooms.can_create_room?(user))
     |> assign(:show_create, false)
     |> assign(
       :create_form,
       to_form(
         %{
           "name" => "",
           "description" => "",
           "type" => "public",
           "category_id" => "",
           "price" => "",
           "is_listed" => "true"
         },
         as: :room
       )
     )
     |> assign(:create_type, "public")
     |> assign(:types, @types)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    user = socket.assigns.current_user

    filters = %{
      type: type_from_params(params["type"]),
      category_id: category_from_params(params["category_id"], user),
      q: String.trim(params["q"] || ""),
      page: page_from_params(params["page"])
    }

    rooms =
      Rooms.list_visible_rooms(user,
        type: filters.type,
        category_id: filters.category_id,
        search: filters.q,
        page: filters.page
      )

    has_more? = length(rooms) > @per_page
    page_rooms = rooms |> Enum.take(@per_page)

    counts = Rooms.member_counts(Enum.map(page_rooms, & &1.id))

    cards =
      Enum.map(page_rooms, fn room ->
        %{id: room.id, room: room, member_count: Map.get(counts, room.id, 0)}
      end)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:rooms, page_rooms)
     |> assign(:has_more?, has_more?)
     |> assign(:selected_category, selected_category_from(filters))
     |> stream(:rooms, cards, reset: true, dom_id: &"room-#{&1.id}")}
  end

  defp type_from_params(type) when type in @types, do: type
  defp type_from_params(_), do: "all"

  # A hidden category only resolves for staff (they browse it); for anyone
  # else the filter silently falls back to the unfiltered directory, same
  # as an unknown id.
  defp category_from_params(category_id, user)
       when is_binary(category_id) and category_id != "" do
    category = Categories.get_category(category_id)

    case category do
      nil -> nil
      %{is_hidden: false} -> category_id
      %{is_hidden: true} -> if staff?(user), do: category_id, else: nil
    end
  end

  defp category_from_params(_category_id, _user), do: nil

  defp selected_category_from(filters) do
    case filters.category_id do
      nil -> nil
      "" -> nil
      category_id -> Categories.get_category(category_id)
    end
  end

  defp page_from_params(page) when is_binary(page) do
    case Integer.parse(page) do
      {page, _} when page > 0 -> page
      _ -> 1
    end
  end

  defp page_from_params(_), do: 1

  defp staff?(%{role: role}) when role in ["admin", "moderator"], do: true
  defp staff?(_), do: false

  ## Events

  @impl true
  def handle_event("search", params, socket) do
    %{type: type, category_id: category_id} = socket.assigns.filters
    q = String.trim((params["search"] || %{})["q"] || "")

    {:noreply,
     push_patch(socket,
       to: ~p"/rooms?#{%{"type" => type, "category_id" => category_id, "q" => q}}"
     )}
  end

  def handle_event("toggle-create", _params, socket) do
    {:noreply, assign(socket, :show_create, not socket.assigns.show_create)}
  end

  def handle_event("create-type-changed", %{"room" => %{"type" => type}}, socket)
      when type in ~w(public private secret paid) do
    {:noreply, assign(socket, :create_type, type)}
  end

  def handle_event("create-type-changed", _params, socket), do: {:noreply, socket}

  def handle_event("validate-create", _params, socket) do
    # Server-side validation happens on submit; change events only drive
    # the conditional price field via create_type.
    {:noreply, socket}
  end

  def handle_event("create-room", params, socket) do
    attrs = room_attrs(params["room"] || %{})

    case Rooms.create_room(socket.assigns.current_user, attrs) do
      {:ok, room} ->
        {:noreply,
         socket
         |> put_flash(:info, "Room created — you are its owner.")
         |> push_navigate(to: ~p"/rooms/#{room.slug}")}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> put_flash(:error, "Room creation is restricted on this platform.")
         |> assign(:show_create, false)}

      {:error, :category_not_found} ->
        {:noreply, put_flash(socket, :error, "Pick a category for the room.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not create the room — check the fields.")
         |> assign(:create_form, to_form(changeset, as: :room))}
    end
  end

  defp room_attrs(attrs) do
    %{
      "name" => String.trim(attrs["name"] || ""),
      "description" => String.trim(attrs["description"] || ""),
      "type" => attrs["type"] || "public",
      "category_id" => attrs["category_id"],
      "is_listed" => attrs["is_listed"] in ["true", true, "on"]
    }
    |> Map.merge(price_attrs(attrs))
  end

  defp price_attrs(%{"type" => "paid"} = attrs) do
    case Decimal.parse(String.trim(attrs["price"] || "")) do
      {%Decimal{} = price, _rest} -> %{"price" => price}
      :error -> %{}
    end
  end

  defp price_attrs(_attrs), do: %{}

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-6 section-spacious bg-grid-subtle min-h-dvh">
      <header class="animate-fade-up">
        <div class="flex flex-wrap items-end justify-between gap-4">
          <div>
            <div class="flex items-center gap-3 mb-2">
              <span class="premium-chip">
                <span class="size-1.5 rounded-full bg-primary pulse-dot"></span> Directory
              </span>
            </div>
            <h1 class="text-headline-lg font-extrabold text-ink tracking-tight">
              Rooms
            </h1>
            <p class="text-body-lg text-base-content/50 mt-1">
              Browse the tree, pick a category, or search across the platform.
            </p>
          </div>

          <%= if @can_create_room do %>
            <button
              type="button"
              class="btn btn-primary btn-premium"
              phx-click="toggle-create"
              id="toggle-create-room"
            >
              <span class="btn-icon"><.icon name="hero-plus" class="size-4" /></span> New room
            </button>
          <% else %>
            <span class="beam-chip">Room creation is restricted</span>
          <% end %>
        </div>
      </header>

      <%= if @show_create do %>
        <div class="animate-slide-up premium-card double-bezel">
          <div class="double-bezel-inner p-6">
            <h2 class="text-headline-md mb-4">Create a room</h2>
            <.form
              for={@create_form}
              id="create-room-form"
              phx-submit="create-room"
              phx-change="create-type-changed"
              class="grid gap-4 sm:grid-cols-2"
            >
              <.input
                field={@create_form[:name]}
                type="text"
                label="Name"
                placeholder="Valorant talk"
              />
              <.input
                field={@create_form[:category_id]}
                type="select"
                label="Category"
                options={category_options(@category_tree)}
              />
              <.input field={@create_form[:description]} type="text" label="Description (optional)" />
              <div>
                <.input
                  field={@create_form[:type]}
                  type="select"
                  label="Type"
                  options={[
                    {"Public — anyone joins", "public"},
                    {"Private — grant to join", "private"},
                    {"Secret — unlisted", "secret"},
                    {"Paid — wallet subscription", "paid"}
                  ]}
                />
              </div>
              <%= if @create_type == "paid" do %>
                <.input
                  field={@create_form[:price]}
                  type="number"
                  label={"Price per 30 days (#{Settings.base_currency()})"}
                  step="0.01"
                  placeholder="150"
                />
                <label class="label cursor-pointer justify-start gap-3">
                  <input type="hidden" name="room[is_listed]" value="false" />
                  <input
                    type="checkbox"
                    name="room[is_listed]"
                    value="true"
                    checked
                    class="checkbox checkbox-sm"
                  />
                  <span class="label-text">List in the directory</span>
                </label>
              <% end %>
              <div class="flex items-end gap-2 sm:col-span-2">
                <button type="submit" class="btn btn-primary btn-premium">Create room</button>
                <button type="button" class="btn btn-ghost btn-premium" phx-click="toggle-create">
                  Cancel
                </button>
              </div>
            </.form>
          </div>
        </div>
      <% end %>

      <div class="grid items-start gap-6 lg:grid-cols-[18rem_minmax(0,1fr)]">
        <aside class="animate-fade-up stagger-1">
          <div class="sidebar-section p-4">
            <h2 class="px-2 pt-1 pb-3 text-label-md uppercase tracking-wider text-base-content/40">
              Categories
            </h2>
            <.link
              navigate={~p"/rooms"}
              class={[
                "sidebar-link flex items-center gap-2 rounded-md px-3 py-2 text-sm font-medium",
                is_nil(@filters.category_id) && "active",
                not is_nil(@filters.category_id) && "text-base-content/60 hover:bg-base-100"
              ]}
            >
              <.icon name="hero-squares-2x2" class="size-4" /> All rooms
            </.link>
            <.tree_node
              :for={node <- @category_tree}
              node={node}
              selected_id={@filters.category_id}
              depth={0}
            />
          </div>
        </aside>

        <section class="flex flex-col gap-5">
          <div class="flex flex-wrap items-center gap-3 animate-fade-up stagger-2" id="room-type-tabs">
            <%= for type <- @types do %>
              <.link
                :for={type <- @types}
                patch={~p"/rooms?#{%{type: type, category_id: @filters.category_id, q: @filters.q}}"}
                class={[
                  "rounded-full border px-4 py-2 text-sm font-medium transition-all duration-300",
                  @filters.type == type && "border-primary bg-primary text-primary-content shadow-sm",
                  @filters.type != type &&
                    "border-base-300 bg-white/60 text-base-content/60 hover:border-primary/40 hover:bg-white"
                ]}
              >
                {type_label(type)}
                <span class={[
                  "ml-2 text-xs tnum",
                  @filters.type == type && "text-primary-content/70",
                  @filters.type != type && "text-base-content/30"
                ]}>
                  {count_for(@type_counts, type)}
                </span>
              </.link>
            <% end %>

            <.form
              for={to_form(%{"q" => @filters.q}, as: :search)}
              id="room-search-form"
              phx-submit="search"
              class="ml-auto flex items-center gap-2"
            >
              <input
                type="search"
                name="search[q]"
                value={@filters.q}
                placeholder="Search rooms…"
                class="search-input w-52 px-4 py-2 text-sm"
                aria-label="Search rooms"
              />
              <button type="submit" class="btn btn-outline btn-sm btn-premium">
                <.icon name="hero-magnifying-glass" class="size-4" />
              </button>
            </.form>
          </div>

          <%= if @selected_category do %>
            <div class="premium-chip animate-fade-up stagger-3" id="selected-category-chip">
              <.icon name="hero-folder" class="size-3.5 text-primary" />
              {category_path_label(@selected_category)}
              <.link
                patch={~p"/rooms?#{%{type: @filters.type, q: @filters.q}}"}
                class="ml-1 hover:text-error transition-colors"
                aria-label="Clear category"
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </.link>
            </div>
          <% end %>

          <div id="rooms" phx-update="stream" class="grid gap-5 sm:grid-cols-2 xl:grid-cols-3">
            <.room_card
              :for={{dom_id, card} <- @streams.rooms}
              dom_id={dom_id}
              room={card.room}
              member_count={card.member_count}
            />
          </div>

          <div
            class="hidden only:block premium-card p-10 text-center text-base-content/40"
            id="rooms-empty"
          >
            <div class="text-4xl mb-3 opacity-30">
              <.icon name="hero-squares-2x2" class="size-12" />
            </div>
            No rooms match — try another category or search.
          </div>

          <div
            class="flex items-center justify-between animate-fade-up stagger-4"
            id="rooms-pagination"
          >
            <span class="text-label-sm text-base-content/40">Page {@filters.page}</span>
            <div class="flex gap-2">
              <.link
                :if={@filters.page > 1}
                patch={~p"/rooms?#{next_filters(@filters, @filters.page - 1)}"}
                class="btn btn-outline btn-sm btn-premium"
              >
                <.icon name="hero-chevron-left" class="size-4" /> Prev
              </.link>
              <.link
                :if={@has_more?}
                patch={~p"/rooms?#{next_filters(@filters, @filters.page + 1)}"}
                class="btn btn-outline btn-sm btn-premium"
              >
                Next <.icon name="hero-chevron-right" class="size-4" />
              </.link>
            </div>
          </div>
        </section>
      </div>
    </div>
    """
  end

  attr :node, :map, required: true
  attr :selected_id, :string, default: nil
  attr :depth, :integer, default: 0

  defp tree_node(assigns) do
    ~H"""
    <div id={"cat-#{@node.category.id}"} style={"margin-left: #{@depth * 0.5}rem"}>
      <.link
        patch={~p"/rooms?#{%{category_id: @node.category.id}}"}
        class={[
          "sidebar-link flex items-center gap-2 rounded-md px-3 py-2 text-sm",
          @selected_id == @node.category.id && "active",
          @selected_id != @node.category.id && "text-base-content/50 hover:bg-base-100"
        ]}
      >
        <.icon :if={@node.category.is_hidden} name="hero-eye-slash" class="size-3.5 text-warning" />
        <.icon :if={not @node.category.is_hidden} name="hero-folder" class="size-3.5 text-primary/50" />
        <span class="truncate">{@node.category.name}</span>
      </.link>
      <.tree_node
        :for={child <- @node.children}
        node={child}
        selected_id={@selected_id}
        depth={@depth + 1}
      />
    </div>
    """
  end

  attr :dom_id, :string, required: true
  attr :room, :map, required: true
  attr :member_count, :integer, required: true

  defp room_card(assigns) do
    ~H"""
    <.link
      id={@dom_id}
      navigate={~p"/rooms/#{@room.slug}"}
      class="room-card block group relative"
    >
      <div class="room-card-inner p-5 flex flex-col gap-3">
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <h3 class="truncate font-bold text-base-content text-[1.0625rem]">
              <span class="text-base-content/25">#</span>{@room.name}
            </h3>
            <p class="text-label-sm text-base-content/40 truncate mt-0.5">
              {(@room.category && @room.category.name) || "uncategorized"} · @{@room.owner.username}
            </p>
          </div>
          <span class={[
            "shrink-0 rounded-full px-2.5 py-0.5 text-[0.6875rem] font-semibold",
            @room.type == "paid" && "bg-primary/10 text-primary",
            @room.type != "paid" && "bg-base-100 text-base-content/50"
          ]}>
            {type_label(@room.type)}
          </span>
        </div>

        <p class="line-clamp-2 text-[0.875rem] text-base-content/50 leading-relaxed">
          {@room.description || "No description yet."}
        </p>

        <div class="mt-auto flex items-center gap-2 pt-2">
          <span class="premium-chip">
            <.icon name="hero-user-group" class="size-3" /> {@member_count}
          </span>
          <%= if @room.type == "paid" do %>
            <span class="premium-chip tnum">
              {format_money(@room.price)} {Settings.base_currency()}
            </span>
          <% end %>
        </div>
      </div>
    </.link>
    """
  end

  defp category_options(tree) do
    flatten_tree(tree) |> Enum.map(fn category -> {option_label(category, tree), category.id} end)
  end

  defp flatten_tree(tree, acc \\ []) do
    Enum.reduce(tree, acc, fn %{category: category, children: children}, acc ->
      flatten_tree(children, [category | acc])
    end)
    |> Enum.reverse()
  end

  defp option_label(category, tree) do
    depth = category_depth(tree, category, 0)
    prefix = if depth > 0, do: String.duplicate("· ", depth), else: ""
    prefix <> category.name
  end

  defp category_depth(tree, %{id: id}, depth) do
    Enum.find_value(tree, fn %{category: category, children: children} ->
      cond do
        category.id == id -> depth
        children != [] -> category_depth(children, id, depth + 1)
        true -> nil
      end
    end) || depth
  end

  defp category_path_label(category) do
    category
    |> BeamChat.Categories.path()
    |> Enum.map_join(" › ", & &1.name)
  end

  defp type_label("all"), do: "All"
  defp type_label(type) when is_binary(type), do: type

  defp count_for(_counts, "all") do
    # "All" count is not in the per-type map; tabs show the individual
    # types' counts and the All tab gets the sum lazily — omitted here to
    # keep the tab light.
    ""
  end

  defp count_for(counts, type) do
    counts |> Map.get(type, 0) |> to_string()
  end

  defp next_filters(filters, page) do
    %{
      "type" => filters.type,
      "category_id" => filters.category_id,
      "q" => filters.q,
      "page" => page
    }
  end

  defp format_money(%Decimal{} = d), do: Decimal.round(d, 2) |> Decimal.to_string(:normal)
  defp format_money(nil), do: "0.00"
end
