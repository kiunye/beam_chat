defmodule BeamChatWeb.RoomTreeLive do
  @moduledoc """
  Hierarchical, multi-tenant room browser and admin creation UI.

  Renders a recursive tree of rooms for the active tenant. Tenant admins see the
  full tree and may create sub-rooms; non-admins see only the rooms they are
  explicitly granted via `BeamChat.Rooms.AccessPolicy` (CATEGORY_REDESIGN.md §4.6 / D5).

  `current_user` is provided by the `:require_authenticated` `on_mount` hook on
  the `:authenticated` live session (see `router.ex`). The active tenant is
  resolved from the LiveView session key `:active_tenant_id`, defaulting to the
  user's first tenant.
  """

  use BeamChatWeb, :live_view

  alias BeamChat.Accounts.User
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
      |> assign(:is_admin, admin?(tenant, user))
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
            socket
            |> assign(:tenant, tenant)
            |> assign(:is_admin, admin?(tenant, socket.assigns.current_user))
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
    draft = Map.put(socket.assigns.draft, "parent_id", parent_id)
    {:noreply, assign(socket, draft: draft, form: draft_to_form(draft), show_create: true)}
  end

  @impl true
  def handle_event("validate", %{"room" => params}, socket) do
    draft = merge_draft(socket.assigns.draft, params)
    {:noreply, assign(socket, draft: draft, form: draft_to_form(draft))}
  end

  @impl true
  def handle_event("save", %{"room" => params}, socket) do
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

    case Repo.with_tenant(tenant.id, user.id, fn -> Rooms.create_room(attrs) end) do
      {:ok, _room} ->
        socket =
          socket
          |> put_flash(:info, "Room “#{attrs["name"]}” created.")
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

  # ---------------------------------------------------------------------------
  # Recursive tree rendering (co-located function component)
  # ---------------------------------------------------------------------------

  attr :node, :map, required: true
  attr :is_admin, :boolean, default: false

  def room_node(assigns) do
    ~H"""
    <div id={"room-node-#{@node.room.id}"} class="motion-safe:transition-all motion-safe:duration-200">
      <div class={[
        "flex items-start justify-between gap-3 rounded-box border bg-base-100 p-3 shadow-sm",
        "hover:border-primary/40 hover:shadow-md",
        @node.room.parent_id == nil && "border-base-300/80"
      ]}>
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <p class="font-display font-semibold text-base-content truncate">
              {@node.room.name}
            </p>

            <span :if={@node.room.type != "public"} class="badge badge-sm badge-ghost">
              {@node.room.type}
            </span>
          </div>

          <p :if={@node.room.slug} class="text-xs text-base-content/55 truncate">
            @{@node.room.slug}
          </p>

          <p
            :if={@node.room.description && @node.room.description != ""}
            class="mt-1 text-sm text-base-content/70"
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
        class="ml-4 mt-2 space-y-2 border-l border-base-300/70 pl-4 sm:ml-5 sm:pl-5"
      >
        <.room_node :for={child <- @node.children} node={child} is_admin={@is_admin} />
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp admin?(nil, _user), do: false
  defp admin?(tenant, %User{} = user), do: Tenants.admin?(tenant, user)
  defp admin?(_tenant, _user), do: false

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
  defp load_tree(socket) do
    case socket.assigns.tenant do
      nil -> []
      tenant -> load_tenant_tree(socket, tenant)
    end
  end

  defp load_tenant_tree(socket, tenant) do
    if socket.assigns.is_admin do
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

  # Flattens the tree into select options with indentation. Only meaningful for
  # admins (who can create); non-admins never see the form.
  defp parent_options(nodes, depth \\ 0) do
    Enum.flat_map(nodes, fn %{room: room, children: children} ->
      label = String.duplicate("  ", depth) <> room.name
      [{label, room.id} | parent_options(children, depth + 1)]
    end)
  end
end
