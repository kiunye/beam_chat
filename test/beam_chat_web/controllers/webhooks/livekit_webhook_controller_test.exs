defmodule BeamChatWeb.Webhooks.LivekitWebhookControllerTest do
  @moduledoc """
  LiveKit webhook intake: JWT + SHA256 authenticity (delegated to
  `Livekit.WebhookReceiver`), and the `ingress_*` → station status mirror.
  """

  use BeamChatWeb.ConnCase, async: true

  import BeamChat.TestFixtures

  alias BeamChat.Repo
  alias BeamChat.Streaming
  alias BeamChat.Tenants

  defp uniq, do: :erlang.unique_integer([:positive]) |> to_string()

  defp active_station do
    tenant = tenant_fixture()

    radio_station_fixture(tenant, %{
      is_active: true,
      ingress_id: "ing_wh_" <> uniq(),
      status: "starting"
    })
  end

  defp signed_webhook(conn, path, body) do
    raw = Jason.encode!(body)

    sha = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    now = System.system_time(:second)

    signer = Joken.Signer.create("HS256", "secret")

    {:ok, jwt, _claims} =
      Joken.encode_and_sign(
        %{"iss" => "devkey", "sha256" => sha, "nbf" => now, "exp" => now + 60},
        signer
      )

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> jwt)
    |> post(path, raw)
  end

  defp status_of(station) do
    Streaming.get_station(station.tenant_id, station.tenant_id, station.id).status
  end

  describe "POST /webhooks/livekit" do
    test "a valid ingress_started webhook moves the station to live", %{conn: conn} do
      station = active_station()

      conn =
        signed_webhook(conn, ~p"/webhooks/livekit", %{
          "event" => "ingress_started",
          "ingressInfo" => %{"ingressId" => station.ingress_id, "state" => "ENDPOINT_PUBLISHING"}
        })

      assert response(conn, 200)
      assert status_of(station) == "live"
    end

    test "an invalid signature is rejected", %{conn: conn} do
      active_station()

      raw = Jason.encode!(%{"event" => "ingress_started", "ingressInfo" => %{"ingressId" => "x"}})

      signer = Joken.Signer.create("HS256", "wrong-secret")
      {:ok, jwt, _} = Joken.encode_and_sign(%{"iss" => "devkey", "sha256" => "deadbeef"}, signer)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> jwt)
        |> post(~p"/webhooks/livekit", raw)

      assert response(conn, 400)
    end

    test "a missing authorization header is rejected", %{conn: conn} do
      raw = Jason.encode!(%{"event" => "ingress_started"})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/webhooks/livekit", raw)

      assert response(conn, 400)
    end

    test "unknown events are acknowledged without side effects", %{conn: conn} do
      station = active_station()

      conn =
        signed_webhook(conn, ~p"/webhooks/livekit", %{
          "event" => "room_started",
          "room" => %{"name" => "radio-elsewhere"}
        })

      assert response(conn, 200)
      assert status_of(station) == "starting"
    end

    test "events for untracked ingress ids are acknowledged", %{conn: conn} do
      conn =
        signed_webhook(conn, ~p"/webhooks/livekit", %{
          "event" => "ingress_ended",
          "ingressInfo" => %{"ingressId" => "ing_not_tracked"}
        })

      assert response(conn, 200)
    end
  end
end
