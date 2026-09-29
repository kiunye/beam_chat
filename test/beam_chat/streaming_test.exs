defmodule BeamChat.StreamingTest do
  use BeamChat.DataCase, async: false

  alias BeamChat.Repo
  alias BeamChat.Streaming
  alias BeamChat.Streaming.RadioStation

  setup do
    original = Application.get_env(:beam_chat, :ingress_client)
    Application.put_env(:beam_chat, :ingress_client, BeamChat.IngressFake)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:beam_chat, :ingress_client)
      else
        Application.put_env(:beam_chat, :ingress_client, original)
      end

      Process.delete(:ingress_fake_creates)
      Process.delete(:ingress_fake_deletes)
    end)

    :ok
  end

  describe "governance" do
    test "only platform admins can create stations" do
      member = user_fixture()

      assert {:error, :forbidden} =
               Streaming.create_station(member, %{
                 "name" => "Horn FM",
                 "slug" => "horn-fm",
                 "source_type" => "url",
                 "source_url" => "https://x.example/str.m3u8"
               })

      admin = admin_fixture()

      assert {:ok, station} =
               Streaming.create_station(admin, %{
                 "name" => "Horn FM",
                 "slug" => "horn-fm",
                 "source_type" => "url",
                 "source_url" => "https://x.example/str.m3u8"
               })

      assert station.status == "offline"
      assert station.is_active == false
    end

    test "only platform admins can update stations" do
      admin = admin_fixture()
      station = station_fixture(name: "Beacon Live")

      member = user_fixture()

      assert {:error, :forbidden} =
               Streaming.update_station(member, station, %{"name" => "Sabotage"})

      assert {:ok, updated} = Streaming.update_station(admin, station, %{"name" => "Renamed"})
      assert updated.name == "Renamed"
      assert updated.slug == station.slug
    end

    test "only platform admins can delete stations" do
      _admin = admin_fixture()
      station = station_fixture()
      member = user_fixture()
      assert {:error, :forbidden} = Streaming.delete_station(member, station)

      admin2 = admin_fixture()
      assert {:ok, _} = Streaming.delete_station(admin2, station)
      assert Repo.get(RadioStation, station.id) == nil
    end
  end

  describe "reads" do
    test "list_active_stations only returns active ones, alphabetical" do
      admin = admin_fixture()

      Process.put(
        :ingress_fake_create_result,
        {:ok, %{ingress_id: "ing_1", url: "rtmp://x", stream_key: "k1"}}
      )

      station_on =
        create_started_station(admin, %{
          "name" => "Amber",
          "slug" => "amber",
          "source_type" => "url",
          "source_url" => "https://amber.example/s.m3u8"
        })

      Process.put(
        :ingress_fake_create_result,
        {:ok, %{ingress_id: "ing_2", url: "rtmp://x", stream_key: "k2"}}
      )

      station_off =
        create_never_started_station(admin, %{
          "name" => "Zebra",
          "slug" => "zebra",
          "source_type" => "url",
          "source_url" => "https://z.example/s.m3u8"
        })

      assert [station_on] == Streaming.list_active_stations()
      assert Enum.find(Streaming.list_stations(), &(&1.id == station_off.id))
      assert Enum.find(Streaming.list_stations(), &(&1.id == station_on.id))
    end
  end

  describe "in Cloudflare lifecycle (IngressClient fake)" do
    test "start_station provisions ingress and marks starting" do
      admin = admin_fixture()
      station = station_fixture()

      Process.put(
        :ingress_fake_create_result,
        {:ok, %{ingress_id: "ing_ABC", url: "rtmp://pci.example", stream_key: "sk-x"}}
      )

      assert {:ok, station} = Streaming.start_station(admin, station)
      assert station.is_active
      assert station.status == "starting"
      assert station.ingress_id == "ing_ABC"
      assert station.metadata["push_url"] == "rtmp://pci.example"
      assert station.metadata["stream_key"] == "sk-x"

      assert %{room_name: "radio-" <> slug} = BeamChat.IngressFake.last_create()
      assert slug == station.slug
    end

    test "start_station on already-active station errors without re-invoking ingress" do
      admin = admin_fixture()
      station = station_fixture()

      Process.put(
        :ingress_fake_create_result,
        {:ok, %{ingress_id: "ing_once", url: "rtmp://p", stream_key: "k"}}
      )

      {:ok, station} = Streaming.start_station(admin, station)

      Process.put(
        :ingress_fake_create_result,
        {:ok, %{ingress_id: "ing_distinct", url: "rtmp://q", stream_key: "x"}}
      )

      assert {:error, :already_active} = Streaming.start_station(admin, station)
    end

    test "start_station failure marks the station status error" do
      admin = admin_fixture()
      station = station_fixture()
      Process.put(:ingress_fake_create_result, {:error, :mpesa_oauth_or_something})

      assert {:error, :mpesa_oauth_or_something} = Streaming.start_station(admin, station)
      assert %{status: "error"} = Repo.get!(RadioStation, station.id)
    end

    test "stop_station degrades local state only after the remote delete succeeds" do
      admin = admin_fixture()
      station = station_fixture()

      Process.put(
        :ingress_fake_create_result,
        {:ok, %{ingress_id: "ing_del", url: "rtmp://p", stream_key: "k"}}
      )

      {:ok, station} = Streaming.start_station(admin, station)

      assert {:ok, stopped} = Streaming.stop_station(admin, station)
      assert stopped.is_active == false
      assert stopped.status == "offline"
      assert stopped.ingress_id == nil
      assert stopped.metadata == %{}
      assert BeamChat.IngressFake.last_delete() == "ing_del"
    end

    test "stop_station on never-started station is a no-op" do
      admin = admin_fixture()
      station = station_fixture()

      assert {:ok, same} = Streaming.stop_station(admin, station)
      assert same.is_active == false
      assert Process.get(:ingress_fake_deletes, []) == []
    end

    test "apply_ingress_event mirrors lifecycle events onto the station" do
      admin = admin_fixture()
      station = station_fixture()

      Process.put(
        :ingress_fake_create_result,
        {:ok, %{ingress_id: "ing_ev", url: "rtmp://p", stream_key: "k"}}
      )

      {:ok, station_started} = Streaming.start_station(admin, station)

      :ok = Streaming.apply_ingress_event("ing_ev", "ingress_started")
      assert Repo.get!(RadioStation, station_started.id).status == "live"

      :ok = Streaming.apply_ingress_event("ing_ev", "ingress_ended")
      assert Repo.get!(RadioStation, station_started.id).status == "offline"

      :ok = Streaming.apply_ingress_event("ing_ev", "ingress_failed")
      assert Repo.get!(RadioStation, station_started.id).status == "error"
    end

    test "apply_ingress_event ignores unknown ids" do
      assert {:error, :not_found} =
               Streaming.apply_ingress_event("ing_missing", "ingress_started")
    end

    test "apply_ingress_event ignores events for a stopped station" do
      admin = admin_fixture()
      station = station_fixture()

      Process.put(
        :ingress_fake_create_result,
        {:ok, %{ingress_id: "ing_stale", url: "rtmp://p", stream_key: "k"}}
      )

      {:ok, station_started} = Streaming.start_station(admin, station)

      # Stopping clears ingress_id; a late event can't find the row.
      {:ok, _} = Streaming.stop_station(admin, station_started)

      {:error, :not_found} = Streaming.apply_ingress_event("ing_stale", "ingress_started")
      assert Repo.get!(RadioStation, station_started.id).status == "offline"
    end
  end

  defp create_started_station(admin, attrs) do
    {:ok, station} = Streaming.create_station(admin, attrs)
    {:ok, station} = Streaming.start_station(admin, station)
    station
  end

  defp create_never_started_station(admin, attrs) do
    {:ok, station} = Streaming.create_station(admin, attrs)
    station
  end
end
