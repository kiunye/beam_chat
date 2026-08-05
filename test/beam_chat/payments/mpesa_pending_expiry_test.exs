defmodule BeamChat.Payments.ObanWorkers.MpesaPendingExpiryTest do
  use BeamChat.DataCase, async: true

  import BeamChat.TestFixtures
  import Ecto.Query

  alias BeamChat.Payments.ObanWorkers.MpesaPendingExpiry
  alias BeamChat.Repo
  alias BeamChat.Wallet.WalletTransaction

  describe "perform/1" do
    setup do
      user = user_fixture()
      wallet = wallet_fixture(user)
      {:ok, wallet: wallet}
    end

    defp backdate(txn, minutes) do
      Repo.update_all(
        from(t in WalletTransaction, where: t.id == ^txn.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -minutes, :minute)]
      )
    end

    test "expires a pending mpesa txn older than the window", %{wallet: wallet} do
      txn =
        wallet_transaction_fixture(wallet, %{status: "pending", provider: "mpesa", reference: nil})

      backdate(txn, 6)

      assert :ok = MpesaPendingExpiry.perform(%Oban.Job{args: %{}})

      reloaded = Repo.get!(WalletTransaction, txn.id)
      assert reloaded.status == "failed"
      assert reloaded.metadata["error"] == "pending_expired_no_callback"
    end

    test "leaves a fresh pending mpesa txn alone", %{wallet: wallet} do
      txn =
        wallet_transaction_fixture(wallet, %{status: "pending", provider: "mpesa", reference: nil})

      assert :ok = MpesaPendingExpiry.perform(%Oban.Job{args: %{}})

      reloaded = Repo.get!(WalletTransaction, txn.id)
      assert reloaded.status == "pending"
    end

    test "leaves an old completed mpesa txn alone", %{wallet: wallet} do
      txn = wallet_transaction_fixture(wallet, %{status: "completed", provider: "mpesa"})
      backdate(txn, 6)

      assert :ok = MpesaPendingExpiry.perform(%Oban.Job{args: %{}})

      reloaded = Repo.get!(WalletTransaction, txn.id)
      assert reloaded.status == "completed"
    end

    test "leaves an old pending paystack txn alone", %{wallet: wallet} do
      txn =
        wallet_transaction_fixture(wallet, %{
          status: "pending",
          provider: "paystack",
          reference: "pay-ref-1"
        })

      backdate(txn, 6)

      assert :ok = MpesaPendingExpiry.perform(%Oban.Job{args: %{}})

      reloaded = Repo.get!(WalletTransaction, txn.id)
      assert reloaded.status == "pending"
    end

    test "is idempotent", %{wallet: wallet} do
      txn =
        wallet_transaction_fixture(wallet, %{status: "pending", provider: "mpesa", reference: nil})

      backdate(txn, 6)

      assert :ok = MpesaPendingExpiry.perform(%Oban.Job{args: %{}})
      assert :ok = MpesaPendingExpiry.perform(%Oban.Job{args: %{}})

      reloaded = Repo.get!(WalletTransaction, txn.id)
      assert reloaded.status == "failed"
    end
  end
end
