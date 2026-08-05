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

    Enum.each(txns, &mark_failed(&1, "pending_expired_no_callback"))

    if txns != [] do
      Logger.info("mpesa_pending_expiry: expired #{length(txns)} pending transaction(s)")
    end

    :ok
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
