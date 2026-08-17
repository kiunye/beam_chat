defmodule BeamChat.Rooms.RecursionTest do
  @moduledoc """
  Recursive room-tree helper tests and cycle-prevention tests for the
  hierarchical, multi-tenant room redesign (CATEGORY_REDESIGN.md §4.4).

  The GUC leak described in `BeamChat.RlsTest` does not affect these tests:
  every read/write runs inside `Repo.with_tenant/3`, which (re)sets the GUC
  for its own tenant, overriding any leaked value.
  """
  use BeamChat.DataCase, async: false

  import BeamChat.TestFixtures

  alias BeamChat.Repo
  alias BeamChat.Rooms
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

  defp build_tree(tenant, user) do
    root = create_room!(tenant, user, %{name: "Root", slug: "root-" <> uniq()})

    child1 =
      create_room!(tenant, user, %{
        name: "Child1",
        slug: "child1-" <> uniq(),
        parent_id: root.id
      })

    child2 =
      create_room!(tenant, user, %{
        name: "Child2",
        slug: "child2-" <> uniq(),
        parent_id: root.id
      })

    grandchild =
      create_room!(tenant, user, %{
        name: "Grandchild",
        slug: "grandchild-" <> uniq(),
        parent_id: child1.id
      })

    {root, child1, child2, grandchild}
  end

  # -- passing: simple helpers ------------------------------------------------

  test "list_child_rooms returns the direct children of a parent" do
    {:ok, tenant} = Tenants.create_tenant(%{name: "Tree", slug: "tree-" <> uniq()})
    user = user_fixture()
    add_member!(tenant, user, "admin")

    {root, child1, child2, _grandchild} = build_tree(tenant, user)

    Repo.with_tenant(tenant.id, user.id, fn ->
      children = Rooms.list_child_rooms(root.id)
      assert MapSet.new(Enum.map(children, & &1.id)) == MapSet.new([child1.id, child2.id])
    end)
  end

  test "room_path returns the breadcrumb root-first" do
    {:ok, tenant} = Tenants.create_tenant(%{name: "Tree2", slug: "tree2-" <> uniq()})
    user = user_fixture()
    add_member!(tenant, user, "admin")

    {_root, _child1, _child2, grandchild} = build_tree(tenant, user)

    Repo.with_tenant(tenant.id, user.id, fn ->
      path = Rooms.room_path(grandchild.id)
      assert Enum.map(path, & &1.name) == ["Root", "Child1", "Grandchild"]
    end)
  end

  test "move_room rejects re-parenting to a different tenant (short-circuits before CTE)" do
    {:ok, tenant_a} = Tenants.create_tenant(%{name: "TenantA", slug: "tA-" <> uniq()})
    {:ok, tenant_b} = Tenants.create_tenant(%{name: "TenantB", slug: "tB-" <> uniq()})
    user = user_fixture()
    add_member!(tenant_a, user, "admin")
    add_member!(tenant_b, user, "admin")

    room_a = create_room!(tenant_a, user, %{name: "RA", slug: "ra-" <> uniq()})
    room_b = create_room!(tenant_b, user, %{name: "RB", slug: "rb-" <> uniq()})

    assert {:error, :cycle} =
             Repo.with_tenant(tenant_a.id, user.id, fn ->
               Rooms.move_room(room_a, room_b.id)
             end)
  end

  # -- failing: recursive CTE helpers (Bug B) ---------------------------------
  # These exercise the recursive-CTE fragments in `BeamChat.Rooms`. They fail
  # because the `^room_id` bind in the `fragment(...)` is sent as a 36-char UUID
  # *string* without a `::uuid` cast, so Postgrex cannot encode it for the
  # `uuid` column. See the final report.

  @tag :known_bug
  test "room_descendants returns the full subtree (root + all descendants)" do
    {:ok, tenant} = Tenants.create_tenant(%{name: "Tree3", slug: "tree3-" <> uniq()})
    user = user_fixture()
    add_member!(tenant, user, "admin")

    {root, child1, child2, grandchild} = build_tree(tenant, user)

    Repo.with_tenant(tenant.id, user.id, fn ->
      descendants = Rooms.room_descendants(root.id)
      assert length(descendants) == 4

      assert MapSet.new(Enum.map(descendants, & &1.id)) ==
               MapSet.new([root.id, child1.id, child2.id, grandchild.id])
    end)
  end

  @tag :known_bug
  test "room_ancestors returns ancestors excluding the node itself" do
    {:ok, tenant} = Tenants.create_tenant(%{name: "Tree4", slug: "tree4-" <> uniq()})
    user = user_fixture()
    add_member!(tenant, user, "admin")

    {root, child1, _child2, grandchild} = build_tree(tenant, user)

    Repo.with_tenant(tenant.id, user.id, fn ->
      ancestors = Rooms.room_ancestors(grandchild.id)
      assert length(ancestors) == 2

      assert MapSet.new(Enum.map(ancestors, & &1.id)) ==
               MapSet.new([child1.id, root.id])
    end)
  end

  @tag :known_bug
  test "move_room prevents cycles (re-parent under own descendant)" do
    {:ok, tenant} = Tenants.create_tenant(%{name: "Move", slug: "move-" <> uniq()})
    user = user_fixture()
    add_member!(tenant, user, "admin")

    {_root, child1, _child2, grandchild} = build_tree(tenant, user)

    assert {:error, :cycle} =
             Repo.with_tenant(tenant.id, user.id, fn ->
               Rooms.move_room(child1, grandchild.id)
             end)
  end
end
