defmodule BeamChat.Tenants.TenancyTest do
  @moduledoc """
  Tenant membership / role checks and role-based room visibility for the
  multi-tenant room redesign (CATEGORY_REDESIGN.md §4.2 / §4.5 / D5).

  `tenant_members` is RLS-protected in the migration, so `Tenants.admin?/2`
  and `Tenants.add_member/3` are exercised with the tenant/user GUCs set.
  """
  use BeamChat.DataCase, async: false

  import BeamChat.TestFixtures

  alias BeamChat.Repo
  alias BeamChat.Rooms
  alias BeamChat.Rooms.AccessPolicy
  alias BeamChat.Rooms.RoomMember
  alias BeamChat.Tenants

  # -- helpers ----------------------------------------------------------------

  defp uniq, do: :erlang.unique_integer([:positive]) |> to_string()

  defp add_member!(tenant, user, role) do
    Repo.with_tenant(tenant.id, user.id, fn ->
      {:ok, _} = Tenants.add_member(tenant, user, role)
    end)
  end

  defp create_room!(tenant, user, attrs) do
    {:ok, room} =
      Repo.with_tenant(tenant.id, user.id, fn ->
        Rooms.create_room(Map.merge(%{tenant_id: tenant.id, owner_id: user.id}, attrs))
      end)

    room
  end

  defp grant_member!(tenant, room, user) do
    Repo.with_tenant(tenant.id, user.id, fn ->
      %RoomMember{}
      |> RoomMember.changeset(%{
        room_id: room.id,
        user_id: user.id,
        tenant_id: tenant.id,
        role: "member"
      })
      |> Repo.insert!()
    end)
  end

  # -- role checks ------------------------------------------------------------

  test "admin? is true for an admin member and false for a normal member" do
    {:ok, tenant} = Tenants.create_tenant(%{name: "Role", slug: "role-" <> uniq()})
    admin = user_fixture()
    member = user_fixture()

    add_member!(tenant, admin, "admin")
    add_member!(tenant, member, "member")

    # tenant_members is RLS-protected, so the check runs inside the tenant GUCs.
    assert Repo.with_tenant(tenant.id, admin.id, fn ->
             Tenants.admin?(tenant, admin)
           end)

    refute Repo.with_tenant(tenant.id, member.id, fn ->
             Tenants.admin?(tenant, member)
           end)
  end

  # -- member management -----------------------------------------------------

  describe "set_member_role/4" do
    test "tenant admin can change a member's role and the change is audited" do
      {:ok, tenant} = Tenants.create_tenant(%{name: "Roles", slug: "roles-" <> uniq()})
      admin = user_fixture()
      member = user_fixture()

      add_member!(tenant, admin, "admin")
      add_member!(tenant, member, "member")

      assert {:ok, updated} = Tenants.set_member_role(admin, tenant, member, "admin")
      assert updated.role == "admin"

      [audit] = BeamChat.Audit.list_recent(action: "tenant_member.role_changed", limit: 1)
      assert audit.actor_id == admin.id
      assert audit.tenant_id == tenant.id
      assert audit.target_id == updated.id
      assert audit.metadata["from"] == "member"
      assert audit.metadata["to"] == "admin"
    end

    test "tenant admins may demote themselves (recoverable by a global admin)" do
      {:ok, tenant} = Tenants.create_tenant(%{name: "Step", slug: "step-" <> uniq()})
      admin = user_fixture()
      add_member!(tenant, admin, "admin")

      assert {:ok, updated} = Tenants.set_member_role(admin, tenant, admin, "member")
      assert updated.role == "member"
    end

    test "global admin can manage a tenant they do not belong to" do
      {:ok, tenant} = Tenants.create_tenant(%{name: "Ops", slug: "ops-" <> uniq()})
      global_admin = user_fixture(%{role: "admin"})
      member = user_fixture()
      add_member!(tenant, member, "member")

      assert {:ok, updated} = Tenants.set_member_role(global_admin, tenant, member, "admin")
      assert updated.role == "admin"
    end

    test "plain tenant members are forbidden" do
      {:ok, tenant} = Tenants.create_tenant(%{name: "No", slug: "no-" <> uniq()})
      admin = user_fixture()
      member = user_fixture()
      other = user_fixture()

      add_member!(tenant, admin, "admin")
      add_member!(tenant, member, "member")

      assert {:error, :forbidden} = Tenants.set_member_role(member, tenant, other, "admin")
      assert Tenants.member_role(tenant, member) == "member"
    end

    test "missing membership or tenant returns :not_found" do
      {:ok, tenant} = Tenants.create_tenant(%{name: "Gone", slug: "gone-" <> uniq()})
      admin = user_fixture()
      stranger = user_fixture()
      add_member!(tenant, admin, "admin")

      assert {:error, :not_found} = Tenants.set_member_role(admin, tenant, stranger, "admin")

      assert {:error, :not_found} =
               Tenants.set_member_role(admin, Ecto.UUID.generate(), admin, "admin")
    end

    test "unknown roles are rejected" do
      {:ok, tenant} = Tenants.create_tenant(%{name: "Bad", slug: "bad-" <> uniq()})
      admin = user_fixture()
      add_member!(tenant, admin, "admin")

      assert {:error, :invalid_role} = Tenants.set_member_role(admin, tenant, admin, "superuser")
    end
  end

  describe "remove_member/3" do
    test "tenant admin can remove a member and the removal is audited" do
      {:ok, tenant} = Tenants.create_tenant(%{name: "Rem", slug: "rem-" <> uniq()})
      admin = user_fixture()
      member = user_fixture()

      add_member!(tenant, admin, "admin")
      add_member!(tenant, member, "member")

      assert {:ok, removed} = Tenants.remove_member(admin, tenant, member)
      assert removed.user_id == member.id
      assert Tenants.member_role(tenant, member) == nil

      [audit] = BeamChat.Audit.list_recent(action: "tenant_member.removed", limit: 1)
      assert audit.actor_id == admin.id
      assert audit.tenant_id == tenant.id
      assert audit.metadata["user_id"] == member.id
    end

    test "plain tenant members cannot remove others" do
      {:ok, tenant} = Tenants.create_tenant(%{name: "Lock", slug: "lock-" <> uniq()})
      admin = user_fixture()
      member = user_fixture()
      other = user_fixture()

      add_member!(tenant, admin, "admin")
      add_member!(tenant, member, "member")
      add_member!(tenant, other, "member")

      assert {:error, :forbidden} = Tenants.remove_member(member, tenant, other)
      assert Tenants.member_role(tenant, other) == "member"
    end
  end

  describe "list_members/1" do
    test "returns members with user fields ordered by username" do
      {:ok, tenant} = Tenants.create_tenant(%{name: "List", slug: "list-" <> uniq()})
      admin = user_fixture(%{username: "zeta_" <> uniq()})
      member = user_fixture(%{username: "alpha_" <> uniq()})

      add_member!(tenant, admin, "admin")
      add_member!(tenant, member, "member")

      members = Tenants.list_members(tenant)
      assert [_row_one, _row_two] = members

      usernames = Enum.map(members, & &1.username)
      assert usernames == Enum.sort(usernames)

      assert Enum.any?(members, &(&1.role == "admin" and &1.username == admin.username))
      assert Enum.any?(members, &(&1.role == "member" and &1.username == member.username))
    end
  end

  # -- role-based visibility --------------------------------------------------

  test "list_visible_rooms: member sees only granted rooms; admin sees full tree" do
    {:ok, tenant} = Tenants.create_tenant(%{name: "Visible", slug: "visible-" <> uniq()})
    admin = user_fixture()
    member = user_fixture()

    add_member!(tenant, admin, "admin")
    add_member!(tenant, member, "member")

    # Two rooms owned by the admin (admin is a room_member via ownership).
    room_a1 = create_room!(tenant, admin, %{name: "A1", slug: "a1-" <> uniq()})
    room_a2 = create_room!(tenant, admin, %{name: "A2", slug: "a2-" <> uniq()})
    # One room owned by the member.
    room_m1 = create_room!(tenant, member, %{name: "M1", slug: "m1-" <> uniq()})

    # Member is explicitly granted room_a1 only.
    grant_member!(tenant, room_a1, member)

    admin_visible = AccessPolicy.list_visible_rooms(admin, tenant)
    admin_ids = MapSet.new(Enum.map(admin_visible, & &1.id))

    # Admin must see the ENTIRE tenant tree, including the room it does not
    # hold an explicit room_members grant for (room_m1).
    assert MapSet.member?(admin_ids, room_a1.id)
    assert MapSet.member?(admin_ids, room_a2.id)
    assert MapSet.member?(admin_ids, room_m1.id)
    assert MapSet.size(admin_ids) == 3

    member_visible = AccessPolicy.list_visible_rooms(member, tenant)
    member_ids = MapSet.new(Enum.map(member_visible, & &1.id))

    # Member sees only the rooms it holds a grant for (room_a1, plus room_m1 it
    # owns) and must NOT see room_a2.
    assert MapSet.member?(member_ids, room_a1.id)
    assert MapSet.member?(member_ids, room_m1.id)
    refute MapSet.member?(member_ids, room_a2.id)
    assert MapSet.size(member_ids) == 2
  end

  test "list_visible_rooms returns empty for a user with no membership in the tenant" do
    {:ok, tenant} = Tenants.create_tenant(%{name: "Empty", slug: "empty-" <> uniq()})
    admin = user_fixture()
    stranger = user_fixture()

    add_member!(tenant, admin, "admin")
    _room = create_room!(tenant, admin, %{name: "Only", slug: "only-" <> uniq()})

    assert AccessPolicy.list_visible_rooms(stranger, tenant) == []
  end
end
