defmodule BeamChatWeb.Api.SsoController do
  use BeamChatWeb, :controller

  alias BeamChat.Accounts
  alias BeamChat.SSO
  alias BeamChatWeb.UserAuth

  @doc """
  Accepts a signed JWT (`jwt` or `token` body field), upserts the user, and sets the session cookie.
  """
  def exchange(conn, params) do
    jwt = Map.get(params, "jwt") || Map.get(params, "token")

    if is_binary(jwt) and jwt != "" do
      exchange_verified_jwt(conn, jwt)
    else
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "missing_jwt"})
    end
  end

  defp exchange_verified_jwt(conn, jwt) do
    case SSO.verify_shared_secret_jwt(jwt) do
      {:ok, claims} -> upsert_and_respond(conn, claims)
      {:error, reason} -> invalid_token(conn, reason)
    end
  end

  defp upsert_and_respond(conn, claims) do
    case Accounts.upsert_user_from_sso_jwt_claims(claims) do
      {:ok, user} ->
        conn
        |> UserAuth.log_in_user(user)
        |> put_status(:ok)
        |> json(%{ok: true, user_id: user.id})

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_user"})

      {:error, _} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "could_not_upsert_user"})
    end
  end

  defp invalid_token(conn, reason) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "invalid_token", reason: error_reason(reason)})
  end

  defp error_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_reason(reason), do: inspect(reason)
end
