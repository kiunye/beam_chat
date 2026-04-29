defmodule BeamChatWeb.ChatLiveTest do
  use BeamChatWeb.ConnCase, async: false

  import BeamChat.TestFixtures
  import Phoenix.LiveViewTest

  test "messages index renders compose form", %{conn: conn} do
    user = registered_user_fixture()
    conn = log_in_user(conn, user)
    {:ok, _view, html} = live(conn, ~p"/messages")

    assert html =~ "Direct messages"
    assert html =~ "dm-compose-form"
  end

  test "messages thread loads for participants", %{conn: conn} do
    u1 = registered_user_fixture()
    u2 = user_fixture()
    conv = conversation_fixture(u1, u2)

    conn = log_in_user(conn, u1)
    {:ok, view, _html} = live(conn, ~p"/messages/#{conv.id}")

    assert has_element?(view, "#dm-message-form")
  end
end
