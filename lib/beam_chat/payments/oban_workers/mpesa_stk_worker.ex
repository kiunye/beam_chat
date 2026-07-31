defmodule BeamChat.Payments.ObanWorkers.MpesaStkWorker do
  @moduledoc false

  use Oban.Worker, queue: :payments, max_attempts: 3

  alias BeamChat.Payments.MpesaClient
  alias BeamChat.Repo
  alias BeamChat.Wallet
  alias BeamChat.Wallet.WalletTransaction

  # After this delay, if the STK push has not produced a webhook callback
  # that flipped the txn to "completed", we mark it "failed" so the user
  # sees a clean refund/expiry message and the row stops being "pending".
  # This bounds the lifetime of a pending row regardless of how many Oban
  # attempts are left. See SECURITY_REVIEW.md P1 #10.
  @pending_expiry_ms :timer.minutes(5)

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
            # STK push accepted by Daraja. Schedule a watchdog: if the
            # webhook has not flipped the txn to "completed" within
            # @pending_expiry_ms, mark it "failed".
            schedule_pending_watchdog(txn.id)
            :ok

          {:error, reason} when attempt >= max_attempts ->
            # Last attempt — flip the txn to "failed" so it doesn't leak
            # as "pending" forever once Oban discards the job.
            _ = mark_failed(txn, "stk_push_exhausted: #{inspect(reason)}")
            {:error, reason}

          {:error, reason} ->
            # Not the last attempt — let Oban retry.
            {:error, reason}
        end
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

  # Fire-and-forget watchdog. The spawned process checks the txn after the
  # expiry window; if it is still "pending", it marks it "failed" so the
  # user-facing "top up pending" UI never gets stuck.
  defp schedule_pending_watchdog(txn_id) do
    parent = self()

    spawn(fn ->
      receive do
        :ok -> :ok
      after
        @pending_expiry_ms ->
          _ = expire_if_pending(txn_id)
          send(parent, :ok)
      end
    end)
  end

  defp expire_if_pending(txn_id) do
    txn = Repo.get(WalletTransaction, txn_id)

    if txn && txn.status == "pending" do
      mark_failed(txn, "pending_expired_no_callback")
    else
      {:ok, :no_op}
    end
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
