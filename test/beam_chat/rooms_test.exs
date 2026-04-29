defmodule BeamChat.RoomsTest do
  use BeamChat.DataCase, async: true

  import BeamChat.TestFixtures

  alias BeamChat.Rooms

  test "list_rooms_for_index returns paginated map" do
    user = user_fixture()
    owner = user_fixture()

    for _ <- 1..55, do: room_fixture(owner, %{type: "public"})

    assert %{rooms: page1, total_count: 55, page: 1, limit: 50, page_count: 2} =
             Rooms.list_rooms_for_index(user, %{page: 1, limit: 50})

    assert length(page1) == 50

    assert %{rooms: page2, total_count: 55, page: 2} =
             Rooms.list_rooms_for_index(user, %{page: 2, limit: 50})

    assert length(page2) == 5

    ids1 = MapSet.new(Enum.map(page1, & &1.id))
    ids2 = MapSet.new(Enum.map(page2, & &1.id))
    assert MapSet.disjoint?(ids1, ids2)
  end

  test "room_access_flags returns member and subscription in one query" do
    owner = user_fixture()
    member = user_fixture()
    guest = user_fixture()
    room = room_fixture(owner, %{type: "paid", is_paid: true})
    _ = room_member_fixture(room, member)
    _ = group_subscription_fixture(guest, room)

    assert %{member: true, active_subscription: false} =
             Rooms.room_access_flags(room.id, member.id)

    assert %{member: false, active_subscription: true} =
             Rooms.room_access_flags(room.id, guest.id)

    assert %{member: false, active_subscription: false} =
             Rooms.room_access_flags(room.id, user_fixture().id)
  end
end
