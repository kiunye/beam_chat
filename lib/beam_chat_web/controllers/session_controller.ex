defmodule BeamChatWeb.SessionController do
  use BeamChatWeb, :controller

  alias BeamChat.Accounts
  alias BeamChatWeb.UserAuth

  def new(conn, _params) do
    render(conn, :new, error_message: nil)
  end

  def create(conn, %{"user" => %{"email" => email, "password" => password}})
      when is_binary(email) and is_binary(password) do
    case Accounts.authenticate_user_by_email_and_password(email, password) do
      {:ok, user} ->
        conn
        |> UserAuth.log_in_user(user)
        |> put_flash(:info, "Welcome back!")
        |> redirect(to: signed_in_path(conn))

      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:new, error_message: "Invalid email or password")
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> render(:new, error_message: "Invalid email or password")
  end

  def delete(conn, _params) do
    conn
    |> UserAuth.log_out_user()
    |> put_flash(:info, "Logged out.")
    |> redirect(to: ~p"/auth/login")
  end

  defp signed_in_path(conn) do
    case get_session(conn, :user_return_to) do
      nil -> ~p"/"
      path -> path
    end
  end
end
