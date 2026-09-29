defmodule BeamChat.Payments.ObanWorkers.PendingTopupExpiry do
  @moduledoc """
  Binds the lifetime of any pending wallet top-up, regardless of
  provider (PRD §2.7): a failed or abandoned M-Pesa STK prompt — or a
  Paystack checkout the user never completed — cannot leave a wallet
  transaction stuck in limbo forever.

  A supervised, DB-backed scan survives restarts, so a pending row can
  never leak forever because the VM restarted. The expiry is a
  conditional update: a row is only flipped if it is STILL pending at
  write time, closing the TOCTOU where a webhook completing the row
  between the SELECT and the UPDATE would be overwritten by a stale
  failed-write. Webhooks keep a compensating late-completion branch.
  """

  use Oban.Worker, queue: :payments, max_attempts: 1

  require Logger

  alias BeamChat.Repo
  alias BeamChat.Wallet.WalletTransaction

  import Ecto.Query

  @pending_expiry_ms :timer.minutes(5)

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -@pending_expiry_ms, :millisecond)

    txns =
      Repo.all(
        from t in WalletTransaction,
          where: t.status == "pending" and t.inserted_at < ^cutoff
      )

    expired = Enum.count(txns, &mark_failed_if_still_pending/1)

    if expired > 0 do
      Logger.info("pending_topup_expiry: expired #{expired} pending transaction(s)")
    end

    :ok
  end

  defp mark_failed_if_still_pending(%WalletTransaction{} = txn) do
    metadata = Map.merge(txn.metadata || %{}, %{"error" => "pending_expired_no_callback"})

    {count, nil} =
      Repo.update_all(
        from(t in WalletTransaction,
          where: t.id == ^txn.id and t.status == "pending",
          update: [set: [status: "failed", metadata: ^metadata]]
        ),
        []
      )

    count > 0
  end
end
