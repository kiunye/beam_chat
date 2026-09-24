defmodule BeamChatWeb.RadioLiveTest do
  @moduledoc """
  The listener-facing radio page: lineup of active stations and the
  subscribe-only token flow (the push events the client hook consumes).
  """

  use BeamChatWeb.ConnCase, async: false

  import BeamChat.TestFixtures
  import Phoenix.LiveViewTest

  alias BeamChat.Video.TokenService

  defp uniq, do: :erlang.unique_integer([:positive]) |> to_string()

  describe "index" do
    test "lists only active stations of the tenant", %{conn: conn} do
      user = registered_user_fixture()
      tenant = tenant_with_member(user, "member")

      live_one =
        radio_station_fixture(tenant, %{name: "Horn FM", is_active: true, status: "live"})

      radio_station_fixture(tenant, %{name: "Dead Air", is_active: false})

      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, ~p"/radio?tenant=#{tenant.id}")

      assert html =~ "Horn FM"
      refute html =~ "Dead Air"
      assert has_element?(view, "#listen-#{live_one.id}")
    end

    test "listening pushes a subscribe-only radio_connect event", %{conn: conn} do
      user = registered_user_fixture()
      tenant = tenant_with_member(user, "member")

      station =
        radio_station_fixture(tenant, %{
          name: "Horn FM",
          slug: "horn-fm-" <> uniq(),
          is_active: true,
          status: "live"
        })

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/radio?tenant=#{tenant.id}")

      view
      |> element("#listen-#{station.id}")
      |> render_click()

      room = "radio-" <> station.slug

      assert_push_event view, "radio_connect", %{
        room: ^room,
        url: _url,
        token: token
      }

      # The issued token is subscribe-only.
      assert {:ok, claims} = TokenService.verify_token(token)
      assert get_in(claims, ["video", "canPublish"]) == false
      assert get_in(claims, ["video", "canSubscribe"]) == true
      assert get_in(claims, ["video", "room"]) == room
    end

    test "stopping pushes a radio_disconnect event for the station", %{conn: conn} do
      user = registered_user_fixture()
      tenant = tenant_with_member(user, "member")

      station =
        radio_station_fixture(tenant, %{
          name: "Horn FM",
          slug: "horn-fm-" <> uniq(),
          is_active: true,
          status: "live"
        })

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/radio?tenant=#{tenant.id}")

      view |> element("#listen-#{station.id}") |> render_click()
      room = "radio-" <> station.slug
      assert_push_event view, "radio_connect", %{room: ^room}

      view |> element("#stop-#{station.id}") |> render_click()
      assert_push_event view, "radio_disconnect", %{room: ^room}
    end

    test "switching stations disconnects the previous one first", %{conn: conn} do
      user = registered_user_fixture()
      tenant = tenant_with_member(user, "member")

      one =
        radio_station_fixture(tenant, %{
          name: "One FM",
          slug: "one-fm-" <> uniq(),
          is_active: true,
          status: "live"
        })

      two =
        radio_station_fixture(tenant, %{
          name: "Two FM",
          slug: "two-fm-" <> uniq(),
          is_active: true,
          status: "live"
        })

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/radio?tenant=#{tenant.id}")

      view |> element("#listen-#{one.id}") |> render_click()
      room_one = "radio-" <> one.slug
      assert_push_event view, "radio_connect", %{room: ^room_one}

      view |> element("#listen-#{two.id}") |> render_click()
      room_two = "radio-" <> two.slug

      assert_push_event view, "radio_disconnect", %{room: ^room_one}
      assert_push_event view, "radio_connect", %{room: ^room_two}
    end

    test "an anonymous visitor is redirected to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/radio")
      assert to == "/auth/login"
    end
  end
end
