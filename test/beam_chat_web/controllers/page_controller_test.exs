defmodule BeamChatWeb.PageControllerTest do
  use BeamChatWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Chat that stays fast at any scale"
  end
end
