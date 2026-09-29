defmodule BeamChat.AuthorizationTest do
  @moduledoc """
  The single authorization point (PRD §4.5): platform-role permissions via
  `Scope.for_user/1`, room-scoped permission composition, and
  `ensure_permission/2`.
  """

  use BeamChat.DataCase, async: true

  # The shared room_fixture creates rooms without a slug, which the room
  # changeset currently rejects (see the defect note below). Re-import
  # TestFixtures without it so the local slug-aware version can use the
  # same name.
  import BeamChat.TestFixtures, except: [room_fixture: 1, room_fixture: 2]

  alias BeamChat.Authorization
  alias BeamChat.Authorization.Scope
  alias BeamChat.Rooms

  # DEFECT WORKAROUND (lib, reported in the test run summary):
  # Rooms.Room.changeset/2 runs validate_required(:slug) before put_slug/1
  # derives one from the name, so the shared room_fixture — which creates
  # rooms without a slug — fails. Shadow it locally with an explicit slug.
  defp room_fixture(owner, attrs \\ []) do
    attrs = Map.new(attrs)
    slug = Map.get_lazy(attrs, :slug, fn -> "room-#{System.unique_integer([:positive])}" end)
    BeamChat.TestFixtures.room_fixture(owner, Map.put(attrs, :slug, slug))
  end

  @admin_permissions ~w(settings_access user_manage payments_configure structure_manage
    moderation_configure wallet_credit radio_manage room_create room_manage room_moderate
    member_manage message_delete)a

  @moderator_permissions ~w(room_create room_moderate member_manage message_delete)a

  @admin_only_permissions ~w(settings_access user_manage payments_configure structure_manage
    moderation_configure wallet_credit radio_manage)a

  describe "global permissions via Scope.for_user/1" do
    test "admin scope grants the full permission list" do
      scope = Scope.for_user(admin_fixture())

      assert Authorization.permissions(scope) |> Enum.sort() == Enum.sort(@admin_permissions)

      Enum.each(@admin_permissions, fn permission ->
        assert Authorization.can?(scope, permission)
      end)
    end

    test "moderator scope grants only content-moderation permissions, never Settings" do
      scope = Scope.for_user(moderator_fixture())

      assert Authorization.permissions(scope) |> Enum.sort() == Enum.sort(@moderator_permissions)

      Enum.each(@moderator_permissions, fn permission ->
        assert Authorization.can?(scope, permission)
      end)

      Enum.each(@admin_only_permissions, fn permission ->
        refute Authorization.can?(scope, permission)
      end)
    end

    test "member scope grants nothing" do
      scope = Scope.for_user(user_fixture())

      assert Authorization.permissions(scope) == []
      refute Authorization.can?(scope, :room_create)
      refute Authorization.can?(scope, :settings_access)
      refute Authorization.can?(scope, :message_delete)
    end

    test "a nil scope is always denied" do
      refute Authorization.can?(nil, :settings_access)
      refute Authorization.can?(nil, :room_create)
      assert Authorization.permissions(nil) == []
      assert {:error, :forbidden} = Authorization.ensure_permission(nil, :user_manage)
    end
  end

  describe "room-scoped can?/3" do
    test "a room owner gets room management powers for their room only" do
      owner = user_fixture()
      room = room_fixture(owner)
      other_room = room_fixture(user_fixture())

      scope = Scope.for_user(owner)

      assert Authorization.can?(scope, :room_manage, %{room: room})
      assert Authorization.can?(scope, :member_manage, %{room: room})
      assert Authorization.can?(scope, :room_moderate, %{room: room})
      assert Authorization.can?(scope, :message_delete, %{room: room})

      # room powers never leak platform-level Settings access…
      refute Authorization.can?(scope, :settings_access, %{room: room})
      refute Authorization.can?(scope, :user_manage, %{room: room})

      # …and never apply to someone else's room
      refute Authorization.can?(scope, :room_manage, %{room: other_room})
      refute Authorization.can?(scope, :message_delete, %{room: other_room})
    end

    test "a room moderator gets moderation powers but not room management" do
      owner = user_fixture()
      room = room_fixture(owner)
      room_mod = user_fixture()
      member_fixture(room, room_mod, "moderator")

      scope = Scope.for_user(room_mod)

      assert Authorization.can?(scope, :room_moderate, %{room: room})
      assert Authorization.can?(scope, :message_delete, %{room: room})
      refute Authorization.can?(scope, :room_manage, %{room: room})
      refute Authorization.can?(scope, :member_manage, %{room: room})
    end

    test "a platform moderator moderates any room without membership" do
      room = room_fixture(user_fixture())
      scope = Scope.for_user(moderator_fixture())

      assert Authorization.can?(scope, :room_moderate, %{room: room})
      assert Authorization.can?(scope, :message_delete, %{room: room})
      refute Authorization.can?(scope, :room_manage, %{room: room})
    end

    test "a plain member has no room powers even in rooms they joined" do
      owner = user_fixture()
      room = room_fixture(owner)
      member = user_fixture()
      member_fixture(room, member)

      scope = Scope.for_user(member)

      refute Authorization.can?(scope, :message_delete, %{room: room})
      refute Authorization.can?(scope, :room_moderate, %{room: room})
      refute Authorization.can?(scope, :room_manage, %{room: room})
    end

    test "revoking room membership flips the check immediately" do
      owner = user_fixture()
      room = room_fixture(owner)
      room_mod = user_fixture()
      member_fixture(room, room_mod, "moderator")

      scope = Scope.for_user(room_mod)
      assert Authorization.can?(scope, :message_delete, %{room: room})

      # The role is resolved with a fresh database lookup per call, so the
      # revocation takes effect on the very next check.
      assert {:ok, _} = Rooms.remove_member(owner, room, room_mod)
      refute Authorization.can?(scope, :message_delete, %{room: room})
    end
  end

  describe "ensure_permission/2" do
    test "returns :ok when the platform role grants the permission" do
      admin = admin_fixture()

      assert :ok = Authorization.ensure_permission(admin, :user_manage)
      assert :ok = Authorization.ensure_permission(admin, :settings_access)
      assert :ok = Authorization.ensure_permission(admin, :wallet_credit)
    end

    test "returns {:error, :forbidden} otherwise" do
      assert {:error, :forbidden} = Authorization.ensure_permission(user_fixture(), :user_manage)
      assert {:error, :forbidden} = Authorization.ensure_permission(user_fixture(), :room_create)

      # moderators reach content but never Settings/payment configuration
      assert {:error, :forbidden} =
               Authorization.ensure_permission(moderator_fixture(), :payments_configure)

      assert {:error, :forbidden} =
               Authorization.ensure_permission(moderator_fixture(), :wallet_credit)
    end
  end
end
