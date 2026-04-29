defmodule BeamChat.Rooms.AccessPolicyTest do
  use BeamChat.DataCase, async: true

  import BeamChat.TestFixtures

  alias BeamChat.Rooms.AccessPolicy

  test "public room allows any signed-in user" do
    user = user_fixture()
    room = room_fixture(user, %{type: "public"})
    assert AccessPolicy.check(room, user) == :ok
  end

  test "private room blocks non-members" do
    owner = user_fixture()
    other = user_fixture()
    room = room_fixture(owner, %{type: "private"})
    assert AccessPolicy.check(room, other) == {:blocked, :membership_required}
  end

  test "private room allows member" do
    owner = user_fixture()
    member = user_fixture()
    room = room_fixture(owner, %{type: "private"})
    _ = room_member_fixture(room, member)
    assert AccessPolicy.check(room, member) == :ok
  end

  test "paid room requires active subscription when is_paid" do
    owner = user_fixture()
    guest = user_fixture()
    room = room_fixture(owner, %{type: "paid", is_paid: true})
    assert AccessPolicy.check(room, guest) == {:blocked, :upgrade_required}
    _ = group_subscription_fixture(guest, room)
    assert AccessPolicy.check(room, guest) == :ok
  end
end
