defmodule BeamChatWeb.PaystackReturnController do
  @moduledoc """
  The browser return URL after Paystack's hosted checkout. Re-verifies
  the charge server-side (defence in depth against a forged redirect),
  then runs the provider's confirm callback — the same
  reference-matched, exactly-once credit path the webhook uses.
  """

  use BeamChatWeb, :controller

  alias BeamChat.Payments
  alias BeamChat.Payments.PaystackClient

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
    credentials = Payments.fetch_credentials("paystack")

    case PaystackClient.verify_transaction(credentials, reference) do
      {:ok, data} ->
        complete_from_verify(conn, data)

      {:error, _} ->
        conn
        |> put_flash(:error, "Could not verify payment. If you were charged, contact support.")
        |> redirect(to: ~p"/wallet")
    end
  end

  defp complete_from_verify(conn, data) do
    if data["status"] == "success" and data["paid_at"] not in [nil, ""] do
      case Payments.confirm_topup("paystack", %{"data" => data}) do
        {:ok, _txn} ->
          conn
          |> put_flash(:info, "Wallet topped up successfully.")
          |> redirect(to: ~p"/wallet")

        {:error, _} ->
          conn
          |> put_flash(
            :error,
            "Could not apply credit. Contact support with reference #{data["reference"]}."
          )
          |> redirect(to: ~p"/wallet")
      end
    else
      conn
      |> put_flash(:error, "Payment not completed.")
      |> redirect(to: ~p"/wallet")
    end
  end
end
