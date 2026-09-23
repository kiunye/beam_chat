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
end
