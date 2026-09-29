defmodule BeamChat.Rooms.AccessPolicyTest do
  @moduledoc """
  Room entry decisions per room type (PRD §2.3, §2.6): the full `check/2`
  matrix, `can_video?/2`, and the freshness guarantees on membership and
  subscription rows.
  """

  use BeamChat.DataCase, async: true

  # The shared room fixtures create rooms without a slug, which the room
  # changeset currently rejects (see the defect note below). Re-import
  # TestFixtures without them so the local slug-aware versions can use
  # the same names.
  import BeamChat.TestFixtures,
    except: [room_fixture: 1, room_fixture: 2, paid_room_fixture: 1, paid_room_fixture: 2]

  alias BeamChat.Rooms
  alias BeamChat.Rooms.AccessPolicy

  # DEFECT WORKAROUND (lib, reported in the test run summary):
  # Rooms.Room.changeset/2 runs validate_required(:slug) before put_slug/1
  # derives one from the name, so the shared room_fixture — which creates
  # rooms without a slug — fails. Shadow both room fixtures locally with
  # an explicit slug.
  defp room_fixture(owner, attrs \\ []) do
    BeamChat.TestFixtures.room_fixture(owner, ensure_room_slug(attrs))
  end

  defp paid_room_fixture(owner, attrs \\ []) do
    BeamChat.TestFixtures.paid_room_fixture(owner, ensure_room_slug(attrs))
  end

  defp ensure_room_slug(attrs) do
    attrs = Map.new(attrs)

    if Map.has_key?(attrs, :slug) do
      attrs
    else
      Map.put(attrs, :slug, "room-#{System.unique_integer([:positive])}")
    end
  end

  describe "check/2 by room type" do
    test "public rooms admit any authenticated user" do
      owner = user_fixture()
      room = room_fixture(owner)

      assert :ok = AccessPolicy.check(room, owner)
      assert :ok = AccessPolicy.check(room, user_fixture())
    end

    test "private rooms require membership" do
      owner = user_fixture()
      room = room_fixture(owner, %{type: "private"})
      member = user_fixture()
      member_fixture(room, member)

      assert :ok = AccessPolicy.check(room, member)
      assert {:blocked, :membership_required} = AccessPolicy.check(room, user_fixture())
    end

    test "secret rooms look forbidden to non-members" do
      owner = user_fixture()
      room = room_fixture(owner, %{type: "secret"})
      member = user_fixture()
      member_fixture(room, member)

      assert :ok = AccessPolicy.check(room, member)
      assert {:blocked, :secret_forbidden} = AccessPolicy.check(room, user_fixture())
    end

    test "paid rooms admit members and active subscribers only" do
      owner = user_fixture()
      room = paid_room_fixture(owner)
      member = user_fixture()
      subscriber = user_fixture()
      member_fixture(room, member)
      subscribe_fixture(subscriber, room)

      assert :ok = AccessPolicy.check(room, member)
      assert :ok = AccessPolicy.check(room, subscriber)
      assert {:blocked, :upgrade_required} = AccessPolicy.check(room, user_fixture())
    end

    test "a stale 'active' subscription past its expiry is never trusted" do
      owner = user_fixture()
      room = paid_room_fixture(owner)
      stale_subscriber = user_fixture()

      subscribe_fixture(stale_subscriber, room,
        expires_at: DateTime.add(DateTime.utc_now(), -86_400, :second)
      )

      assert {:blocked, :upgrade_required} = AccessPolicy.check(room, stale_subscriber)
      refute AccessPolicy.active_subscription?(room.id, stale_subscriber.id)
    end

    test "archived rooms block members but not staff" do
      owner = user_fixture()
      room = room_fixture(owner)
      member = user_fixture()
      member_fixture(room, member)

      assert {:ok, room} = Rooms.set_archived(owner, room, true)

      assert {:blocked, :archived} = AccessPolicy.check(room, member)
      assert :ok = AccessPolicy.check(room, admin_fixture())
      assert :ok = AccessPolicy.check(room, moderator_fixture())
    end

    test "banned users are blocked everywhere" do
      room = room_fixture(user_fixture())
      banned = banned_user_fixture()

      assert {:blocked, :banned} = AccessPolicy.check(room, banned)
    end

    test "anonymous and missing inputs are rejected" do
      room = room_fixture(user_fixture())

      assert {:blocked, :not_authenticated} = AccessPolicy.check(room, nil)
      assert {:blocked, :secret_forbidden} = AccessPolicy.check(nil, user_fixture())
    end

    test "platform admins and moderators enter every room regardless of type" do
      owner = user_fixture()

      rooms = [
        room_fixture(owner),
        room_fixture(owner, %{type: "private"}),
        room_fixture(owner, %{type: "secret"}),
        paid_room_fixture(owner)
      ]

      for staff <- [admin_fixture(), moderator_fixture()], room <- rooms do
        assert :ok = AccessPolicy.check(room, staff)
      end
    end
  end

  describe "can_video?/2" do
    test "mirrors check/2 exactly" do
      owner = user_fixture()

      public = room_fixture(owner)
      private = room_fixture(owner, %{type: "private"})
      paid = paid_room_fixture(owner)

      stranger = user_fixture()
      member = user_fixture()
      member_fixture(private, member)
      member_fixture(paid, member)

      assert AccessPolicy.can_video?(public, stranger)
      refute AccessPolicy.can_video?(private, stranger)
      assert AccessPolicy.can_video?(private, member)
      refute AccessPolicy.can_video?(paid, stranger)
      assert AccessPolicy.can_video?(paid, member)
      refute AccessPolicy.can_video?(paid, nil)
      assert AccessPolicy.can_video?(paid, admin_fixture())
    end
  end

  describe "active_member?/2 and active_subscription?/2" do
    test "active_member?/2 is true only for unexpired memberships" do
      owner = user_fixture()
      room = room_fixture(owner)
      member = user_fixture()
      expired = user_fixture()

      member_fixture(room, member)

      past = DateTime.add(DateTime.utc_now(), -600, :second)
      assert {:ok, _} = Rooms.add_member(owner, room, expired, expires_at: past)

      assert AccessPolicy.active_member?(room.id, member.id)
      refute AccessPolicy.active_member?(room.id, expired.id)
      refute AccessPolicy.active_member?(room.id, user_fixture().id)
    end

    test "active_subscription?/2 ignores stale or cancelled rows" do
      owner = user_fixture()
      room = paid_room_fixture(owner)

      active = user_fixture()
      stale = user_fixture()
      cancelled = user_fixture()

      subscribe_fixture(active, room)
      subscribe_fixture(stale, room, expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      subscribe_fixture(cancelled, room, status: "cancelled")

      assert AccessPolicy.active_subscription?(room.id, active.id)
      refute AccessPolicy.active_subscription?(room.id, stale.id)
      refute AccessPolicy.active_subscription?(room.id, cancelled.id)
      refute AccessPolicy.active_subscription?(room.id, user_fixture().id)
    end
  end
end
