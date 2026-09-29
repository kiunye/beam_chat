defmodule BeamChatWeb.RoomLiveTest do
  @moduledoc """
  LiveView smoke test for the rooms surface: directory renders for signed-in
  members; anonymous visitors are redirected.
  """

  use BeamChatWeb.ConnCase

  alias BeamChat.Accounts
  alias BeamChat.Rooms

  test "anonymous request for the directory redirects to sign-in", %{conn: conn} do
    conn = get(conn, "/rooms")

    assert redirected_to(conn, 302) =~ "/auth/login"
    assert conn.resp_headers |> Enum.any?(fn {h, _} -> String.downcase(h) == "location" end)
  end

  test "signed-in member sees the rooms directory", %{conn: conn} do
    name = "Open hall #{System.unique_integer([:positive])}"

    {:ok, room} =
      Rooms.create_room(user_fixture(), %{
        "name" => name,
        "type" => "public",
        "category_id" => category_fixture().id
      })

    conn =
      conn
      |> Plug.Test.init_test_session(%{
        user_token: Accounts.generate_user_session_token(user_fixture())
      })
      |> get("/rooms")

    assert response(conn, 200)
    assert conn.resp_body =~ name
    assert room.name == name
  end
end
