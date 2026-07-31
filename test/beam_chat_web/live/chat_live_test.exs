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

  test "messages thread rate-limits excess GETs (P1 #11)", %{conn: conn} do
    u1 = registered_user_fixture()
    u2 = user_fixture()
    conv = conversation_fixture(u1, u2)
    conn = log_in_user(conn, u1)

    # First 60 navigations stay in the thread.
    for _ <- 1..60 do
      {:ok, _view, _html} = live(conn, ~p"/messages/#{conv.id}")
      conn = recycle(conn)
    end

    # 61st navigation gets bounced back to the inbox with a flash.
    {:ok, view, html} = live(conn, ~p"/messages/#{conv.id}")

    assert html =~ "loading that conversation too quickly"
    assert has_element?(view, "#dm-compose-form")
  end
end
