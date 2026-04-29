defmodule BeamChatWeb.SessionControllerTest do
  use BeamChatWeb.ConnCase

  import BeamChat.TestFixtures

  test "POST /auth/login signs in with valid credentials", %{conn: conn} do
    user = registered_user_fixture()

    conn =
      post(conn, ~p"/auth/login", %{
        "user" => %{"email" => user.email, "password" => "password12"}
      })

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, "user_token")
  end

  test "POST /auth/login renders error for bad password", %{conn: conn} do
    user = registered_user_fixture()

    conn =
      post(conn, ~p"/auth/login", %{
        "user" => %{"email" => user.email, "password" => "wrongpassword"}
      })

    assert response(conn, 422) =~ "Invalid email or password"
  end

  test "POST /auth/logout clears session", %{conn: conn} do
    user = registered_user_fixture()
    conn = log_in_user(conn, user)

    conn = post(conn, ~p"/auth/logout")

    assert redirected_to(conn) == ~p"/auth/login"
    refute get_session(conn, "user_token")
  end
end
