defmodule BeamChatWeb.UserAuth do
  @moduledoc "Session fetch, login, logout, and plugs for browser pipelines."

  use Phoenix.VerifiedRoutes,
    endpoint: BeamChatWeb.Endpoint,
    router: BeamChatWeb.Router,
    statics: BeamChatWeb.static_paths()

  import Plug.Conn
  import Phoenix.Controller

  alias BeamChat.Accounts
  alias BeamChat.Accounts.User

  @user_token "user_token"
  @live_socket_id "live_socket_id"

  @doc "Assigns `:current_user` from session token (nil if banned or missing)."
  def fetch_current_user(conn, _opts) do
    token = get_session(conn, @user_token)
    user = Accounts.get_user_by_session_token(token)
    user = if user && user.is_banned, do: nil, else: user
    assign(conn, :current_user, user)
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/auth/login")
      |> halt()
    end
  end

  def require_staff(conn, _opts) do
    user = conn.assigns[:current_user]

    cond do
      user && User.staff?(user) ->
        conn

      user ->
        conn
        |> put_flash(:error, "You do not have access.")
        |> redirect(to: ~p"/")
        |> halt()

      true ->
        require_authenticated_user(conn, [])
    end
  end

  def log_in_user(conn, %User{} = user, _params \\ %{}) do
    token = Accounts.generate_user_session_token(user)

    conn
    |> renew_session()
    |> put_session(@user_token, token)
    |> put_session(@live_socket_id, "users_sessions:#{Base.url_encode64(token, padding: false)}")
    |> fetch_current_user([])
  end

  def log_out_user(conn) do
    token = get_session(conn, @user_token)
    token && Accounts.delete_user_session_token(token)

    conn
    |> renew_session()
    |> fetch_current_user([])
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
