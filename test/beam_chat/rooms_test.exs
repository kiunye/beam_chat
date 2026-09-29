defmodule BeamChat.RoomsTest do
  @moduledoc """
  The room context (PRD §2.3–§2.5): creation gating and ownership,
  directory visibility per room type, membership governance, room
  lifecycle, message soft-deletion, and recent-message reads.
  """

  use BeamChat.DataCase, async: false

  # The shared room fixtures create rooms without a slug, which the room
  # changeset currently rejects (see the defect note below). Re-import
  # TestFixtures without them so the local slug-aware versions can use
  # the same names.
  import BeamChat.TestFixtures,
    except: [room_fixture: 1, room_fixture: 2, paid_room_fixture: 1, paid_room_fixture: 2]

  alias BeamChat.Messages.Message
  alias BeamChat.Messages.Persister
  alias BeamChat.Moderation.ModerationLog
  alias BeamChat.Rooms
  alias BeamChat.Rooms.RoomMember

  setup do
    # Registration fixtures hash passwords with bcrypt; keep the suite fast.
    Application.put_env(:bcrypt_elixir, :log_rounds, 1)

    on_exit(fn -> Application.delete_env(:bcrypt_elixir, :log_rounds) end)

    :ok
  end

  # DEFECT WORKAROUND (lib, reported in the test run summary):
  # Rooms.Room.changeset/2 runs validate_required(:slug) *before* put_slug/1
  # derives one from the name, so every slug-less create fails with
  # "slug can't be blank" even though the slug ends up in the changes.
  # The shared room_fixture creates rooms without a slug, so we shadow it
  # locally with a unique explicit slug (lib/ and test/support are off
  # limits for this task).
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

  describe "create_room/2" do
    test "members can create rooms while creation is open (default) and become the owner" do
      member = user_fixture()

      assert {:ok, room} =
               Rooms.create_room(member, %{
                 name: "Member Room",
                 slug: "member-room-#{System.unique_integer([:positive])}",
                 category_id: category_fixture().id
               })

      assert room.owner_id == member.id
      assert room.is_archived == false

      owner_row = Repo.get_by(RoomMember, room_id: room.id, user_id: member.id)
      assert owner_row.role == "owner"
    end

    test "closing creation forbids members but not moderators or admins" do
      :ok = put_setting(:room_creation_open, false)
      category = category_fixture()

      # the member is rejected at the gate before any changeset validation
      assert {:error, :forbidden} =
               Rooms.create_room(user_fixture(), %{name: "Nope", category_id: category.id})

      assert {:ok, _} =
               Rooms.create_room(moderator_fixture(), %{
                 name: "Mod Room",
                 slug: "mod-room-#{System.unique_integer([:positive])}",
                 category_id: category.id
               })

      assert {:ok, _} =
               Rooms.create_room(admin_fixture(), %{
                 name: "Admin Room",
                 slug: "admin-room-#{System.unique_integer([:positive])}",
                 category_id: category.id
               })
    end

    test "rejects a category that does not exist" do
      assert {:error, :category_not_found} =
               Rooms.create_room(user_fixture(), %{
                 name: "Ghost",
                 category_id: Ecto.UUID.generate()
               })
    end

    test "paid rooms require a positive price" do
      owner = user_fixture()
      category = category_fixture()

      attrs = %{
        name: "Paid Room",
        slug: "paid-room-#{System.unique_integer([:positive])}",
        type: "paid",
        category_id: category.id
      }

      assert {:error, changeset} = Rooms.create_room(owner, attrs)
      assert_error_message(changeset, :price, "can't be blank")

      assert {:error, changeset} =
               Rooms.create_room(owner, Map.put(attrs, :price, Decimal.new("-1")))

      assert_error_message(changeset, :price, "must be greater than %{number}")

      assert {:ok, room} = Rooms.create_room(owner, Map.put(attrs, :price, Decimal.new("100")))
      assert room.is_paid
      assert room.type == "paid"
    end
  end

  describe "list_visible_rooms/2 and count_rooms_by_type/1" do
    setup do
      owner = user_fixture()
      viewer = user_fixture()

      rooms = %{
        public: room_fixture(owner),
        private: room_fixture(owner, %{type: "private"}),
        secret: room_fixture(owner, %{type: "secret"}),
        paid_listed: paid_room_fixture(owner),
        paid_unlisted: paid_room_fixture(owner, %{is_listed: false}),
        archived: room_fixture(owner)
      }

      assert {:ok, _} = Rooms.set_archived(owner, rooms.archived, true)

      %{owner: owner, viewer: viewer, rooms: rooms}
    end

    test "members see public, private, and listed paid rooms only", %{
      viewer: viewer,
      rooms: rooms
    } do
      ids = visible_ids(viewer)

      assert rooms.public.id in ids
      assert rooms.private.id in ids
      assert rooms.paid_listed.id in ids

      refute rooms.secret.id in ids
      refute rooms.paid_unlisted.id in ids
      # archived rooms are never listed
      refute rooms.archived.id in ids
    end

    test "membership and subscription unlock secret and unlisted paid rooms (fresh ids per call)",
         %{
           viewer: viewer,
           rooms: rooms
         } do
      refute rooms.secret.id in visible_ids(viewer)
      refute rooms.paid_unlisted.id in visible_ids(viewer)

      member_fixture(rooms.secret, viewer)
      subscribe_fixture(viewer, rooms.paid_unlisted)

      ids = visible_ids(viewer)
      assert rooms.secret.id in ids
      assert rooms.paid_unlisted.id in ids
    end

    test "staff see everything except archived rooms", %{rooms: rooms} do
      for staff <- [admin_fixture(), moderator_fixture()] do
        ids = visible_ids(staff)

        assert rooms.public.id in ids
        assert rooms.private.id in ids
        assert rooms.secret.id in ids
        assert rooms.paid_listed.id in ids
        assert rooms.paid_unlisted.id in ids
        refute rooms.archived.id in ids
      end
    end

    test "count_rooms_by_type/1 counts only the visible rooms per type", %{viewer: viewer} do
      counts = Rooms.count_rooms_by_type(viewer)

      assert counts["public"] == 1
      assert counts["private"] == 1
      assert counts["paid"] == 1
      # the secret room is invisible to a non-member, so the type is absent
      refute Map.has_key?(counts, "secret")

      staff_counts = Rooms.count_rooms_by_type(admin_fixture())
      assert staff_counts["public"] == 1
      assert staff_counts["secret"] == 1
      assert staff_counts["paid"] == 2
    end
  end

  describe "membership reads" do
    test "expired membership rows read as absent" do
      owner = user_fixture()
      room = room_fixture(owner)
      temp_member = user_fixture()

      past = DateTime.add(DateTime.utc_now(), -3_600, :second)

      assert {:ok, _} = Rooms.add_member(owner, room, temp_member, expires_at: past)

      assert is_nil(Rooms.room_member_role(room.id, temp_member.id))
      refute Rooms.room_member?(room.id, temp_member.id)
      # only the owner still counts
      assert Rooms.member_count(room.id) == 1
    end

    test "unexpired membership rows read normally" do
      owner = user_fixture()
      room = room_fixture(owner)
      member = user_fixture()
      member_fixture(room, member)

      assert Rooms.room_member_role(room.id, member.id) == "member"
      assert Rooms.room_member?(room.id, member.id)
      assert Rooms.member_count(room.id) == 2
    end
  end

  describe "add_member/4" do
    setup do
      owner = user_fixture()
      room = room_fixture(owner)

      %{owner: owner, room: room}
    end

    test "the owner adds a member and the action is logged", %{owner: owner, room: room} do
      member = user_fixture()

      assert {:ok, %RoomMember{} = row} = Rooms.add_member(owner, room, member)
      assert row.role == "member"
      assert Rooms.room_member_role(room.id, member.id) == "member"

      log = Repo.one(from l in ModerationLog, where: l.action == "member_added")

      refute is_nil(log)
      assert log.target_type == "room"
      assert log.target_id == room.id
      assert log.actor_id == owner.id
      assert log.metadata["user_id"] == member.id
    end

    test "a platform moderator can add members", %{room: room} do
      member = user_fixture()

      assert {:ok, _} = Rooms.add_member(moderator_fixture(), room, member)
      assert Rooms.room_member_role(room.id, member.id) == "member"
    end

    test "a plain member who does not manage the room is forbidden", %{room: room} do
      assert {:error, :forbidden} = Rooms.add_member(user_fixture(), room, user_fixture())
    end

    test "adding an existing member is rejected", %{owner: owner, room: room} do
      member = user_fixture()
      member_fixture(room, member)

      assert {:error, :already_member} = Rooms.add_member(owner, room, member)
    end

    test "rooms at capacity reject new members", %{owner: owner} do
      room = room_fixture(owner, %{max_members: 1})

      assert {:error, :room_full} = Rooms.add_member(owner, room, user_fixture())
    end
  end

  describe "remove_member/3" do
    test "a member can always leave on their own" do
      owner = user_fixture()
      room = room_fixture(owner)
      member = user_fixture()
      member_fixture(room, member)

      assert {:ok, %RoomMember{}} = Rooms.remove_member(member, room, member)
      refute Rooms.room_member?(room.id, member.id)
    end

    test "the room owner cannot be removed" do
      owner = user_fixture()
      room = room_fixture(owner)

      assert {:error, :owner_immovable} = Rooms.remove_member(admin_fixture(), room, owner)
    end

    test "a non-manager cannot remove someone else" do
      owner = user_fixture()
      room = room_fixture(owner)
      first = user_fixture()
      second = user_fixture()
      member_fixture(room, first)
      member_fixture(room, second)

      assert {:error, :forbidden} = Rooms.remove_member(first, room, second)
      assert Rooms.room_member?(room.id, second.id)
    end
  end

  describe "set_member_role/4" do
    setup do
      owner = user_fixture()
      room = room_fixture(owner)
      member = user_fixture()
      member_fixture(room, member)

      %{owner: owner, room: room, member: member}
    end

    test "the room owner promotes a member to moderator", %{
      owner: owner,
      room: room,
      member: member
    } do
      assert {:ok, updated} = Rooms.set_member_role(owner, room, member, "moderator")
      assert updated.role == "moderator"
      assert Rooms.room_member_role(room.id, member.id) == "moderator"
    end

    test "a platform admin can change room roles", %{room: room, member: member} do
      assert {:ok, _} = Rooms.set_member_role(admin_fixture(), room, member, "moderator")
      assert Rooms.room_member_role(room.id, member.id) == "moderator"
    end

    test "a room moderator cannot (room_manage is owner/admin only)", %{
      room: room,
      member: member
    } do
      room_mod = user_fixture()
      member_fixture(room, room_mod, "moderator")

      assert {:error, :forbidden} = Rooms.set_member_role(room_mod, room, member, "moderator")
      assert Rooms.room_member_role(room.id, member.id) == "member"
    end
  end

  describe "update_room/3" do
    setup do
      owner = user_fixture()
      room = room_fixture(owner)

      %{owner: owner, room: room}
    end

    test "the owner renames the room", %{owner: owner, room: room} do
      assert {:ok, updated} = Rooms.update_room(owner, room, %{name: "Renamed"})
      assert updated.name == "Renamed"
      assert Rooms.get_room!(room.id).name == "Renamed"
    end

    test "a plain member is forbidden", %{room: room} do
      assert {:error, :forbidden} = Rooms.update_room(user_fixture(), room, %{name: "Nope"})
    end

    test "a platform admin can edit the room", %{room: room} do
      assert {:ok, updated} =
               Rooms.update_room(admin_fixture(), room, %{description: "admin edit"})

      assert updated.description == "admin edit"
    end
  end

  describe "set_archived/3" do
    setup do
      owner = user_fixture()
      room = room_fixture(owner)

      %{owner: owner, room: room}
    end

    test "the owner archives and the room leaves the directory", %{owner: owner, room: room} do
      assert {:ok, archived} = Rooms.set_archived(owner, room, true)
      assert archived.is_archived
      refute archived.id in visible_ids(user_fixture())

      assert {:ok, restored} = Rooms.set_archived(admin_fixture(), room, false)
      refute restored.is_archived
    end

    test "a plain member is forbidden", %{room: room} do
      assert {:error, :forbidden} = Rooms.set_archived(user_fixture(), room, true)
      refute Rooms.get_room!(room.id).is_archived
    end
  end

  describe "delete_message/3" do
    test "a platform moderator soft-deletes and the action is logged" do
      owner = user_fixture()
      room = room_fixture(owner)

      {:ok, message} = Rooms.send_message(room, owner.id, "to be deleted")

      assert {:ok, deleted} = Rooms.delete_message(moderator_fixture(), message)
      assert deleted.is_deleted

      persisted = Repo.get_by(Message, id: message.id)
      assert persisted.is_deleted

      log = Repo.one(from l in ModerationLog, where: l.action == "message_deleted")

      refute is_nil(log)
      assert log.target_type == "room"
      assert log.target_id == room.id
      assert log.metadata["message_id"] == message.id
    end

    test "a random member is forbidden" do
      owner = user_fixture()
      room = room_fixture(owner)

      {:ok, message} = Rooms.send_message(room, owner.id, "stay put")

      assert {:error, :forbidden} = Rooms.delete_message(user_fixture(), message)
    end
  end

  describe "list_recent_messages/2" do
    test "returns the newest N messages in oldest-first order" do
      owner = user_fixture()
      room = room_fixture(owner)

      # Timestamps are controlled explicitly: utc_datetime has second
      # precision, so real-time sends would tie on inserted_at and the
      # UUID tiebreak is not chronologically meaningful.
      base = DateTime.add(DateTime.utc_now() |> DateTime.truncate(:second), -60, :second)

      batch =
        for i <- 1..5 do
          %{
            kind: :room,
            room_id: room.id,
            user_id: owner.id,
            content: "recent #{i}",
            inserted_at: DateTime.add(base, i, :second)
          }
        end

      results = Persister.persist_ordered(batch)
      assert Enum.all?(results, &match?({:ok, _}, &1))

      messages = Rooms.list_recent_messages(room.id, 3)

      assert Enum.map(messages, & &1.content) == ["recent 3", "recent 4", "recent 5"]
      # preloaded for display
      assert Enum.all?(messages, &(&1.sender.id == owner.id))
    end
  end

  defp visible_ids(user) do
    user |> Rooms.list_visible_rooms() |> Enum.map(& &1.id)
  end

  defp assert_error_message(changeset, field, message) do
    assert Enum.any?(changeset.errors, fn {error_field, {error_message, _details}} ->
             error_field == field and error_message == message
           end),
           "expected an error on #{inspect(field)} with message #{inspect(message)}, got: #{inspect(changeset.errors)}"
  end
end
