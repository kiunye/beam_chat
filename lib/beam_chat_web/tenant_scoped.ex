defmodule BeamChatWeb.TenantScoped do
  @moduledoc """
  Shared plumbing for tenant-scoped LiveViews.

  Every tenant-aware page resolves its active tenant the same way (a
  `?tenant=` param for the user's own membership wins, then the session
  key, then the first tenant), keeps the process RLS context in sync with
  what it renders, and (on the admin pages) renders the same tenant
  switcher. Before this module existed that ceremony — including the
  GUC-re-sync rationale — was copy-pasted across four LiveViews; now it
  is defined once here.

  Use:

      # mount
      socket =
        socket
        |> assign(:page_title, "Members")
        |> assign_active_tenant(params, session)

      # handle_params (pages with a tenant switcher)
      case find_tenant(socket.assigns.tenants, params["tenant"]) do
        nil -> socket
        tenant -> socket |> activate_tenant(tenant) |> reload_page_data()
      end

      # render
      <.tenant_switcher tenants={@tenants} form={@tenant_form} />

  The `?tenant=` re-sync matters: `BeamChatWeb.TenantContext` runs as an
  `on_mount` hook, so a tenant switch arriving via `push_patch` would
  otherwise leave stale GUCs under legacy `Repo.scoped/1` calls.
  """

  use Phoenix.Component

  import BeamChatWeb.CoreComponents

  alias BeamChat.Repo
  alias BeamChat.Tenants

  @doc """
  Resolve and assign the active tenant for the authenticated user:
  assigns `:tenants`, `:tenant`, and `:tenant_form`, and syncs the
  process RLS context to the resolved tenant.
  """
  def assign_active_tenant(socket, params, session) do
    user = socket.assigns.current_user
    tenants = Tenants.list_tenants_for_user(user)
    active_id = params["tenant"] || session["active_tenant_id"]
    tenant = Enum.find(tenants, &(&1.id == active_id)) || List.first(tenants)

    socket
    |> assign(tenants: tenants, tenant: tenant)
    |> sync_tenant_context(tenant, user)
    |> assign(tenant_form: to_form(%{"tenant_id" => tenant && tenant.id}, as: :switcher))
  end

  @doc """
  Activate a tenant that already belongs to `socket.assigns.tenants`
  (i.e. on a `handle_params` switch): re-assign `:tenant` /
  `:tenant_form` and re-sync the process RLS context.
  """
  def activate_tenant(socket, %Tenants.Tenant{} = tenant) do
    socket
    |> assign(tenant: tenant)
    |> sync_tenant_context(tenant, socket.assigns.current_user)
    |> assign(tenant_form: to_form(%{"tenant_id" => tenant.id}, as: :switcher))
  end

  @doc "Find a tenant among the user's tenants by id; nil when absent or unknown."
  def find_tenant(_tenants, nil), do: nil

  def find_tenant(tenants, tenant_id) when is_binary(tenant_id),
    do: Enum.find(tenants, &(&1.id == tenant_id))

  @doc """
  The tenant switcher select. Owns the form and the `tenant-selected`
  change event; pages push-patch to their own path in the handler.
  """
  attr :tenants, :list, required: true
  attr :form, Phoenix.HTML.Form, required: true, doc: "the `:tenant_form` assign"

  def tenant_switcher(assigns) do
    ~H"""
    <.form
      for={@form}
      id="tenant-switcher"
      phx-change="tenant-selected"
      class="flex items-center gap-2"
    >
      <.input
        field={@form[:tenant_id]}
        type="select"
        options={Enum.map(@tenants, &{&1.name, &1.id})}
        label="Tenant"
      />
    </.form>
    """
  end

  defp sync_tenant_context(socket, nil, _user), do: socket

  defp sync_tenant_context(socket, tenant, user) do
    Repo.set_tenant_context(tenant.id, user.id)
    socket
  end
end
