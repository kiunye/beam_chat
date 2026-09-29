defmodule BeamChatWeb.Webhooks.MpesaWebhookController do
  @moduledoc """
  Receives the M-Pesa STK callback at `POST /webhooks/mpesa/:secret`
  (the secret is enforced upstream by `BeamChatWeb.Plugs.MpesaWebhookAuth`).

  The body flows into the Daraja provider's confirm callback, which
  resolves the `CheckoutRequestID` against the pending wallet
  transaction, credits on ResultCode 0 (including the late-completion
  branch when the expiry job beat the callback), and finalizes failures.
  """

  use BeamChatWeb, :controller

  alias BeamChat.Payments

  def create(conn, _params) do
    raw = conn.private[:raw_body] || ""

    case Jason.decode(raw) do
      {:ok, body} when is_map(body) ->
        _ = Payments.confirm_topup("mpesa", body)
        send_resp(conn, 200, "ok")

      {:ok, _} ->
        send_resp(conn, 200, "ignored")

      {:error, _} ->
        send_resp(conn, 400, "bad json")
    end
  end
end
