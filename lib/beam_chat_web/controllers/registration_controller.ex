defmodule BeamChatWeb.RegistrationController do
  use BeamChatWeb, :controller

  alias BeamChat.Accounts
  alias BeamChat.Accounts.User
  alias BeamChatWeb.UserAuth

  def new(conn, _params) do
    changeset = Accounts.change_registration(%User{})
    render(conn, :new, changeset: changeset, error_message: nil)
  end

  def create(conn, %{"user" => user_params}) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        conn
        |> UserAuth.log_in_user(user)
        |> put_flash(:info, "Account created.")
        |> redirect(to: ~p"/")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:new,
          changeset: changeset,
          error_message: "Please fix the errors below."
        )
    end
  end

  def create(conn, _params) do
    changeset = Accounts.change_registration(%User{})

    conn
    |> put_status(:unprocessable_entity)
    |> render(:new, changeset: changeset, error_message: "Invalid submission.")
  end
end
