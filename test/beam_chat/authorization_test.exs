defmodule BeamChat.AuthorizationTest do
  @moduledoc """
  Central permission checks (`BeamChat.Authorization.can?/2`) and scope
  construction (`BeamChat.Authorization.Scope.for_user/2`).

  Roles are exercised through fixtures with explicit `role` attributes so
  the permission union (global role + tenant role) is asserted
  end-to-end: the same path production LiveViews and plugs will use.
  """

  use BeamChat.DataCase, async: false

  import BeamChat.TestFixtures

  alias BeamChat.Authorization
  alias BeamChat.Authorization.Scope
  alias BeamChat.Tenants

  defp uniq, do: :erlang.unique_integer([:positive]) |> to_string()

  defp tenant_with_member(user, role) do
    {:ok, tenant} = Tenants.create_tenant(%{name: "T " <> uniq(), slug: "t-" <> uniq()})
    {:ok, _} = Tenants.add_member(tenant, user, role)
    tenant
  end

  describe "Scope.for_user/2" do
    test "guest scope carries no user, tenant, or role" do
      scope = Scope.for_user(nil, nil)

      assert scope.user == nil
      assert scope.tenant == nil
      assert scope.tenant_role == nil
      assert Scope.user_id(scope) == nil
    end

    test "resolves the tenant membership role once when the tenant is known" do
      user = user_fixture()
      tenant = tenant_with_member(user, "admin")
      scope = Scope.for_user(user, tenant)

      assert scope.user.id == user.id
      assert scope.tenant.id == tenant.id
      assert scope.tenant_role == "admin"
      assert Scope.user_id(scope) == user.id
    end

    test "a user without membership in the tenant gets no tenant role" do
      user = user_fixture()
      stranger = user_fixture()
      tenant = tenant_with_member(user, "member")

      assert Scope.for_user(stranger, tenant).tenant_role == nil
    end
  end

  describe "Authorization.can?/2 with global roles" do
    test "guest scopes hold nothing" do
      refute Authorization.can?(nil, :user_ban)
      refute Authorization.can?(Scope.for_user(nil, nil), :user_ban)
    end

    test "global admin holds user_ban and wallet_credit" do
      admin = user_fixture(%{role: "admin"})
      scope = Scope.for_user(admin, nil)

      assert Authorization.can?(scope, :user_ban)
      assert Authorization.can?(scope, :wallet_credit)
      assert Authorization.can?(scope, :user_manage_roles)
    end

    test "global moderator can ban but cannot credit wallets" do
      moderator = user_fixture(%{role: "moderator"})
      scope = Scope.for_user(moderator, nil)

      assert Authorization.can?(scope, :user_ban)
      refute Authorization.can?(scope, :wallet_credit)
      refute Authorization.can?(scope, :user_manage_roles)
    end

    test "plain members hold no global permissions" do
      member = user_fixture()
      scope = Scope.for_user(member, nil)

      refute Authorization.can?(scope, :user_ban)
      refute Authorization.can?(scope, :wallet_credit)
      refute Authorization.can?(scope, :room_create)
    end

    test "unknown permissions fail closed instead of raising" do
      admin = user_fixture(%{role: "admin"})
      scope = Scope.for_user(admin, nil)

      refute Authorization.can?(scope, :not_a_real_permission)
    end
  end

  describe "Authorization.can?/2 with tenant roles" do
    test "tenant admins can create rooms in their tenant" do
      user = user_fixture()
      tenant = tenant_with_member(user, "admin")
      scope = Scope.for_user(user, tenant)

      assert Authorization.can?(scope, :room_create)
      assert Authorization.can?(scope, :tenant_manage)
    end

    test "tenant members cannot create rooms" do
      user = user_fixture()
      tenant = tenant_with_member(user, "member")
      scope = Scope.for_user(user, tenant)

      refute Authorization.can?(scope, :room_create)
      refute Authorization.can?(scope, :tenant_manage)
    end

    test "tenant powers do not leak global powers" do
      user = user_fixture()
      tenant = tenant_with_member(user, "admin")
      scope = Scope.for_user(user, tenant)

      refute Authorization.can?(scope, :user_ban)
      refute Authorization.can?(scope, :wallet_credit)
    end

    test "the permission union combines global and tenant roles" do
      moderator = user_fixture(%{role: "moderator"})
      tenant = tenant_with_member(moderator, "admin")
      scope = Scope.for_user(moderator, tenant)

      # global moderator powers ...
      assert Authorization.can?(scope, :user_ban)
      # ... combined with tenant admin powers.
      assert Authorization.can?(scope, :room_create)
      # still no wallet credit from either role.
      refute Authorization.can?(scope, :wallet_credit)
    end
  end

  describe "Authorization.can?/3 with a room context" do
    test "a room owner holds owner powers in their room" do
      owner = user_fixture()
      room = room_fixture(owner)

      # `room_fixture/2` inserts only the room row; the owner membership is
      # created by `Rooms.create_room/1` in production, so mirror it here.
      room_member_fixture(room, owner, %{role: "owner"})

      scope = Scope.for_user(owner, nil)

      assert Authorization.can?(scope, :room_update, %{room: room})
      assert Authorization.can?(scope, :room_delete, %{room: room})
      assert Authorization.can?(scope, :room_manage_members, %{room: room})
      assert Authorization.can?(scope, :room_message_delete, %{room: room})
    end

    test "a room moderator can moderate but cannot delete the room" do
      owner = user_fixture()
      moderator = user_fixture()
      room = room_fixture(owner)
      room_member_fixture(room, moderator, %{role: "moderator"})
      scope = Scope.for_user(moderator, nil)

      assert Authorization.can?(scope, :room_update, %{room: room})
      assert Authorization.can?(scope, :room_manage_members, %{room: room})
      assert Authorization.can?(scope, :room_message_delete, %{room: room})
      refute Authorization.can?(scope, :room_delete, %{room: room})
    end

    test "a plain room member holds no room powers" do
      owner = user_fixture()
      member = user_fixture()
      room = room_fixture(owner)
      room_member_fixture(room, member)
      scope = Scope.for_user(member, nil)

      refute Authorization.can?(scope, :room_update, %{room: room})
      refute Authorization.can?(scope, :room_delete, %{room: room})
      refute Authorization.can?(scope, :room_message_delete, %{room: room})
    end

    test "a non-member of the room gets nothing from the room context" do
      owner = user_fixture()
      stranger = user_fixture()
      room = room_fixture(owner)
      scope = Scope.for_user(stranger, nil)

      refute Authorization.can?(scope, :room_update, %{room: room})
      refute Authorization.can?(scope, :room_message_delete, %{room: room})
    end

    test "room powers apply only within the room context" do
      owner = user_fixture()
      room = room_fixture(owner)
      scope = Scope.for_user(owner, nil)

      # Owner powers are room-scoped: no :room_create (a tenant-level
      # permission) and no global powers fall out of the context.
      refute Authorization.can?(scope, :room_create)
      refute Authorization.can?(scope, :user_ban)
      refute Authorization.can?(scope, :wallet_credit)
    end

    test "room role unions with the scope's global and tenant roles" do
      moderator = user_fixture(%{role: "moderator"})
      owner = user_fixture()
      room = room_fixture(owner)
      room_member_fixture(room, moderator, %{role: "member"})
      scope = Scope.for_user(moderator, nil)

      # The room context grants nothing extra (plain member), but the
      # scope still carries the global moderator powers.
      refute Authorization.can?(scope, :room_message_delete, %{room: room})
      assert Authorization.can?(scope, :user_ban, %{room: room})
    end

    test "guest scopes are denied in room context too" do
      owner = user_fixture()
      room = room_fixture(owner)

      refute Authorization.can?(nil, :room_message_delete, %{room: room})
      refute Authorization.can?(Scope.for_user(nil, nil), :room_message_delete, %{room: room})
    end
  end

  describe "Roles catalogue integrity" do
    alias BeamChat.Authorization.Roles

    test "every permission in the catalogue is declared in the type union" do
      declared = [
        :moderation_configure,
        :room_create,
        :room_delete,
        :room_manage_members,
        :room_message_delete,
        :room_update,
        :tenant_manage,
        :user_ban,
        :user_manage_roles,
        :wallet_credit
      ]

      assert Enum.sort(declared) == Roles.all_permissions()
    end

    test "unknown roles at any level hold nothing" do
      assert Roles.global_permissions("superuser") == []
      assert Roles.tenant_permissions("superuser") == []
      assert Roles.room_permissions("superuser") == []
      assert Roles.global_permissions(nil) == []
      assert Roles.tenant_permissions(nil) == []
      assert Roles.room_permissions(nil) == []
    end
  end
end
