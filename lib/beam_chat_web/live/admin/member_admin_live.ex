defmodule BeamChatWeb.MemberAdminLive do
  @moduledoc """
  Tenant member management for users holding the `:tenant_manage`
  permission (tenant admins and global admins).

  The route itself is gated by the `{:require_permission, :tenant_manage}`
  `on_mount` hook in the router's `:tenant_manage` live session, so plain
  members never mount this LiveView. The mutating handlers still call the
  permission-checked context functions (`BeamChat.Tenants.set_member_role/4`,
  `BeamChat.Tenants.remove_member/3`) — the route gate is defence in
  depth, and the context check also covers tenant switches after mount.
  """

  use BeamChatWeb, :live_view

  alias BeamChat.Repo
  alias BeamChat.Tenants

  @impl true
  def mount(params, session, socket) do
    user = socket.assigns.current_user
    tenants = Tenants.list_tenants_for_user(user)
    active_id = params["tenant"] || session["active_tenant_id"]
    tenant = Enum.find(tenants, &(&1.id == active_id)) || List.first(tenants)

    socket =
      socket
      |> assign(:page_title, "Members")
      |> assign(:tenants, tenants)
      |> assign(:tenant, tenant)
      |> assign(:tenant_form, to_form(%{"tenant_id" => tenant && tenant.id}, as: :switcher))

    {:ok, stream_members(socket, tenant)}
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
            |> stream_members(tenant)
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
    {:noreply, push_patch(socket, to: ~p"/admin/members?tenant=#{tenant_id}")}
  end

  def handle_event("set-role", %{"user_id" => user_id, "role" => role}, socket) do
    case Tenants.set_member_role(
           socket.assigns.current_user,
           socket.assigns.tenant,
           user_id,
           role
         ) do
      {:ok, _member} ->
        {:noreply,
         socket
         |> put_flash(:info, "Role updated.")
         |> stream_members(socket.assigns.tenant)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have access.")}

      {:error, :invalid_role} ->
        {:noreply, put_flash(socket, :error, "Invalid role.")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "That user is no longer a member.")
         |> stream_members(socket.assigns.tenant)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update the role.")}
    end
  end

  def handle_event("remove-member", %{"user_id" => user_id}, socket) do
    case Tenants.remove_member(socket.assigns.current_user, socket.assigns.tenant, user_id) do
      {:ok, _member} ->
        {:noreply,
         socket
         |> put_flash(:info, "Member removed.")
         |> stream_members(socket.assigns.tenant)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You do not have access.")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "That user is no longer a member.")
         |> stream_members(socket.assigns.tenant)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not remove the member.")}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Streams are not enumerable, so the empty state is driven by a separate
  # `:member_count` assign (AGENTS.md LiveView streams).
  defp stream_members(socket, nil) do
    socket
    |> assign(:member_count, 0)
    |> stream(:members, [], reset: true)
  end

  defp stream_members(socket, tenant) do
    members = Tenants.list_members(tenant)

    socket
    |> assign(:member_count, length(members))
    |> stream(:members, members, dom_id: &("member-" <> &1.user_id), reset: true)
  end

  defp tenant_options(tenants) do
    Enum.map(tenants, &{&1.name, &1.id})
  end

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto space-y-4">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h1 class="text-xl font-display font-semibold text-base-content">Members</h1>

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
      </div>

      <p :if={!@tenant} class="text-sm text-base-content/60">
        You are not a member of any tenant yet.
      </p>

      <p :if={@tenant && @member_count == 0} class="text-sm text-base-content/60">
        No members in this tenant yet.
      </p>

      <div
        :if={@tenant && @member_count > 0}
        class="rounded-box border border-base-300 bg-base-100 shadow-sm"
      >
        <table class="table">
          <thead>
            <tr class="text-base-content/60">
              <th class="text-xs uppercase tracking-wide font-semibold">User</th>
              <th class="text-xs uppercase tracking-wide font-semibold">Role</th>
              <th class="text-xs uppercase tracking-wide font-semibold text-right">Actions</th>
            </tr>
          </thead>
          <tbody id="member-rows" phx-update="stream">
            <tr :for={{id, member} <- @streams.members} id={id}>
              <td>
                <p class="font-medium text-sm">{member.username}</p>
                <p :if={member.full_name} class="text-xs text-base-content/60">
                  {member.full_name}
                </p>
              </td>
              <td>
                <span class={[
                  "badge badge-sm",
                  member.role == "admin" && "badge-primary",
                  member.role == "member" && "badge-ghost"
                ]}>
                  {member.role}
                </span>
              </td>
              <td>
                <div class="flex items-center justify-end gap-2">
                  <div class="w-40">
                    <.form
                      for={nil}
                      id={"role-form-#{member.user_id}"}
                      phx-change="set-role"
                      class="flex items-center gap-2"
                    >
                      <input type="hidden" name="user_id" value={member.user_id} />
                      <.input
                        name="role"
                        type="select"
                        options={[{"Member", "member"}, {"Admin", "admin"}]}
                        value={member.role}
                      />
                    </.form>
                  </div>

                  <button
                    type="button"
                    phx-click="remove-member"
                    phx-value-user_id={member.user_id}
                    class="btn btn-ghost btn-xs text-error"
                    id={"remove-member-#{member.user_id}"}
                  >
                    Remove
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
