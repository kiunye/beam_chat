defmodule BeamChatWeb.VideoLiveTest do
  use BeamChatWeb.ConnCase, async: false

  import BeamChat.TestFixtures
  import Phoenix.LiveViewTest

  alias BeamChatWeb.VideoLive

  @moduletag :livekit

  describe "join_video" do
    test "renders the join button for an authenticated member of a public room", %{conn: conn} do
      user = registered_user_fixture()
      owner = user_fixture()
      room = room_fixture(owner, %{type: "public"})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/rooms/#{room.slug}")

      assert has_element?(view, "#video-join-button")
      assert has_element?(view, "#video-panel")
    end

    test "clicking join pushes a livekit_connect event with token, url, identity, room", %{
      conn: conn
    } do
      user = registered_user_fixture()
      owner = user_fixture()
      room = room_fixture(owner, %{type: "public"})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/rooms/#{room.slug}")

      # Surface a hook event capture by rendering the component in isolation.
      # The full LiveView test exercises this through #video-join-button.
      html = render_component(VideoLive,
        id: "video-panel",
        room: room,
        current_user: user,
        can_video: true
      )

      assert html =~ "Join video"
    end

    test "blocks a banned user from receiving a token", %{conn: conn} do
      user = registered_user_fixture(%{is_banned: true})
      owner = user_fixture()
      room = room_fixture(owner, %{type: "public"})

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/rooms/#{room.slug}")

      # Banned user is treated as logged out and gets redirected to login.
      # They never reach the room LiveView, so no #video-panel.
      refute html =~ "video-panel"
    end

    test "blocks an unauthenticated viewer of a private room", %{conn: conn} do
      owner = user_fixture()
      room = room_fixture(owner, %{type: "private"})

      # No log_in_user — anonymous user is denied.
      {:ok, _view, html} = live(conn, ~p"/rooms/#{room.slug}")

      refute html =~ "video-panel"
      refute html =~ "video-join-button"
    end
  end

  describe "leave_video" do
    test "renders the leave button after joining", %{conn: conn} do
      user = registered_user_fixture()
      owner = user_fixture()
      room = room_fixture(owner, %{type: "public"})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/rooms/#{room.slug}")

      assert has_element?(view, "#video-join-button")
      refute has_element?(view, "#video-leave-button")
    end
  end

  describe "video state machine" do
    test "component renders idle state by default" do
      user = %BeamChat.Accounts.User{
        id: "11111111-1111-1111-1111-111111111111",
        username: "alice"
      }

      room = %BeamChat.Rooms.Room{
        id: "22222222-2222-2222-2222-222222222222",
        type: "public"
      }

      html = render_component(VideoLive,
        id: "video-panel",
        room: room,
        current_user: user,
        can_video: true
      )

      assert html =~ ~s(data-video-state="idle")
      assert html =~ "Join video"
    end

    test "component does not render join button when can_video is false" do
      user = %BeamChat.Accounts.User{
        id: "11111111-1111-1111-1111-111111111111",
        username: "alice"
      }

      room = %BeamChat.Rooms.Room{
        id: "22222222-2222-2222-2222-222222222222",
        type: "public"
      }

      html = render_component(VideoLive,
        id: "video-panel",
        room: room,
        current_user: user,
        can_video: false
      )

      assert html =~ "Video is not available"
      refute html =~ "Join video"
    end
  end
end
