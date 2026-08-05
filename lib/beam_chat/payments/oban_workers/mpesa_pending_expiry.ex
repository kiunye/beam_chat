defmodule BeamChat.Payments.ObanWorkers.MpesaPendingExpiry do
  @moduledoc false

  use Oban.Worker, queue: :payments, max_attempts: 1

  require Logger

  alias BeamChat.Repo
  alias BeamChat.Wallet.WalletTransaction

  import Ecto.Query

  # A pending M-Pesa credit is expired if no webhook flipped it to
  # "completed" within this window. Replaces the STK worker's former
  # in-process `spawn` watchdog (SECURITY_REVIEW.md P1 #10): a supervised
  # DB-backed scan survives restarts, so a pending row can never leak
  # forever because the VM restarted.
  @pending_expiry_ms :timer.minutes(5)

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -@pending_expiry_ms, :millisecond)

    txns =
      Repo.all(
        from t in WalletTransaction,
          where: t.status == "pending" and t.provider == "mpesa" and t.inserted_at < ^cutoff
      )

    expired = Enum.count(txns, &mark_failed_if_still_pending(&1))

    if expired > 0 do
      Logger.info("mpesa_pending_expiry: expired #{expired} pending transaction(s)")
    end

    :ok
  end

  # Conditional update: a row is only flipped if it is STILL pending at write
  # time, closing the TOCTOU where a webhook completing the row between the
  # SELECT above and an unconditional UPDATE would be overwritten by a stale
  # failed-write.
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
