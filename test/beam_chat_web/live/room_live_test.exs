defmodule BeamChatWeb.RoomLiveTest do
  use BeamChatWeb.ConnCase, async: false

  import BeamChat.TestFixtures
  import Phoenix.LiveViewTest

  alias BeamChatWeb.RoomPresence

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

  # Presence is shared tracker state, so these tests live in this async: false
  # module (Phoenix.Presence merges diffs asynchronously in a task; the
  # `RoomPresence.list/1` assertions read the tracker synchronously, and the
  # render assertions sync with the LiveView via `:sys.get_state/1` before
  # reading the HTML).
  describe "video_active presence metadata" do
    test "mounts a public room member with video_active: false in presence", %{conn: conn} do
      user = registered_user_fixture()
      owner = user_fixture()
      room = room_fixture(owner, %{type: "public"})

      conn = log_in_user(conn, user)
      {:ok, _view, _html} = live(conn, ~p"/rooms/#{room.slug}")

      assert %{metas: [%{video_active: false} | _]} =
               RoomPresence.list("room:" <> room.id)[user.id]
    end

    test "video_connected and video_disconnected flip video_active in presence", %{conn: conn} do
      user = registered_user_fixture()
      owner = user_fixture()
      room = room_fixture(owner, %{type: "public"})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/rooms/#{room.slug}")

      topic = "room:" <> room.id
      assert %{metas: [%{video_active: false} | _]} = RoomPresence.list(topic)[user.id]

      render_hook(view, "video_connected", %{"participants" => 1})
      assert %{metas: [%{video_active: true} | _]} = RoomPresence.list(topic)[user.id]

      render_hook(view, "video_disconnected", %{})
      assert %{metas: [%{video_active: false} | _]} = RoomPresence.list(topic)[user.id]
    end

    test "presence panel shows the in-video badge only while video is connected", %{conn: conn} do
      user = registered_user_fixture()
      owner = user_fixture()
      room = room_fixture(owner, %{type: "public"})

      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, ~p"/rooms/#{room.slug}")

      refute html =~ "In video"

      render_hook(view, "video_connected", %{"participants" => 1})
      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#presence-video-" <> user.id, "In video")

      render_hook(view, "video_disconnected", %{})
      _ = :sys.get_state(view.pid)
      refute has_element?(view, "#presence-video-" <> user.id)
    end
  end

  # Regression: the VideoLive panel root used `phx-update="ignore"`, so
  # morphdom skipped patching the panel children when the server-side state
  # flipped to `:connected` — the "N live" badge, "Leave video" button and
  # joining indicator never appeared in the browser even though the server
  # state was correct. The LiveKitRoom hook never manages its own DOM, so
  # the panel must stay patchable (AGENTS.md: `phx-update="ignore"` is only
  # for hooks that manage their own DOM). This test must go through the full
  # LiveView flow (mount -> render_hook -> has_element?); render_component/3
  # full-renders without morphing and would give a false positive.
  describe "video panel patchability" do
    test "video_connected patches the panel DOM and video_disconnected reverts it", %{conn: conn} do
      user = registered_user_fixture()
      owner = user_fixture()
      room = room_fixture(owner, %{type: "public"})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/rooms/#{room.slug}")

      # Idle at mount: no participant badge, "Join video" button present.
      refute has_element?(view, "#video-participant-count")
      assert has_element?(view, "#video-join-button")

      # The LiveKitRoom hook pushes `video_connected`; the panel must patch
      # in the connected UI (badge + "Leave video", join button gone).
      render_hook(view, "video_connected", %{"participants" => 3})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#video-participant-count", "3 live")
      assert has_element?(view, "#video-leave-button")
      refute has_element?(view, "#video-join-button")

      # The hook pushes `video_disconnected`; the panel must return to idle.
      render_hook(view, "video_disconnected", %{})
      _ = :sys.get_state(view.pid)

      refute has_element?(view, "#video-participant-count")
      assert has_element?(view, "#video-join-button")
    end
  end
end
