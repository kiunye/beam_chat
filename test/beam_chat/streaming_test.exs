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

  describe "station stream lifecycle" do
    alias BeamChat.IngressFake

    test "start_station provisions an Ingress and marks the station starting" do
      admin = user_fixture()
      tenant = tenant_with(admin, "admin")
      station = radio_station_fixture(tenant)

      assert {:ok, started} = Streaming.start_station(admin, station)
      assert started.is_active == true
      assert started.status == "starting"
      assert started.ingress_id == "ing_fake"
      assert started.metadata["push_url"] == "rtmp://fake/push"
      assert started.metadata["stream_key"] == "fake-key"

      create = IngressFake.last_create()
      assert create.input_type == :URL_INPUT
      assert create.room_name == "radio-" <> station.slug
      assert create.participant_identity == "radio-" <> station.slug
      assert create.url == station.source_url

      [audit] = BeamChat.Audit.list_recent(action: "radio_station.started", limit: 1)
      assert audit.actor_id == admin.id
      assert audit.target_id == station.id
    end

    test "starting an already-active station is rejected" do
      admin = user_fixture()
      tenant = tenant_with(admin, "admin")
      station = radio_station_fixture(tenant)

      {:ok, started} = Streaming.start_station(admin, station)
      assert {:error, :already_active} = Streaming.start_station(admin, started)
    end

    test "a provisioning failure marks the station error and is audited" do
      admin = user_fixture()
      tenant = tenant_with(admin, "admin")
      station = radio_station_fixture(tenant)

      Process.put(:ingress_fake_create_result, {:error, :livekit_down})

      assert {:error, :livekit_down} = Streaming.start_station(admin, station)

      failed = Streaming.get_station(admin, tenant.id, station.id)
      assert failed.status == "error"
      assert failed.is_active == false

      [audit] = BeamChat.Audit.list_recent(action: "radio_station.start_failed", limit: 1)
      assert audit.target_id == station.id
      assert audit.metadata["reason"] =~ "livekit_down"
    end

    test "a plain tenant member cannot start or stop a station" do
      admin = user_fixture()
      tenant = tenant_with(admin, "admin")
      member = user_fixture()

      Repo.with_tenant(tenant.id, member.id, fn ->
        {:ok, _} = Tenants.add_member(tenant, member, "member")
      end)

      station = radio_station_fixture(tenant)

      assert {:error, :forbidden} = Streaming.start_station(member, station)
      assert {:error, :forbidden} = Streaming.stop_station(member, station)
    end

    test "stop_station tears down the Ingress and returns the station to offline" do
      admin = user_fixture()
      tenant = tenant_with(admin, "admin")
      station = radio_station_fixture(tenant)

      {:ok, started} = Streaming.start_station(admin, station)

      assert {:ok, stopped} = Streaming.stop_station(admin, started)
      assert stopped.is_active == false
      assert stopped.status == "offline"
      assert stopped.ingress_id == nil
      assert stopped.metadata == %{}

      assert IngressFake.last_delete() == "ing_fake"

      [audit] = BeamChat.Audit.list_recent(action: "radio_station.stopped", limit: 1)
      assert audit.actor_id == admin.id
    end

    test "a failed remote delete leaves the station untouched" do
      admin = user_fixture()
      tenant = tenant_with(admin, "admin")
      station = radio_station_fixture(tenant)
      {:ok, started} = Streaming.start_station(admin, station)

      Process.put(:ingress_fake_delete_result, {:error, :livekit_down})

      assert {:error, {:ingress_delete_failed, :livekit_down}} =
               Streaming.stop_station(admin, started)

      unchanged = Streaming.get_station(admin, tenant.id, station.id)
      assert unchanged.is_active == true
      assert unchanged.status == "starting"
    end

    test "apply_ingress_event mirrors webhook state transitions" do
      admin = user_fixture()
      tenant = tenant_with(admin, "admin")

      station =
        radio_station_fixture(tenant, %{is_active: true, ingress_id: "ing_x", status: "starting"})

      assert :ok = Streaming.apply_ingress_event("ing_x", "ingress_started")
      assert Streaming.get_station(admin, tenant.id, station.id).status == "live"

      assert :ok = Streaming.apply_ingress_event("ing_x", "ingress_failed")
      assert Streaming.get_station(admin, tenant.id, station.id).status == "error"

      # Idempotent repeats and unknown events change nothing.
      assert :ok = Streaming.apply_ingress_event("ing_x", "room_started")
      assert Streaming.get_station(admin, tenant.id, station.id).status == "error"

      # An admin-stopped station ignores stale events from its old resource.
      stale =
        radio_station_fixture(tenant, %{
          is_active: false,
          status: "offline",
          ingress_id: "ing_stale"
        })

      assert :ok = Streaming.apply_ingress_event("ing_stale", "ingress_started")
      assert Streaming.get_station(admin, tenant.id, stale.id).status == "offline"

      assert {:error, :not_found} =
               Streaming.apply_ingress_event("ing_unknown", "ingress_started")
    end
  end
end
