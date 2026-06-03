defmodule BeamChatWeb.VideoLiveTest do
  use BeamChatWeb.ConnCase, async: false

  import BeamChat.TestFixtures
  import Phoenix.LiveViewTest

  alias BeamChat.Rooms.AccessPolicy
  alias BeamChat.Rooms.Room
  alias BeamChatWeb.VideoLive

  @moduletag :livekit

  describe "join_video in RoomLive.Show" do
    test "renders the join button for an authenticated member of a public room", %{conn: conn} do
      user = registered_user_fixture()
      owner = user_fixture()
      room = room_fixture(owner, %{type: "public"})

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/rooms/#{room.slug}")

      assert html =~ "video-join-button"
      assert html =~ "video-panel"
    end

    test "blocks a banned user from seeing the video panel", %{conn: conn} do
      # Use user_fixture (not registered_user_fixture) so is_banned actually
      # gets stored — the password registration path doesn't accept it.
      banned = user_fixture(%{is_banned: true})
      owner = user_fixture()
      room = room_fixture(owner, %{type: "public"})

      # Confirm the fixture recorded the ban.
      assert banned.is_banned == true

      conn = log_in_user(conn, banned)
      # The FetchCurrentUser plug treats banned users as logged out, so the
      # require_authenticated on_mount redirects them to /auth/login.
      assert {:error, {:redirect, _}} = live(conn, ~p"/rooms/#{room.slug}")
    end

    test "blocks a non-member from joining video in a private room", %{conn: conn} do
      user = registered_user_fixture()
      owner = user_fixture()
      room = room_fixture(owner, %{type: "private"})

      # Confirm the policy denies video.
      refute AccessPolicy.can_video?(room, user)

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/rooms/#{room.slug}")

      # The room view renders the "membership required" panel — no video
      # controls.
      refute html =~ "video-join-button"
    end
  end

  describe "VideoLive component state machine" do
    test "component renders idle state by default" do
      user = %BeamChat.Accounts.User{
        id: "11111111-1111-1111-1111-111111111111",
        username: "alice"
      }

      room = %Room{
        id: "22222222-2222-2222-2222-222222222222",
        type: "public"
      }

      html =
        render_component(VideoLive,
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

      room = %Room{
        id: "22222222-2222-2222-2222-222222222222",
        type: "public"
      }

      html =
        render_component(VideoLive,
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
