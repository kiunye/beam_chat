defmodule BeamChatWeb.Plugs.Authorize do
  @moduledoc """
  Gates a controller pipeline on a permission.

      pipeline :admin do
        plug BeamChatWeb.Plugs.Authorize, :user_ban
      end

  The permission is checked against `conn.assigns.current_scope`, built
  by `BeamChatWeb.Plug.TenantContext` (which itself requires
  `BeamChatWeb.Plugs.FetchCurrentUser` to have run first), so order in
  the pipeline matters: authenticate, then tenant context, then this
  plug.

  Unauthenticated users are redirected to the login page with a flash;
  authenticated users without the permission are redirected home with a
  generic "no access" message. Both paths halt.
  """

  @behaviour Plug

  use Phoenix.VerifiedRoutes,
    endpoint: BeamChatWeb.Endpoint,
    router: BeamChatWeb.Router,
    statics: BeamChatWeb.static_paths()

  import Phoenix.Controller
  import Plug.Conn

  alias BeamChat.Authorization

  @impl true
  def init(permission) when is_atom(permission), do: permission

  @impl true
  def call(conn, permission) do
    case conn.assigns[:current_scope] do
      %{user: nil} = _scope ->
        conn
        |> put_flash(:error, "You must log in to access this page.")
        |> redirect(to: ~p"/auth/login")
        |> halt()

      scope ->
        if Authorization.can?(scope, permission) do
          conn
        else
          conn
          |> put_flash(:error, "You do not have access.")
          |> redirect(to: "/")
          |> halt()
        end
    end
  end
end
