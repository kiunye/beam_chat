defmodule BeamChatWeb.MagicLinkControllerTest do
  use BeamChatWeb.ConnCase

  import BeamChat.TestFixtures

  alias BeamChat.Accounts.UserToken
  alias BeamChat.Repo

  test "GET /auth/magic-link/verify with valid token signs in", %{conn: conn} do
    user = registered_user_fixture()
    {raw, token} = UserToken.build_magic_link_token(user, user.email)
    Repo.insert!(token)

    conn = get(conn, ~p"/auth/magic-link/verify", %{"token" => raw})

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, "user_token")
  end

  test "GET /auth/magic-link/verify with bad token redirects to login", %{conn: conn} do
    conn = get(conn, ~p"/auth/magic-link/verify", %{"token" => "invalid"})

    assert redirected_to(conn) == ~p"/auth/login"
  end
end
