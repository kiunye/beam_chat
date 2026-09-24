defmodule BeamChatWeb.RadioAdminLiveTest do
  @moduledoc """
  The permission-gated radio management page: route gate, station CRUD
  via events, and the start/stop lifecycle buttons (through the fake
  Ingress client configured in test_helper).
  """

  use BeamChatWeb.ConnCase, async: false

  import BeamChat.TestFixtures
  import Phoenix.LiveViewTest

  alias BeamChat.IngressFake
  alias BeamChat.Streaming

  defp uniq, do: :erlang.unique_integer([:positive]) |> to_string()

  describe "route gate" do
    test "a plain tenant member is redirected away at mount", %{conn: conn} do
      user = registered_user_fixture()
      tenant = tenant_with_member(user, "member")

      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: to}}} =
               live(conn, ~p"/admin/radio?tenant=#{tenant.id}")

      assert to == "/"
    end

    test "an anonymous visitor is redirected to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/admin/radio")
      assert to == "/auth/login"
    end
  end

  describe "station management" do
    test "tenant admin sees stations and creates one via the form", %{conn: conn} do
      admin = registered_user_fixture()
      tenant = tenant_with_member(admin, "admin")
      radio_station_fixture(tenant)

      conn = log_in_user(conn, admin)
      {:ok, view, html} = live(conn, ~p"/admin/radio?tenant=#{tenant.id}")

      assert html =~ "Radio"
      assert has_element?(view, "#toggle-create-button")

      slug = "horn-fm-" <> uniq()

      view
      |> element("#toggle-create-button")
      |> render_click()

      html =
        view
        |> element("#station-form")
        |> render_submit(%{
          "station" => %{
            "name" => "Horn FM",
            "slug" => slug,
            "source_type" => "url",
            "source_url" => "https://example.com/live.m3u8"
          }
        })

      assert html =~ "created."
      assert Streaming.get_station_by_slug(admin, tenant.id, slug).name == "Horn FM"
    end

    test "tenant admin starts and stops a station through the lifecycle buttons", %{conn: conn} do
      admin = registered_user_fixture()
      tenant = tenant_with_member(admin, "admin")
      station = radio_station_fixture(tenant)

      conn = log_in_user(conn, admin)
      {:ok, view, html} = live(conn, ~p"/admin/radio?tenant=#{tenant.id}")

      assert html =~ "offline"
      refute has_element?(view, "#stop-#{station.id}")

      view
      |> element("#start-#{station.id}")
      |> render_click()

      html = render(view)
      assert html =~ "starting"
      assert has_element?(view, "#stop-#{station.id}")

      view
      |> element("#stop-#{station.id}")
      |> render_click()

      html = render(view)
      assert html =~ "offline"
      assert has_element?(view, "#start-#{station.id}")
    end

    test "a provisioning failure surfaces the error and marks the station", %{conn: conn} do
      admin = registered_user_fixture()
      tenant = tenant_with_member(admin, "admin")
      station = radio_station_fixture(tenant)

      # The LiveView runs in its own process, so the failure result rides on
      # the application environment (see BeamChat.IngressFake).
      Application.put_env(:beam_chat, :ingress_fake_create_result, {:error, :livekit_down})
      on_exit(fn -> Application.delete_env(:beam_chat, :ingress_fake_create_result) end)

      conn = log_in_user(conn, admin)
      {:ok, view, _html} = live(conn, ~p"/admin/radio?tenant=#{tenant.id}")

      html =
        view
        |> element("#start-#{station.id}")
        |> render_click()

      assert html =~ ":livekit_down"
      assert html =~ "error"
      assert Streaming.get_station(admin, tenant.id, station.id).status == "error"
    end

    test "tenant admin deletes a station", %{conn: conn} do
      admin = registered_user_fixture()
      tenant = tenant_with_member(admin, "admin")
      station = radio_station_fixture(tenant)

      conn = log_in_user(conn, admin)
      {:ok, view, _html} = live(conn, ~p"/admin/radio?tenant=#{tenant.id}")

      html =
        view
        |> element("#delete-#{station.id}")
        |> render_click()

      assert html =~ "Station deleted."
      assert Streaming.get_station(admin, tenant.id, station.id) == nil
    end

    test "active rtmp stations show their push endpoint", %{conn: conn} do
      admin = registered_user_fixture()
      tenant = tenant_with_member(admin, "admin")

      radio_station_fixture(tenant, %{
        source_type: "rtmp",
        is_active: true,
        status: "live",
        ingress_id: "ing_rtmp",
        metadata: %{"push_url" => "rtmp://ingress/live", "stream_key" => "key-123"}
      })

      conn = log_in_user(conn, admin)
      {:ok, _view, html} = live(conn, ~p"/admin/radio?tenant=#{tenant.id}")

      assert html =~ "rtmp://ingress/live"
      assert html =~ "key-123"
    end
  end
end
