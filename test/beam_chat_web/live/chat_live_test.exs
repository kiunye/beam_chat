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

    # A single `live/2` drives the LiveView twice — the HTTP render and the
    # websocket mount — and both invoke `handle_params`, where the per-minute
    # thread-view rate limiter runs. So every navigation below counts as two
    # checks against the 60-checks/minute limit. 30 navigations (60 checks)
    # are allowed; the 31st (62nd check) is bounced back to the inbox.
    for _ <- 1..30 do
      {:ok, _view, _html} = live(conn, ~p"/messages/#{conv.id}")
    end

    # 31st navigation gets bounced back to the inbox with a flash.
    {:error, {:live_redirect, %{to: "/messages", flash: flash}}} =
      live(conn, ~p"/messages/#{conv.id}")

    assert flash["error"] =~ "loading that conversation too quickly"
  end
end
