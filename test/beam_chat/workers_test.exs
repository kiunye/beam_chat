defmodule BeamChat.WorkersTest do
  use BeamChat.DataCase, async: false

  alias BeamChat.Moderation.RuleEngine
  alias BeamChat.Payments.ObanWorkers.MpesaStkWorker
  alias BeamChat.Payments.ObanWorkers.PendingTopupExpiry
  alias BeamChat.Payments.RoomSubscription
  alias BeamChat.Repo
  alias BeamChat.Wallet
  alias BeamChat.Wallet.WalletTransaction
  alias BeamChat.Workers.ExpireSubscriptions
  alias BeamChat.Workers.RefreshModerationCache

  describe "PendingTopupExpiry" do
    test "expires stale pending top-ups regardless of provider" do
      user = user_fixture()
      stale_mpesa = pending_topup_fixture(user, Decimal.new("10.00"), "mpesa")
      stale_paystack = pending_topup_fixture(user, Decimal.new("20.00"), "paystack")

      ten_minutes_ago = DateTime.add(DateTime.utc_now(), -10 * 60, :second)

      # Backdate two pending rows; keep the fresh one untouched.
      from(t in WalletTransaction, where: t.id in ^[stale_mpesa.id, stale_paystack.id])
      |> Repo.update_all(set: [inserted_at: ten_minutes_ago])

      assert :ok = PendingTopupExpiry.perform(%Oban.Job{})

      assert Repo.get!(WalletTransaction, stale_mpesa.id).status == "failed"
      assert Repo.get!(WalletTransaction, stale_paystack.id).status == "failed"

      assert Repo.get!(WalletTransaction, stale_mpesa.id).metadata["error"] ==
               "pending_expired_no_callback"
    end

    test "ignores rows that are not pending" do
      user = user_fixture()
      pending = pending_topup_fixture(user, Decimal.new("10.00"), "paystack")
      ten_minutes_ago = DateTime.add(DateTime.utc_now(), -10 * 60, :second)

      from(w in WalletTransaction, where: w.id == ^pending.id)
      |> Repo.update_all(set: [inserted_at: ten_minutes_ago])

      {:ok, _} = Wallet.mark_transaction_failed(pending.id, "webhook_completed_first")

      assert :ok = PendingTopupExpiry.perform(%Oban.Job{})

      # The expiry job only flips pending rows; the webhook's finalization is preserved.
      assert Repo.get!(WalletTransaction, pending.id).metadata["error"] ==
               "webhook_completed_first"
    end
  end

  describe "MpesaStkWorker" do
    test "account_ref/1 is the de-hyphenated UUID tail (last 18 hex chars)" do
      txn_id = Ecto.UUID.generate()
      assert String.length(MpesaStkWorker.account_ref(txn_id)) == 18
    end

    test "without credentials, the push is skipped and the row stays pending" do
      user = user_fixture()
      pending = pending_topup_fixture(user, Decimal.new("10.00"), "mpesa")

      assert {:error, :missing_callback_url} =
               MpesaStkWorker.perform(%Oban.Job{
                 attempt: 1,
                 max_attempts: 3,
                 args: %{"user_id" => user.id, "txn_id" => pending.id, "phone" => "+254700000000"}
               })

      assert Repo.get!(WalletTransaction, pending.id).status == "pending"
    end

    test "on the final attempt, the row is flipped to failed" do
      user = user_fixture()
      pending = pending_topup_fixture(user, Decimal.new("10.00"), "mpesa")

      assert {:error, :missing_callback_url} =
               MpesaStkWorker.perform(%Oban.Job{
                 attempt: 3,
                 max_attempts: 3,
                 args: %{"user_id" => user.id, "txn_id" => pending.id, "phone" => "+254700000000"}
               })

      assert Repo.get!(WalletTransaction, pending.id).status == "failed"
    end

    test "already-finalized rows are left alone by the worker" do
      user = user_fixture()
      pending = pending_topup_fixture(user, Decimal.new("10.00"), "mpesa")
      {:ok, _} = Wallet.mark_transaction_failed(pending.id, "webhook_completed_first")

      assert :ok =
               MpesaStkWorker.perform(%Oban.Job{
                 attempt: 1,
                 max_attempts: 3,
                 args: %{"user_id" => user.id, "txn_id" => pending.id, "phone" => "+254700000000"}
               })

      # A finalized row was never pushed because the early-exit path was taken.
      assert Repo.get!(WalletTransaction, pending.id).status == "failed"

      assert Repo.get!(WalletTransaction, pending.id).metadata["error"] ==
               "webhook_completed_first"
    end
  end

  describe "ExpireSubscriptions" do
    test "past-due subscriptions flip to expired; active ones untouched" do
      user = user_fixture()
      admin = admin_fixture()
      room = paid_room_fixture(admin, price: Decimal.new("50.00"))

      subscribe_fixture(user, room,
        expires_at: DateTime.add(DateTime.utc_now(), -86_400, :second),
        status: "active"
      )

      assert :ok = ExpireSubscriptions.perform(%Oban.Job{})

      assert Repo.get_by(RoomSubscription, room_id: room.id).status == "expired"
    end
  end

  describe "RefreshModerationCache" do
    test "the engine sees newly-active rules" do
      rule =
        rule_fixture(
          name: "synthetic-#{System.unique_integer([:positive])}",
          config: %{"words" => ["synthblock"]}
        )

      assert :ok = RefreshModerationCache.perform(%Oban.Job{})

      msg = %{user_id: nil, content: "hello synthblock"}
      result = RuleEngine.apply_rules(msg)

      assert {:blocked, _msg, %{name: name}, _reason} = result
      assert name == rule.name
    end
  end
end
