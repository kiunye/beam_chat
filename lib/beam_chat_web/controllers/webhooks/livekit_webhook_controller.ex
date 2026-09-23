defmodule BeamChatWeb.Webhooks.LivekitWebhookController do
  @moduledoc """
  Receives LiveKit server webhooks and mirrors Ingress lifecycle events
  into radio station status.

  Authenticity: LiveKit signs each webhook with a JWT (`Authorization:
  Bearer <token>`) whose `sha256` claim pins the raw request body —
  verified by `Livekit.WebhookReceiver.receive/2` against the configured
  API key/secret (`config :livekit, :webhook`).

  Unknown events are acknowledged with 200 so LiveKit does not retry
  them; `ingress_*` events for ingress ids we do not track (e.g. created
  out-of-band) are acknowledged and ignored.
  """

  use BeamChatWeb, :controller

  require Logger

  alias BeamChat.Streaming

  @ingress_events ~w(ingress_started ingress_ended ingress_failed)

  def create(conn, _params) do
    raw = conn.private[:raw_body] || ""
    auth = conn |> get_req_header("authorization") |> List.first() |> bearer_token()

    with {:ok, event} <- Livekit.WebhookReceiver.receive(raw, auth),
         {:ok, body} <- Jason.decode(raw),
         :ok <- handle_event(event.event, extract_ingress_id(body, event.event)) do
      send_resp(conn, 200, "ok")
    else
      {:error, reason} ->
        Logger.warning("livekit webhook rejected: #{inspect(reason)}")
        send_resp(conn, 400, "invalid")
    end
  end

  # `Livekit.AccessToken.verify/3` expects the bare token, but LiveKit sends
  # `Authorization: Bearer <token>` — normalize here so the SDK sees a JWT.
  defp bearer_token("Bearer " <> token), do: token
  defp bearer_token(token) when is_binary(token), do: token
  defp bearer_token(nil), do: ""

  # `Livekit.WebhookReceiver` decodes room/participant/track but not the
  # `ingressInfo` payload, so the (already authenticity-verified) raw body
  # is decoded once more for the ingress fields.
  defp extract_ingress_id(body, event) when event in @ingress_events do
    get_in(body, ["ingressInfo", "ingressId"])
  end

  defp extract_ingress_id(_body, _event), do: nil

  defp handle_event(event, nil) when event in @ingress_events do
    Logger.warning("livekit #{event} webhook without ingressId acknowledged and ignored")
    :ok
  end

  defp handle_event(event, ingress_id) when event in @ingress_events do
    case Streaming.apply_ingress_event(ingress_id, event) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp handle_event(_event, _ingress_id), do: :ok
end
