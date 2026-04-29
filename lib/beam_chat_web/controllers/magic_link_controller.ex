defmodule BeamChatWeb.MagicLinkController do
  use BeamChatWeb, :controller

  alias BeamChat.Accounts
  alias BeamChatWeb.UserAuth

  def new(conn, _params) do
    render(conn, :new, error_message: nil)
  end

  def create(conn, %{"user" => %{"email" => email}}) when is_binary(email) do
    :ok = Accounts.deliver_magic_link_instructions(email)

    conn
    |> put_flash(:info, "If that email is registered, you will receive a link shortly.")
    |> redirect(to: ~p"/auth/login")
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> render(:new, error_message: "Enter a valid email address.")
  end

  def verify(conn, %{"token" => token}) when is_binary(token) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, user} ->
        conn
        |> UserAuth.log_in_user(user)
        |> put_flash(:info, "Welcome back!")
        |> redirect(to: ~p"/")

      {:error, _} ->
        conn
        |> put_flash(:error, "Invalid or expired link.")
        |> redirect(to: ~p"/auth/login")
    end
  end

  def verify(conn, _params) do
    conn
    |> put_flash(:error, "Invalid link.")
    |> redirect(to: ~p"/auth/login")
  end
end
