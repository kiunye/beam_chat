defmodule BeamChatWeb.Webhooks.PaystackWebhookController do
  @moduledoc """
  Receives Paystack events at `POST /webhooks/paystack`. The HMAC-SHA512
  signature header is verified against the admin-managed Paystack
  credentials; `charge.success` events flow into the provider's confirm
  callback, which matches the reference against the pending wallet
  transaction it claims to complete and credits exactly once (PRD §2.7).
  """

  use BeamChatWeb, :controller

  alias BeamChat.Payments
  alias BeamChat.Payments.PaystackClient

  def create(conn, _params) do
    raw = conn.private[:raw_body] || ""

    sig =
      conn
      |> get_req_header("x-paystack-signature")
      |> List.first()

    credentials = Payments.fetch_credentials("paystack")

    if PaystackClient.valid_signature?(credentials, raw, sig) do
      dispatch(conn, raw)
    else
      send_resp(conn, 401, "invalid signature")
    end
  end

  defp dispatch(conn, raw) do
    case Jason.decode(raw) do
      {:ok, %{"event" => "charge.success", "data" => data}} when is_map(data) ->
        _ = Payments.confirm_topup("paystack", %{"data" => data})
        send_resp(conn, 200, "ok")

      {:ok, _} ->
        send_resp(conn, 200, "ignored")

      {:error, _} ->
        send_resp(conn, 400, "bad json")
    end
  end
end
