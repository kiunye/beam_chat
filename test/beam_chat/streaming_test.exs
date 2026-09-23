defmodule BeamChat.StreamingTest do
  @moduledoc """
  Radio station administration (`BeamChat.Streaming`): permission-gated
  CRUD, RLS tenant isolation, validation, and audit wiring.
  """

  use BeamChat.DataCase, async: false

  import BeamChat.TestFixtures

  alias BeamChat.Repo
  alias BeamChat.Streaming
  alias BeamChat.Tenants

  defp uniq, do: :erlang.unique_integer([:positive]) |> to_string()

  defp tenant_with(user, role) do
    {:ok, tenant} = Tenants.create_tenant(%{name: "Radio " <> uniq(), slug: "radio-" <> uniq()})

    Repo.with_tenant(tenant.id, user.id, fn ->
      {:ok, _} = Tenants.add_member(tenant, user, role)
    end)

    tenant
  end

  defp station_attrs do
    %{
      "name" => "Horn FM",
      "slug" => "horn-fm-" <> uniq(),
      "source_type" => "url",
      "source_url" => "https://example.com/live.m3u8"
    }
  end

  describe "create_station/3" do
    test "tenant admin can create a station and the creation is audited" do
      admin = user_fixture()
      tenant = tenant_with(admin, "admin")

      assert {:ok, station} = Streaming.create_station(admin, tenant, station_attrs())
      assert station.tenant_id == tenant.id
      assert station.is_active == false
      assert station.status == "offline"

      [audit] = BeamChat.Audit.list_recent(action: "radio_station.created", limit: 1)
      assert audit.actor_id == admin.id
      assert audit.target_id == station.id
      assert audit.tenant_id == tenant.id
    end

    test "a plain tenant member is forbidden" do
      member = user_fixture()
      tenant = tenant_with(member, "member")

      assert {:error, :forbidden} = Streaming.create_station(member, tenant, station_attrs())
    end

    test "a global admin can create a station in a tenant they do not belong to" do
      global_admin = user_fixture(%{role: "admin"})

      {:ok, tenant} = Tenants.create_tenant(%{name: "Out " <> uniq(), slug: "out-" <> uniq()})

      assert {:ok, station} = Streaming.create_station(global_admin, tenant, station_attrs())
      assert station.tenant_id == tenant.id
    end

    test "an unknown tenant returns :not_found" do
      admin = user_fixture(%{role: "admin"})

      assert {:error, :not_found} =
               Streaming.create_station(admin, Ecto.UUID.generate(), station_attrs())
    end

    test "rejects url sources without a source URL" do
      admin = user_fixture()
      tenant = tenant_with(admin, "admin")

      assert {:error, changeset} =
               Streaming.create_station(admin, tenant, %{
                 "name" => "No URL",
                 "slug" => "no-url-" <> uniq(),
                 "source_type" => "url"
               })

      assert changeset.errors[:source_url] != nil
    end

    test "rejects unknown source types and malformed slugs" do
      admin = user_fixture()
      tenant = tenant_with(admin, "admin")

      assert {:error, changeset} =
               Streaming.create_station(admin, tenant, %{
                 station_attrs()
                 | "source_type" => "carrier_pigeon"
               })

      assert changeset.errors[:source_type] != nil

      assert {:error, slug_changeset} =
               Streaming.create_station(admin, tenant, %{
                 station_attrs()
                 | "slug" => "Not A Slug!"
               })

      assert slug_changeset.errors[:slug] != nil
    end
  end

  describe "list_stations/2 and gets (RLS isolation)" do
    test "stations are only visible inside their tenant" do
      admin_a = user_fixture()
      tenant_a = tenant_with(admin_a, "admin")
      admin_b = user_fixture()
      tenant_b = tenant_with(admin_b, "admin")

      station_a = radio_station_fixture(tenant_a)
      radio_station_fixture(tenant_b)

      visible = Streaming.list_stations(admin_a, tenant_a)
      assert Enum.map(visible, & &1.id) == [station_a.id]

      assert Streaming.get_station(admin_a, tenant_a.id, station_a.id).id == station_a.id

      assert Streaming.get_station_by_slug(admin_a, tenant_a.id, station_a.slug).id ==
               station_a.id

      # Another tenant's station is invisible even by id.
      assert Streaming.get_station(admin_a, tenant_a.id, Ecto.UUID.generate()) == nil
    end
  end

  describe "update_station/3 and delete_station/2" do
    test "tenant admin can update and delete, both audited" do
      admin = user_fixture()
      tenant = tenant_with(admin, "admin")
      station = radio_station_fixture(tenant)

      assert {:ok, updated} =
               Streaming.update_station(admin, station, %{
                 "name" => "Horn FM 2",
                 "source_url" => "https://example.com/live2.m3u8"
               })

      assert updated.name == "Horn FM 2"

      assert {:ok, deleted} = Streaming.delete_station(admin, updated)
      assert deleted.id == station.id

      assert [_, _] = [
               BeamChat.Audit.list_recent(action: "radio_station.updated", limit: 1) |> hd(),
               BeamChat.Audit.list_recent(action: "radio_station.deleted", limit: 1) |> hd()
             ]

      assert Streaming.get_station(admin, tenant.id, station.id) == nil
    end

    test "a plain tenant member cannot update or delete" do
      admin = user_fixture()
      tenant = tenant_with(admin, "admin")
      member = user_fixture()

      Repo.with_tenant(tenant.id, member.id, fn ->
        {:ok, _} = Tenants.add_member(tenant, member, "member")
      end)

      station = radio_station_fixture(tenant)

      assert {:error, :forbidden} =
               Streaming.update_station(member, station, %{"name" => "Hacked"})

      assert {:error, :forbidden} = Streaming.delete_station(member, station)
    end
  end

  describe "slug uniqueness" do
    test "duplicate slugs are rejected" do
      admin = user_fixture()
      tenant = tenant_with(admin, "admin")
      attrs = station_attrs()

      assert {:ok, _} = Streaming.create_station(admin, tenant, attrs)
      assert {:error, changeset} = Streaming.create_station(admin, tenant, attrs)

      assert changeset.errors[:slug] != nil
    end
  end
end
