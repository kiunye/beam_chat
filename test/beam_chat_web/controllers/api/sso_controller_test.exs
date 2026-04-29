defmodule BeamChatWeb.Api.SsoControllerTest do
  use BeamChatWeb.ConnCase

  alias BeamChat.Accounts.User
  alias BeamChat.Repo

  defp sign_sso_jwt(claims) do
    secret = Application.fetch_env!(:beam_chat, :sso_jwt_secret)
    signer = Joken.Signer.create("HS256", secret)
    {:ok, jwt, _claims} = Joken.encode_and_sign(claims, signer)
    jwt
  end

  test "POST /api/sso/exchange creates user and sets session", %{conn: conn} do
    jwt =
      sign_sso_jwt(%{"sub" => "sso-ext-1", "email" => "sso1@example.com", "name" => "SSO One"})

    conn = post(conn, ~p"/api/sso/exchange", %{"jwt" => jwt})

    body = json_response(conn, 200)
    assert body["ok"] == true
    assert is_binary(body["user_id"])
    assert get_session(conn, "user_token")

    user = Repo.get!(User, body["user_id"])
    assert user.sso_provider == "sso_jwt"
    assert user.sso_uid == "sso-ext-1"
  end

  test "POST /api/sso/exchange rejects bad jwt", %{conn: conn} do
    conn = post(conn, ~p"/api/sso/exchange", %{"jwt" => "not-a-jwt"})

    assert json_response(conn, 401)["error"] == "invalid_token"
  end

  test "POST /api/sso/exchange rejects missing sub", %{conn: conn} do
    jwt = sign_sso_jwt(%{"email" => "nope@example.com"})

    conn = post(conn, ~p"/api/sso/exchange", %{"jwt" => jwt})

    assert json_response(conn, 401)["error"] == "invalid_token"
  end
end
