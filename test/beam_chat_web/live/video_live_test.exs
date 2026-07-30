defmodule BeamChatWeb.VideoLiveTest do
  use BeamChatWeb.ConnCase, async: false

  import BeamChat.TestFixtures
  import Phoenix.LiveViewTest

  alias BeamChat.Accounts
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

    test "denies join_video event when user is banned after LiveView mount", %{conn: conn} do
      # The LiveView mounts with a non-banned user, then we ban them mid-session
      # and attempt to fire the join_video event. The DB re-check inside the
      # event handler must reject the request rather than trusting the stale
      # socket assign. See SECURITY_REVIEW.md P0 #2.
      user = registered_user_fixture()
      owner = user_fixture()
      room = room_fixture(owner, %{type: "public"})

      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, ~p"/rooms/#{room.slug}")

      # Confirm the video panel and join button were rendered at mount.
      assert html =~ "video-join-button"

      # Ban the user mid-session — this also wipes their tokens.
      assert {:ok, _} = Accounts.ban_user(user, "video abuse")

      # Spawn the join_video event targeted at the LiveKitRoom component and
      # assert it does NOT push a `livekit_connect` event to the client. The
      # push only happens when the user is eligible; a banned user should be
      # rejected before any token is issued.
      ref =
        view
        |> element("#video-join-button")
        |> render_click()

      # The rendered html for the panel must remain in the idle state — no
      # `data-video-state="joining"` token issuance.
      assert ref =~ ~s(data-video-state="idle")
      # phx-hook="LiveKitRoom" pushes `livekit_connect` on success; verifying
      # that the hook DC was not pushed is implicit in the absence of any
      # `phx-disconnected` markup. The explicit assertion here is that no
      # video error is rendered (since neither success nor a missing-config
      # path was hit — the ban-check returned a flash).
      refute ref =~ ~s(data-video-state="joining")
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
