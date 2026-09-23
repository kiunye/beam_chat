defmodule BeamChatWeb.RoomTreeLive do
  @moduledoc """
  Hierarchical, multi-tenant room browser and admin creation UI.

  Renders a recursive tree of rooms for the active tenant. Tenant admins see the
  full tree and may create sub-rooms; non-admins see only the rooms they are
  explicitly granted via `BeamChat.Rooms.AccessPolicy` (CATEGORY_REDESIGN.md §4.6 / D5).

  Authorization is enforced server-side in the event handlers via
  `BeamChat.Authorization.can?/2` (`:room_create`) — the hidden create form is
  a UI nicety, never the gate.

  `current_user` is provided by the `:require_authenticated` `on_mount` hook on
  the `:authenticated` live session (see `router.ex`). The active tenant is
  resolved from the LiveView session key `:active_tenant_id`, defaulting to the
  user's first tenant.
  """

  use BeamChatWeb, :live_view

  require Logger

  alias BeamChat.Accounts.User
  alias BeamChat.Audit
  alias BeamChat.Authorization
  alias BeamChat.Authorization.Scope
  alias BeamChat.Repo
  alias BeamChat.Rooms
  alias BeamChat.Rooms.AccessPolicy
  alias BeamChat.Rooms.Room
  alias BeamChat.Tenants

  # ---------------------------------------------------------------------------
  # Mount / assign setup
  # ---------------------------------------------------------------------------

  @impl true
  def mount(params, session, socket) do
    user = socket.assigns.current_user
    tenants = Tenants.list_tenants_for_user(user)
    active_id = params["tenant"] || session["active_tenant_id"]
    tenant = Enum.find(tenants, &(&1.id == active_id)) || List.first(tenants)

    socket =
      socket
      |> assign(:page_title, "Room Tree")
      |> assign(:tenants, tenants)
      |> assign(:tenant, tenant)
      |> assign(:is_admin, can_create_rooms?(tenant, user))
      |> assign(:tenant_form, to_form(%{"tenant_id" => tenant && tenant.id}, as: :switcher))
      |> assign(:draft, new_draft())
      |> assign(:show_create, false)
      |> assign(:form, draft_to_form(new_draft()))

    {:ok, assign(socket, :tree, load_tree(socket))}
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
            # The mount-time GUC context resolved by BeamChatWeb.TenantContext
            # matched the ?tenant= param at mount, but a tenant switch arrives
            # here via push_patch without re-running the on_mount hooks — re-sync
            # the process context so legacy `Repo.scoped/1` calls (e.g. inside
            # `Rooms.create_room/1`) see the tenant this view is now rendering.
            Repo.set_tenant_context(tenant.id, socket.assigns.current_user.id)

            socket
            |> assign(:tenant, tenant)
            |> assign(:is_admin, can_create_rooms?(tenant, socket.assigns.current_user))
            |> assign(:tenant_form, to_form(%{"tenant_id" => tenant.id}, as: :switcher))
            |> assign(:tree, load_tree(socket))
          else
            socket
          end
      end

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Event handlers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("tenant-selected", %{"switcher" => %{"tenant_id" => tenant_id}}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/rooms?tenant=#{tenant_id}")}
  end

  @impl true
  def handle_event("toggle-create", _params, socket) do
    {:noreply, assign(socket, :show_create, not socket.assigns.show_create)}
  end

  @impl true
  def handle_event("start-create", %{"parent_id" => parent_id}, socket) do
    if can_create_rooms?(socket) do
      draft = Map.put(socket.assigns.draft, "parent_id", parent_id)
      {:noreply, assign(socket, draft: draft, form: draft_to_form(draft), show_create: true)}
    else
      {:noreply, deny_room_create(socket)}
    end
  end

  @impl true
  def handle_event("validate", %{"room" => params}, socket) do
    draft = merge_draft(socket.assigns.draft, params)
    {:noreply, assign(socket, draft: draft, form: draft_to_form(draft))}
  end

  @impl true
  def handle_event("save", %{"room" => params}, socket) do
    if can_create_rooms?(socket) do
      create_room(socket, params)
    else
      {:noreply, deny_room_create(socket)}
    end
  end

  defp create_room(socket, params) do
    user = socket.assigns.current_user
    tenant = socket.assigns.tenant
    draft = merge_draft(socket.assigns.draft, params)
    parent_id = blank_to_nil(draft["parent_id"])

    attrs = %{
      "name" => draft["name"],
      "slug" => draft["slug"],
      "description" => draft["description"],
      "type" => draft["type"],
      "parent_id" => parent_id,
      "tenant_id" => tenant.id,
      "owner_id" => user.id
    }

    result =
      Repo.with_tenant(tenant.id, user.id, fn ->
        with {:ok, room} <- Rooms.create_room(attrs),
             {:ok, _audit} <- Audit.log(user, "room.created", room, %{tenant_id: tenant.id}) do
          {:ok, room}
        end
      end)

    case result do
      {:ok, _room} ->
        socket =
          socket
          |> put_flash(:info, "Room \"#{attrs["name"]}\" created.")
          |> assign(:draft, new_draft())
          |> assign(:show_create, false)
          |> assign(:form, draft_to_form(new_draft()))
          |> assign(:tree, load_tree(socket))

        {:noreply, socket}

      {:error, :missing_tenant} ->
        {:noreply, put_flash(socket, :error, "No active tenant — cannot create room.")}

      {:error, changeset} ->
        {:noreply, assign(socket, draft: draft, form: to_form(changeset, as: :room))}
    end
  end

  # Server-side authorization for room creation. The create form is only
  # rendered for privileged users, but events can be forged from any client —
  # the permission check here is the actual gate, not the hidden UI.
  defp can_create_rooms?(%{assigns: %{tenant: tenant, current_user: user}}),
    do: can_create_rooms?(tenant, user)

  defp can_create_rooms?(tenant, %User{} = user),
    do: Authorization.can?(Scope.for_user(user, tenant), :room_create)

  defp can_create_rooms?(_tenant, _user), do: false

  defp deny_room_create(socket) do
    user = socket.assigns.current_user
    tenant = socket.assigns.tenant

    Logger.warning(
      "room create denied: user #{user && user.id} lacks :room_create in tenant #{tenant && tenant.id}"
    )

    socket
    |> put_flash(:error, "You do not have access.")
    |> assign(:draft, new_draft())
    |> assign(:form, draft_to_form(new_draft()))
    |> assign(:show_create, false)
  end

  # ---------------------------------------------------------------------------
  # Recursive tree rendering (co-located function component)
  # ---------------------------------------------------------------------------

  attr :node, :map, required: true
  attr :is_admin, :boolean, default: false

  def room_node(assigns) do
    ~H"""
    <div id={"room-node-#{@node.room.id}"} class="motion-safe:transition-all motion-safe:duration-200">
      <div class={[
        "flex items-start justify-between gap-3 rounded-lg border bg-base-100 p-3 shadow-sm",
        "hover:border-primary/40 hover:shadow-md",
        @node.room.parent_id == nil && "border-base-300/80"
      ]}>
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <p class="font-display font-semibold text-base-content truncate text-sm">
              {@node.room.name}
            </p>

            <span :if={@node.room.type != "public"} class="badge badge-sm badge-ghost">
              {@node.room.type}
            </span>
          </div>

          <p :if={@node.room.slug} class="text-xs text-base-content/60 truncate">
            @{@node.room.slug}
          </p>

          <p
            :if={@node.room.description && @node.room.description != ""}
            class="mt-1 text-xs text-base-content/70"
          >
            {@node.room.description}
          </p>
        </div>

        <.button
          :if={@is_admin}
          phx-click="start-create"
          phx-value-parent_id={@node.room.id}
          class="btn btn-xs btn-ghost shrink-0"
        >
          Add sub-room
        </.button>
      </div>

      <div
        :if={@node.children != []}
        class="ml-3 mt-2 space-y-2 border-l border-base-300/70 pl-3"
      >
        <.room_node :for={child <- @node.children} node={child} is_admin={@is_admin} />
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Header -->
      <div class="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h1 class="font-display text-2xl font-semibold tracking-tight text-base-content">
            Admin Console
          </h1>

          <p class="text-sm text-base-content/70 mt-1">
            Manage your tenants, rooms, and workspace settings.
          </p>
        </div>
      </div>
      
    <!-- Tenant Switcher -->
      <div class="rounded-box border border-base-300 bg-base-100 p-4">
        <h2 class="text-sm font-semibold text-base-content mb-2">Current Tenant</h2>

        <.form
          for={@tenant_form}
          id="tenant-switcher-form"
          phx-submit="tenant-selected"
          class="flex items-center gap-2"
        >
          <.input
            field={@tenant_form[:tenant_id]}
            type="select"
            class="w-48"
            options={Enum.map(@tenants, fn t -> {t.name || t.id, t.id} end)}
          />
        </.form>
      </div>

      <%= if @tree != [] do %>
        <!-- Room Tree -->
        <div class="rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="font-display font-semibold text-lg mb-3">Property Tree</h2>

          <ul id="room-tree" class="space-y-2">
            <%= for node <- @tree do %>
              <.room_node node={node} is_admin={@is_admin} />
            <% end %>
          </ul>
        </div>
      <% else %>
        <!-- Empty State -->
        <div class="rounded-box border border-base-300 bg-base-200/40 p-8 text-center">
          <p class="text-base-content/70 mb-2">No rooms in this tenant.</p>
          <.link navigate={~p"/rooms"} class="link link-primary">Browse all rooms</.link>
        </div>
      <% end %>
      
    <!-- Create Room Panel -->
      <%= if @show_create do %>
        <div class="rounded-box border border-primary bg-primary/5 p-4">
          <h3 class="font-display font-semibold text-base-content mb-3">Create New Room</h3>

          <.form
            for={@form}
            id="create-room-form"
            phx-submit="save"
            phx-change="validate"
            class="space-y-4"
          >
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <.input
                field={@form[:name]}
                type="text"
                label="Room Name"
                placeholder="Enter room name"
                required
              />

              <.input
                field={@form[:slug]}
                type="text"
                label="Slug"
                placeholder="room-slug"
                required
              />
            </div>

            <.input
              field={@form[:description]}
              type="text"
              label="Description"
              placeholder="Room description"
              class="w-full"
            />

            <.input
              field={@form[:type]}
              type="select"
              label="Room Type"
              options={[
                {"Public", "public"},
                {"Private", "private"},
                {"Secret", "secret"}
              ]}
            />

            <div class="flex justify-end gap-2">
              <.button type="submit" class="btn btn-primary btn-sm">
                Create Room
              </.button>
            </div>
          </.form>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp new_draft do
    %{"name" => "", "slug" => "", "description" => "", "type" => "public", "parent_id" => ""}
  end

  defp merge_draft(draft, params) when is_map(params) do
    Map.merge(draft, Map.new(params))
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp draft_to_form(draft) do
    parent_id = blank_to_nil(draft["parent_id"])
    changeset = %Room{} |> Room.changeset(Map.put(draft, "parent_id", parent_id))
    to_form(changeset, as: :room)
  end

  # Loads the tree for the active tenant. Admin reads run inside
  # `Repo.with_tenant/3` so PostgreSQL Row Level Security applies the correct
  # `app.current_tenant_id` GUC; non-admins use the visibility-scoped policy.
  # Full-tree visibility is a tenant-admin power (it mirrors the RLS select
  # policy); the create controls additionally open for global admins via the
  # `:room_create` permission.
  defp load_tree(socket) do
    case socket.assigns.tenant do
      nil -> []
      tenant -> load_tenant_tree(socket, tenant)
    end
  end

  defp load_tenant_tree(socket, tenant) do
    if Tenants.admin?(tenant, socket.assigns.current_user) do
      Repo.with_tenant(tenant.id, socket.assigns.current_user.id, fn ->
        roots = Rooms.list_child_rooms(nil)
        Enum.map(roots, &build_node/1)
      end)
    else
      visible = AccessPolicy.list_visible_rooms(socket.assigns.current_user, tenant)
      organize_flat(visible)
    end
  end

  defp build_node(room) do
    children = Rooms.list_child_rooms(room.id) |> Enum.map(&build_node/1)
    %{room: room, children: children}
  end

  defp organize_flat(rooms) do
    by_parent = Enum.group_by(rooms, fn r -> r.parent_id end)
    build_from(by_parent, nil)
  end

  defp build_from(by_parent, parent_id) do
    Map.get(by_parent, parent_id, [])
    |> Enum.sort_by(& &1.name)
    |> Enum.map(fn room -> %{room: room, children: build_from(by_parent, room.id)} end)
  end
end
