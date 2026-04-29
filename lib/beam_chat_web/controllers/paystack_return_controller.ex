defmodule BeamChatWeb.PaystackReturnController do
  use BeamChatWeb, :controller

  alias BeamChat.Payments.PaystackClient
  alias BeamChat.Payments.PaystackUserLookup
  alias BeamChat.Wallet

  def show(conn, params) do
    reference = params["reference"] || params["trxref"]

    if reference in [nil, ""] do
      missing_reference(conn)
    else
      verify_and_complete(conn, reference)
    end
  end

  defp missing_reference(conn) do
    conn
    |> put_flash(:error, "Missing payment reference.")
    |> redirect(to: ~p"/wallet")
  end

  defp verify_and_complete(conn, reference) do
    case PaystackClient.verify_transaction(reference) do
      {:ok, data} -> complete_from_verify(data, conn)
      {:error, _} -> verify_failed(conn)
    end
  end

  defp verify_failed(conn) do
    conn
    |> put_flash(:error, "Could not verify payment. If you were charged, contact support.")
    |> redirect(to: ~p"/wallet")
  end

  defp complete_from_verify(data, conn) do
    if paystack_paid?(data) do
      apply_paystack_credit(data, conn)
    else
      conn
      |> put_flash(:error, "Payment not completed.")
      |> redirect(to: ~p"/wallet")
    end
  end

  defp paystack_paid?(data) do
    data["status"] == "success" and data["paid_at"] not in [nil, ""]
  end

  defp apply_paystack_credit(data, conn) do
    reference = data["reference"]
    amount_major = paystack_amount_to_decimal(data["amount"])

    case PaystackUserLookup.user_id_from_charge_data(data) do
      nil -> credit_mismatch(conn)
      uid -> finalize_credit(conn, uid, amount_major, reference, data)
    end
  end

  defp credit_mismatch(conn) do
    conn
    |> put_flash(:error, "Payment verified but wallet could not be matched.")
    |> redirect(to: ~p"/wallet")
  end

  defp finalize_credit(conn, uid, amount_major, reference, data) do
    case Wallet.complete_provider_credit(uid, amount_major, "paystack", reference, %{
           "paystack_id" => data["id"]
         }) do
      {:ok, _, _} ->
        conn
        |> put_flash(:info, "Wallet topped up successfully.")
        |> redirect(to: ~p"/wallet")

      {:error, _} ->
        conn
        |> put_flash(
          :error,
          "Could not apply credit. Contact support with reference #{reference}."
        )
        |> redirect(to: ~p"/wallet")
    end
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
