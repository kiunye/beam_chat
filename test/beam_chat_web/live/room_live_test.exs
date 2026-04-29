defmodule BeamChatWeb.RoomLiveTest do
  use BeamChatWeb.ConnCase, async: false

  import BeamChat.TestFixtures
  import Phoenix.LiveViewTest

  test "index lists a public room", %{conn: conn} do
    user = registered_user_fixture()
    owner = user_fixture()
    room = room_fixture(owner, %{type: "public", name: "Lobby Alpha"})

    conn = log_in_user(conn, user)
    {:ok, _view, html} = live(conn, ~p"/rooms")

    assert html =~ "Lobby Alpha"
    assert html =~ room.slug
  end

  test "show renders upgrade panel for paid room without subscription", %{conn: conn} do
    user = registered_user_fixture()
    owner = user_fixture()
    room = room_fixture(owner, %{type: "paid", is_paid: true})

    conn = log_in_user(conn, user)
    {:ok, _view, html} = live(conn, ~p"/rooms/#{room.slug}")

    assert html =~ "Paid room"
    assert html =~ "access-upgrade-panel"
  end

  test "show renders chat for public room", %{conn: conn} do
    user = registered_user_fixture()
    owner = user_fixture()
    room = room_fixture(owner, %{type: "public"})

    conn = log_in_user(conn, user)
    {:ok, view, _html} = live(conn, ~p"/rooms/#{room.slug}")

    assert has_element?(view, "#room-message-form")
    assert has_element?(view, "#room-chat-panel")
  end
end
