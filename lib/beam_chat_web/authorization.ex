defmodule BeamChatWeb.Authorization do
  @moduledoc """
  LiveView `on_mount` hooks for permission gating.

  Gate a LiveView (or a whole `live_session`) on a permission instead of
  a role name:

      live_session :staff,
        on_mount: [
          {BeamChatWeb.UserAuthLive, :require_authenticated},
          {BeamChatWeb.TenantContext, :default},
          {BeamChatWeb.Authorization, {:require_permission, :room_create}}
        ] do
        live "/admin/rooms", RoomTreeLive, :index
      end

  The permission is checked against the `:current_scope` assign, which
  `BeamChatWeb.TenantContext` builds from the authenticated user and
  the active tenant — so this hook must be listed *after* both
  `BeamChatWeb.UserAuthLive` and `BeamChatWeb.TenantContext`.

  Unauthorized users are halted with a flash and redirected; there is no
  permission-hinting in the UI beyond the generic message.
  """

  use Phoenix.VerifiedRoutes,
    endpoint: BeamChatWeb.Endpoint,
    router: BeamChatWeb.Router,
    statics: BeamChatWeb.static_paths()

  import Phoenix.LiveView

  alias BeamChat.Authorization

  def on_mount({:require_permission, permission}, _params, _session, socket)
      when is_atom(permission) do
    if Authorization.can?(socket.assigns[:current_scope], permission) do
      {:cont, socket}
    else
      {:halt, halt_no_access(socket)}
    end
  end

  defp halt_no_access(socket) do
    socket
    |> put_flash(:error, "You do not have access.")
    |> redirect(to: ~p"/")
  end
end
