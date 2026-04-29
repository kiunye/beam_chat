defmodule BeamChatWeb.UserAuthLive do
  @moduledoc "LiveView `on_mount` hooks for session-backed auth."

  use Phoenix.VerifiedRoutes,
    endpoint: BeamChatWeb.Endpoint,
    router: BeamChatWeb.Router,
    statics: BeamChatWeb.static_paths()

  import Phoenix.Component
  import Phoenix.LiveView

  alias BeamChat.Accounts
  alias BeamChat.Accounts.User

  def on_mount(:mount_current_user, _params, session, socket) do
    socket = mount_current_user(socket, session)
    {:cont, socket}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      socket =
        socket
        |> put_flash(:error, "You must log in to access this page.")
        |> redirect(to: ~p"/auth/login")

      {:halt, socket}
    end
  end

  def on_mount(:require_staff, _params, session, socket) do
    socket = mount_current_user(socket, session)

    user = socket.assigns.current_user

    cond do
      user && User.staff?(user) ->
        {:cont, socket}

      user ->
        {:halt,
         socket
         |> put_flash(:error, "You do not have access.")
         |> redirect(to: ~p"/")}

      true ->
        {:halt,
         socket
         |> put_flash(:error, "You must log in to access this page.")
         |> redirect(to: ~p"/auth/login")}
    end
  end

  defp mount_current_user(socket, session) do
    token = session["user_token"]
    user = Accounts.get_user_by_session_token(token)
    user = if user && user.is_banned, do: nil, else: user
    assign(socket, :current_user, user)
  end
end
