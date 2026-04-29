defmodule BeamChatWeb.HealthControllerTest do
  use BeamChatWeb.ConnCase

  test "GET /health returns ok and node", %{conn: conn} do
    conn = get(conn, ~p"/health")
    body = json_response(conn, 200)
    assert body["status"] == "ok"
    assert is_binary(body["node"])
  end
end
