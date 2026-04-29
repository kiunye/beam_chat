defmodule BeamChatWeb.Webhooks.PaystackWebhookController do
  use BeamChatWeb, :controller

  alias BeamChat.Payments.PaystackClient
  alias BeamChat.Payments.PaystackUserLookup
  alias BeamChat.Wallet

  def create(conn, _params) do
    raw = conn.private[:raw_body] || ""

    sig =
      conn
      |> get_req_header("x-paystack-signature")
      |> List.first()

    if PaystackClient.valid_signature?(raw, sig) do
      dispatch_paystack_body(conn, raw)
    else
      send_resp(conn, 401, "invalid signature")
    end
  end

  defp dispatch_paystack_body(conn, raw) do
    case Jason.decode(raw) do
      {:ok, %{"event" => "charge.success", "data" => data}} ->
        handle_charge_success(data)
        send_resp(conn, 200, "ok")

      {:ok, _} ->
        send_resp(conn, 200, "ignored")

      {:error, _} ->
        send_resp(conn, 400, "bad json")
    end
  end

  defp handle_charge_success(data) do
    if data["status"] == "success" and is_binary(data["reference"]) do
      amount_major = paystack_amount_to_decimal(data["amount"])
      maybe_credit_user(data, amount_major)
    end
  end

  defp maybe_credit_user(data, amount_major) do
    reference = data["reference"]

    case PaystackUserLookup.user_id_from_charge_data(data) do
      nil -> :ok
      uid -> credit_user(uid, amount_major, reference, data)
    end
  end

  defp credit_user(uid, amount_major, reference, data) do
    _ =
      Wallet.complete_provider_credit(uid, amount_major, "paystack", reference, %{
        "paystack_id" => data["id"],
        "source" => "webhook"
      })

    :ok
  end

  defp paystack_amount_to_decimal(amount) when is_integer(amount) do
    amount |> Decimal.new() |> Decimal.div(Decimal.new(100))
  end

  defp paystack_amount_to_decimal(amount) when is_binary(amount) do
    amount |> String.to_integer() |> paystack_amount_to_decimal()
  end

  defp paystack_amount_to_decimal(%Decimal{} = d), do: d
  defp paystack_amount_to_decimal(_), do: Decimal.new("0")
end
