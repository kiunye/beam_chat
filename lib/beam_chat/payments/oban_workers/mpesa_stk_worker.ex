defmodule BeamChat.Payments.ObanWorkers.MpesaStkWorker do
  @moduledoc false

  use Oban.Worker, queue: :payments, max_attempts: 3

  alias BeamChat.Payments.MpesaClient
  alias BeamChat.Repo
  alias BeamChat.Wallet
  alias BeamChat.Wallet.WalletTransaction

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"user_id" => _user_id, "txn_id" => txn_id, "phone" => phone}
      }) do
    txn = Repo.get!(WalletTransaction, txn_id)

    if txn.status != "pending" do
      :ok
    else
      run_stk_for_txn(txn, phone)
    end
  end

  defp run_stk_for_txn(%WalletTransaction{} = txn, phone) do
    callback_url = Application.get_env(:beam_chat, :mpesa)[:stk_callback_url]

    if callback_url in [nil, ""] do
      {:error, :missing_callback_url}
    else
      do_stk_push(txn, phone, callback_url)
    end
  end

  defp do_stk_push(%WalletTransaction{id: txn_id} = txn, phone, callback_url) do
    account_ref = account_ref(txn_id)

    with {:ok, token} <- MpesaClient.get_access_token(),
         {:ok, checkout_id} <-
           MpesaClient.stk_push(
             token,
             phone,
             txn.amount,
             account_ref,
             "BeamChat wallet",
             callback_url
           ),
         {:ok, _} <- Wallet.attach_mpesa_checkout_id(txn, checkout_id) do
      :ok
    else
      {:error, {:mpesa_stk, %{"errorMessage" => msg}}} ->
        _ = mark_failed(txn, msg)
        :ok

      {:error, {:mpesa_stk, body}} ->
        _ = mark_failed(txn, inspect(body))
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Builds an M-Pesa `AccountReference` from a wallet transaction UUID.

  Daraja 2.0 accepts up to ~40 chars; legacy Daraja accepts 20. We strip
  hyphens and slice to 18 hex chars — well within both limits — giving
  18×4 = 72 bits of entropy. Collision probability is negligible for our
  scale (vs. the previous 12-char / 48-bit slice which was ~1/4096 per
  same-microsecond pair).
  """
  def account_ref(txn_id) when is_binary(txn_id) do
    txn_id
    |> String.replace("-", "")
    |> String.slice(0, 18)
  end

  defp mark_failed(%WalletTransaction{} = txn, reason) do
    txn
    |> Ecto.Changeset.change(
      status: "failed",
      metadata: Map.merge(txn.metadata || %{}, %{"error" => reason})
    )
    |> Repo.update()
  end
end
