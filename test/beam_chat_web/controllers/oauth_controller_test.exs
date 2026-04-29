defmodule BeamChatWeb.OAuthControllerTest do
  use BeamChatWeb.ConnCase

  test "GET /auth/oauth/unknown redirects to login", %{conn: conn} do
    conn = get(conn, ~p"/auth/oauth/unknown")

    assert redirected_to(conn) == ~p"/auth/login"
  end
end
