defmodule BeamChatWeb.RegistrationControllerTest do
  use BeamChatWeb.ConnCase

  import BeamChat.TestFixtures

  test "GET /auth/register renders", %{conn: conn} do
    conn = get(conn, ~p"/auth/register")
    assert response(conn, 200) =~ "Create account"
  end

  test "POST /auth/register creates user and signs in", %{conn: conn} do
    suffix = unique_suffix()

    conn =
      post(conn, ~p"/auth/register", %{
        "user" => %{
          "username" => "newuser_" <> suffix,
          "email" => "new_" <> suffix <> "@example.com",
          "password" => "password12"
        }
      })

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, "user_token")
  end
end
