defmodule BeamChatWeb.Webhooks.MpesaWebhookController do
  use BeamChatWeb, :controller

  alias BeamChat.Repo
  alias BeamChat.Wallet
  alias BeamChat.Wallet.Wallet, as: WalletSchema
  alias BeamChat.Wallet.WalletTransaction

  def create(conn, _params) do
    raw = conn.private[:raw_body] || ""

    case Jason.decode(raw) do
      {:ok, body} ->
        case extract_stk_callback(body) do
          {:ok, checkout_id, result_code} ->
            handle_callback(checkout_id, result_code)
            send_resp(conn, 200, "ok")

          :ignore ->
            send_resp(conn, 200, "ignored")
        end

      {:error, _} ->
        send_resp(conn, 400, "bad json")
    end
  end

  defp extract_stk_callback(%{"Body" => %{"stkCallback" => cb}}) do
    checkout_id = cb["CheckoutRequestID"]

    if is_binary(checkout_id) do
      {:ok, checkout_id, cb["ResultCode"]}
    else
      :ignore
    end
  end

  defp extract_stk_callback(_), do: :ignore

  defp handle_callback(checkout_id, result_code) do
    case Repo.get_by(WalletTransaction, reference: checkout_id) do
      nil ->
        :ok

      %WalletTransaction{status: "completed"} ->
        :ok

      %WalletTransaction{status: "pending"} = txn ->
        wallet = Repo.get!(WalletSchema, txn.wallet_id)

        if result_code == 0 do
          _ =
            Wallet.complete_provider_credit(
              wallet.user_id,
              txn.amount,
              "mpesa",
              checkout_id,
              %{"source" => "webhook"}
            )
        else
          _ =
            txn
            |> Ecto.Changeset.change(
              status: "failed",
              metadata: Map.merge(txn.metadata || %{}, %{"mpesa_result_code" => result_code})
            )
            |> Repo.update()
        end

        :ok

      _ ->
        :ok
    end
  end
end
