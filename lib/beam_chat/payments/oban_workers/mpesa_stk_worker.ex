defmodule BeamChat.Payments.ObanWorkers.MpesaStkWorker do
  @moduledoc """
  Performs the actual Daraja STK push for a pre-created pending
  transaction and attaches the `CheckoutRequestID` as the transaction's
  provider reference. Completion is webhook-driven; this worker only
  initiates the prompt.

  Daraja business errors mark the transaction failed immediately (no
  retry can fix a rejected shortcode); transport errors retry, and the
  final attempt marks the transaction failed so it can't leak as
  "pending" once Oban discards the job.
  """

  use Oban.Worker, queue: :payments, max_attempts: 3

  alias BeamChat.Payments
  alias BeamChat.Payments.MpesaClient
  alias BeamChat.Repo
  alias BeamChat.Wallet
  alias BeamChat.Wallet.WalletTransaction

  @impl Oban.Worker
  def perform(%Oban.Job{attempt: attempt, max_attempts: max_attempts} = job) do
    %{"user_id" => _user_id, "txn_id" => txn_id, "phone" => phone} = job.args
    txn = Repo.get!(WalletTransaction, txn_id)

    cond do
      txn.status == "completed" ->
        # Webhook beat us to it. Nothing to do.
        :ok

      txn.status == "failed" ->
        # Already finalized by a previous attempt's mark_failed.
        :ok

      true ->
        case run_stk_for_txn(txn, phone) do
          :ok ->
            # STK push accepted by Daraja. The pending-topup expiry scan
            # marks this txn "failed" if no webhook flips it to
            # "completed" within the expiry window.
            :ok

          {:error, reason} when attempt >= max_attempts ->
            _ = Wallet.mark_transaction_failed(txn.id, "stk_push_exhausted: #{inspect(reason)}")
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp run_stk_for_txn(%WalletTransaction{} = txn, phone) do
    config = Payments.fetch_credentials("mpesa")
    callback_url = config["stk_callback_url"]

    if callback_url in [nil, ""] do
      {:error, :missing_callback_url}
    else
      do_stk_push(config, txn, phone, callback_url)
    end
  end

  defp do_stk_push(config, %WalletTransaction{id: txn_id} = txn, phone, callback_url) do
    account_ref = account_ref(txn_id)

    with {:ok, token} <- MpesaClient.get_access_token(config),
         {:ok, checkout_id} <-
           MpesaClient.stk_push(
             config,
             token,
             phone,
             txn.amount,
             account_ref,
             "BeamChat wallet",
             callback_url
           ),
         {:ok, _} <- Wallet.attach_provider_reference(txn, checkout_id) do
      :ok
    else
      {:error, {:mpesa_stk, %{"errorMessage" => msg}}} ->
        _ = Wallet.mark_transaction_failed(txn.id, msg)
        :ok

      {:error, {:mpesa_stk, body}} ->
        _ = Wallet.mark_transaction_failed(txn.id, inspect(body))
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Builds an M-Pesa `AccountReference` from a wallet transaction UUID.

  We strip hyphens and slice the LAST 18 hex chars, because the tail of
  the UUID carries the distinguishing entropy: for v4 UUIDs the head
  holds fixed version/variant bits while the last 12 hex digits are
  fully random. 18 chars is within the legacy Daraja 20-char
  AccountReference limit and gives ~56+ bits of real entropy, so
  collision probability is negligible.
  """
  def account_ref(txn_id) when is_binary(txn_id) do
    txn_id
    |> String.replace("-", "")
    |> String.slice(-18, 18)
  end
end
