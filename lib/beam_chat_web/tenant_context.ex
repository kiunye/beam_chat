defmodule BeamChatWeb.TenantContext do
  @moduledoc """
  Per-request tenant scoping for multi-tenant Row Level Security.

  This module provides two entry points that both resolve the *active* tenant
  for the authenticated user and stash it on the process via
  `BeamChat.Repo.set_tenant_context/2` so that legacy context functions wrapped
  in `BeamChat.Repo.scoped/1` run under the correct PostgreSQL RLS GUCs:

  - `on_mount/4` — LiveView mount hook (wired into the `:authenticated`
    `live_session` in `router.ex`). The LiveView runs in its own process, so the
    context must be set here rather than in the HTTP plug.
  - `BeamChatWeb.Plug.TenantContext` — a Plug for the `:browser` pipeline so
    controller reads are scoped too.

  The active tenant defaults to the user's first tenant. A session
  `active_tenant_id` (only when the user is actually a member) is preferred if
  present, but defaulting to the first tenant is sufficient for the current UI.

  See CATEGORY_REDESIGN.md §3.6 / §4.3.
  """

  alias BeamChat.Repo
  alias BeamChat.Tenants

  @doc """
  LiveView `on_mount` callback. Matches the signature
  `on_mount(arg, params, session, socket)`.

  If `socket.assigns.current_user` is present, resolves the active tenant and
  stores it on the process so `Repo.scoped/1` can re-apply the RLS GUCs.
  Returns `{:cont, socket}` in all cases (we never halt the mount here).
  """
  def on_mount(_arg, _params, session, socket) do
    socket =
      case socket.assigns[:current_user] do
        nil ->
          socket

        user ->
          tenants = Tenants.list_tenants_for_user(user)

          case tenants do
            [] ->
              socket

            tenants ->
              active =
                Enum.find(tenants, &(&1.id == session_active_tenant_id(session))) ||
                  List.first(tenants)

              Repo.set_tenant_context(active.id, user.id)
              Phoenix.Component.assign(socket, :active_tenant, active)
          end
      end

    {:cont, socket}
  end

  defp session_active_tenant_id(session) when is_map(session) do
    session["active_tenant_id"]
  end

  defp session_active_tenant_id(_), do: nil
end

defmodule BeamChatWeb.Plug.TenantContext do
  @moduledoc """
  Plug that resolves the active tenant for the authenticated user and stores it
  on the process via `BeamChat.Repo.set_tenant_context/2` so controller reads
  wrapped in `BeamChat.Repo.scoped/1` run under the correct RLS GUCs.

  Must run after `BeamChatWeb.Plugs.FetchCurrentUser` so `conn.assigns.current_user`
  is available.
  """
  @behaviour Plug

  alias BeamChat.Repo
  alias BeamChat.Tenants

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      nil ->
        conn

      user ->
        tenants = Tenants.list_tenants_for_user(user)

        case tenants do
          [] ->
            conn

          [active | _] ->
            Repo.set_tenant_context(active.id, user.id)
            conn
        end
    end
  end
end
