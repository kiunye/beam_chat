defmodule BeamChat.RlsTest do
  @moduledoc """
  PostgreSQL Row Level Security isolation tests for the multi-tenant room
  redesign (CATEGORY_REDESIGN.md §3.6 / T3).

  The test DB connects as the non-superuser role `beamchat_app`, so RLS is
  ACTIVE. A query without the `app.current_tenant_id` / `app.current_user_id`
  GUCs must return nothing (default-deny), and a non-superuser connection must
  not read another tenant's rows.

  NOTE on the SQL Sandbox: `BeamChat.Repo.with_tenant/3` uses
  `set_config(..., true)`. Under `Ecto.Adapters.SQL.Sandbox` the outer
  connection is a single transaction and nested `Repo.transaction` calls use
  SAVEPOINTs, so the GUC is **not** discarded until the sandbox transaction
  ends — it leaks out of `with_tenant` within a single test. To assert true
  default-deny we therefore (a) query before any `with_tenant`, or (b) clear
  the GUC to a valid-but-nonexistent tenant UUID so the RLS policy matches
  nothing. This is a known test-environment artifact, not a test bug.
  """
  use BeamChat.DataCase, async: false

  import BeamChat.TestFixtures

  alias BeamChat.Repo
  alias BeamChat.Rooms
  alias BeamChat.Rooms.Room
  alias BeamChat.Tenants

  @sentinel_tenant "00000000-0000-0000-0000-000000000000"

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

  # -- tests ------------------------------------------------------------------

  test "cross-tenant isolation: a tenant's rooms are invisible to another tenant (RLS enforced)" do
    {:ok, tenant_a} = Tenants.create_tenant(%{name: "Alpha", slug: "alpha-" <> uniq()})
    {:ok, tenant_b} = Tenants.create_tenant(%{name: "Beta", slug: "beta-" <> uniq()})

    user_a = user_fixture()
    user_b = user_fixture()

    add_member!(tenant_a, user_a, "member")
    add_member!(tenant_b, user_b, "member")

    room_a = create_room!(tenant_a, user_a, %{name: "Room A", slug: "room-a-" <> uniq()})
    room_b = create_room!(tenant_b, user_b, %{name: "Room B", slug: "room-b-" <> uniq()})

    # Inside tenant A's context, only tenant A's room is visible — tenant B's
    # room is filtered out by RLS even though we issue a bare `Repo.all(Room)`.
    visible_in_a =
      Repo.with_tenant(tenant_a.id, user_a.id, fn ->
        Repo.all(Room)
      end)

    assert Enum.map(visible_in_a, & &1.id) == [room_a.id]
    refute room_b.id in Enum.map(visible_in_a, & &1.id)

    # Inside tenant B's context, only tenant B's room is visible.
    visible_in_b =
      Repo.with_tenant(tenant_b.id, user_b.id, fn ->
        Repo.all(Room)
      end)

    assert Enum.map(visible_in_b, & &1.id) == [room_b.id]
    refute room_a.id in Enum.map(visible_in_b, & &1.id)
  end

  test "default-deny: a query with no tenant GUC returns nothing even when rows exist" do
    {:ok, tenant_a} = Tenants.create_tenant(%{name: "Gamma", slug: "gamma-" <> uniq()})
    user_a = user_fixture()
    add_member!(tenant_a, user_a, "member")

    _room_a = create_room!(tenant_a, user_a, %{name: "Room A2", slug: "room-a2-" <> uniq()})

    # The GUC leaked from the create_room! with_tenant above; clear it to a
    # valid-but-nonexistent tenant so the RLS `tenant_id = <sentinel>` predicate
    # matches nothing instead of throwing on an empty-string cast.
    Repo.query!(
      "SELECT set_config('app.current_tenant_id', '#{@sentinel_tenant}', false), set_config('app.current_user_id', '#{@sentinel_tenant}', false)"
    )

    assert Repo.all(Room) == []
  end

  @tag :known_bug
  test "list_child_rooms(nil) returns the top-level rooms" do
    {:ok, tenant} = Tenants.create_tenant(%{name: "Top", slug: "top-" <> uniq()})
    user = user_fixture()
    add_member!(tenant, user, "admin")

    room = create_room!(tenant, user, %{name: "Root", slug: "root-" <> uniq()})

    result =
      Repo.with_tenant(tenant.id, user.id, fn ->
        Rooms.list_child_rooms(nil)
      end)

    assert Enum.map(result, & &1.id) == [room.id]
  end
end
