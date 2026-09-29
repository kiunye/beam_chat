defmodule BeamChat.WalletTest do
  use BeamChat.DataCase, async: false

  alias BeamChat.Accounts
  alias BeamChat.Payments.RoomSubscription
  alias BeamChat.Repo
  alias BeamChat.Rooms.AccessPolicy
  alias BeamChat.Settings
  alias BeamChat.Wallet

  setup do
    # Some tests change the platform base currency through the Settings
    # table. Always restore KES so later tests start from the default.
    on_exit(fn ->
      Settings.put(:base_currency, "KES")
      Settings.put(:room_creation_open, true)
    end)

    :ok
  end

  defp paystack_pending(
         user,
         amount \\ Decimal.new("100.00"),
         reference \\ "ref-paystack-#{System.unique_integer([:positive])}"
       ) do
    pending_topup_fixture(user, amount, "paystack", reference)
  end

  defp paystack_confirm(reference, amount_subunits) do
    BeamChat.Payments.confirm_topup(
      "paystack",
      %{
        "data" => %{
          "reference" => reference,
          "amount" => amount_subunits,
          "status" => "success",
          "currency" => "KES"
        }
      }
    )
  end

  defp current_balance(user) do
    wallet_fixture(user).balance
  end

  describe "ensure_wallet/1" do
    test "creates a wallet with zero balance, is idempotent" do
      user = user_fixture()

      assert {:ok, first} = Wallet.ensure_wallet(user.id)
      assert Decimal.equal?(first.balance, Decimal.new("0.00"))
      assert first.currency == "KES"

      assert {:ok, second} = Wallet.ensure_wallet(user.id)
      assert second.id == first.id
    end

    test "new wallets adopt the platform base currency" do
      Settings.put(:base_currency, "USD")

      user = user_fixture()
      {:ok, wallet} = Wallet.ensure_wallet(user.id)
      assert wallet.currency == "USD"
    end
  end

  describe "list_transactions/3" do
    test "returns newest-first with has_more pagination" do
      user = user_fixture()
      admin = admin_fixture()
      _wallet = wallet_fixture(user)

      for i <- 1..25 do
        {:ok, _w, _t} = Wallet.manual_credit(admin, user.id, Decimal.new("1.00"), "seed #{i}")
      end

      {page_one, has_more_one} = Wallet.list_transactions(user.id, 20, 0)
      assert Enum.count(page_one) == 20
      assert has_more_one

      {page_two, has_more_two} = Wallet.list_transactions(user.id, 20, 20)
      assert Enum.count(page_two) == 5
      refute has_more_two

      # Newest-first order maintained by stable (inserted_at, id) tie-break.
      first_in_page_two = hd(page_two)
      assert hd(page_one).inserted_at >= first_in_page_two.inserted_at
      assert hd(page_one).id >= first_in_page_two.id
    end

    test "empty wallet returns empty page" do
      user = user_fixture()
      _wallet = wallet_fixture(user)

      assert {[], false} = Wallet.list_transactions(user.id, 5, 0)
    end

    test "unknown user returns empty page (no wallet created)" do
      assert {[], false} = Wallet.list_transactions(Ecto.UUID.generate(), 5, 0)
    end
  end

  describe "manual_credit/4" do
    test "writes the credit and logs it in the same transaction" do
      actor = admin_fixture()
      target = user_fixture()
      amount = Decimal.new("42.00")

      log_count_before = wallet_log_count(target)
      {:ok, wallet, txn} = Wallet.manual_credit(actor, target.id, amount, "welcome")

      assert Decimal.equal?(wallet.balance, amount)
      assert txn.type == "credit"
      assert txn.status == "completed"
      assert txn.provider == "internal"
      assert txn.metadata["manual"] == true

      assert wallet_log_count(target) == log_count_before + 1
      log = wallet_log(target) |> hd()
      assert log.action == "wallet_manual_credit"
      assert log.actor_id == actor.id
      assert log.reason == "welcome"
      assert log.metadata["amount"] == "42.00"
    end

    test "non-admin can't credit" do
      member = user_fixture()
      target = user_fixture()

      assert {:error, :forbidden} =
               Wallet.manual_credit(member, target.id, Decimal.new("1.00"), "nope")
    end

    test "banned admin can't credit other's wallet" do
      admin_target = user_fixture()
      admin_actor = admin_fixture()
      {:ok, banned} = Accounts.ban_user(admin_actor, admin_target, "test ban")

      assert banned.is_banned
      target = user_fixture()

      assert {:error, reason} =
               Wallet.manual_credit(banned, target.id, Decimal.new("1.00"), "nope")

      assert reason in [:forbidden, :banned]
    end
  end

  describe "complete_provider_credit/5 (the idempotency core, PRD §2.7)" do
    test "happy path: pending row completes exactly once" do
      user = user_fixture()
      pending = paystack_pending(user)
      id_key = pending.provider_reference

      assert user
             |> wallet_fixture()
             |> Map.fetch!(:balance)
             |> Decimal.equal?(Decimal.new("0.00"))

      assert {:ok, txn} = paystack_confirm(id_key, 10_000)
      assert txn.status == "completed"
      assert txn.provider == "paystack"
      assert Decimal.equal?(current_balance(user), Decimal.new("100.00"))

      # Replay the same callback — no double credit.
      assert {:ok, txn2} = paystack_confirm(id_key, 10_000)
      assert Decimal.equal?(current_balance(user), Decimal.new("100.00"))
      assert txn2.id == txn.id
    end

    test "amount mismatch is rejected" do
      user = user_fixture()
      pending = paystack_pending(user, Decimal.new("100.00"))

      assert {:error, :amount_mismatch} = paystack_confirm(pending.provider_reference, 5_000)

      assert user
             |> wallet_fixture()
             |> Map.fetch!(:balance)
             |> Decimal.equal?(Decimal.new("0.00"))

      assert Repo.reload(pending).status == "pending"
    end

    test "currency mismatch is rejected" do
      user = user_fixture()
      pending = paystack_pending(user)

      assert {:error, {:unsupported_currency, "USD"}} =
               BeamChat.Payments.confirm_topup(
                 "paystack",
                 %{
                   "data" => %{
                     "reference" => pending.provider_reference,
                     "amount" => 10_000,
                     "status" => "success",
                     "currency" => "USD"
                   }
                 }
               )

      assert Repo.reload(pending).status == "pending"
    end

    test "unknown reference is rejected" do
      assert {:error, :unknown_reference} =
               BeamChat.Payments.confirm_topup(
                 "paystack",
                 %{
                   "data" => %{
                     "reference" => "no-such-ref",
                     "amount" => 10_000,
                     "status" => "success",
                     "currency" => "KES"
                   }
                 }
               )
    end

    test "late completion: expiry-closed row still credits when the real callback arrives" do
      user = user_fixture()
      pending = paystack_pending(user)

      {:ok, _} = Wallet.mark_transaction_failed(pending.id, "pending_expired_no_callback")
      assert Repo.reload(pending).status == "failed"

      assert {:ok, txn} = paystack_confirm(pending.provider_reference, 10_000)
      assert txn.status == "completed"
      assert Decimal.equal?(current_balance(user), Decimal.new("100.00"))
    end

    test "a completed row is not re-finalized by a retry" do
      user = user_fixture()
      pending = paystack_pending(user)

      assert {:ok, first_txn} = paystack_confirm(pending.provider_reference, 10_000)
      assert {:ok, second_txn} = paystack_confirm(pending.provider_reference, 10_000)

      assert first_txn.id == second_txn.id
      assert Decimal.equal?(current_balance(user), Decimal.new("100.00"))
    end
  end

  describe "subscribe_paid_room/2 (atomic debit + grant, PRD §2.6)" do
    test "debits and grants in one transaction" do
      user = user_fixture()
      admin = admin_fixture()
      room = paid_room_fixture(admin, price: Decimal.new("150.00"))

      _wallet = wallet_fixture(user)

      {:ok, _w, _credit_txn} =
        Wallet.manual_credit(admin, user.id, Decimal.new("500.00"), "funds")

      assert {:ok, wallet, debit_txn, sub} = Wallet.subscribe_paid_room(user, room)

      assert Decimal.equal?(wallet.balance, Decimal.new("350.00"))
      assert debit_txn.type == "debit"
      assert debit_txn.metadata["room_id"] == room.id
      assert debit_txn.status == "completed"

      assert sub.status == "active"
      assert sub.user_id == user.id
      assert sub.room_id == room.id
      assert !is_nil(sub.started_at)
      assert !is_nil(sub.expires_at)
      assert DateTime.diff(sub.expires_at, sub.started_at) == 30 * 86_400

      # Access: the subscription table change is visible to policy checks.
      assert AccessPolicy.active_subscription?(room.id, user.id)
    end

    test "insufficient funds writes nothing" do
      user = user_fixture()
      admin = admin_fixture()
      room = paid_room_fixture(admin, price: Decimal.new("150.00"))

      _wallet = wallet_fixture(user)
      {:ok, w, _txn} = Wallet.manual_credit(admin, user.id, Decimal.new("100.00"), "funds")

      assert {:error, :insufficient_funds} = Wallet.subscribe_paid_room(user, room)

      assert Repo.get!(BeamChat.Wallet.Wallet, w.id).balance
             |> Decimal.equal?(Decimal.new("100.00"))

      assert Repo.aggregate(RoomSubscription, :count, :id) == 0
    end

    test "already subscribed is rejected without another debit" do
      user = user_fixture()
      admin = admin_fixture()
      room = paid_room_fixture(admin, price: Decimal.new("10.00"))

      _wallet = wallet_fixture(user)

      {:ok, _w, _txn} =
        Wallet.manual_credit(admin, user.id, Decimal.new("100.00"), "funds")

      assert {:ok, _, _, _} = Wallet.subscribe_paid_room(user, room)
      subs_before = Repo.aggregate(RoomSubscription, :count, :id)

      assert {:error, :already_subscribed} = Wallet.subscribe_paid_room(user, room)
      assert Repo.aggregate(RoomSubscription, :count, :id) == subs_before
    end

    test "non-paid rooms are rejected" do
      user = user_fixture()
      admin = admin_fixture()
      room = room_fixture(admin)

      _wallet = wallet_fixture(user)
      {:ok, _w, _txn} = Wallet.manual_credit(admin, user.id, Decimal.new("100.00"), "funds")

      assert {:error, :not_paid_room} = Wallet.subscribe_paid_room(user, room)
    end

    test "banned users are blocked from spending (PRD §2.2)" do
      admin = admin_fixture()
      buyer = user_fixture()
      room = paid_room_fixture(admin, price: Decimal.new("50.00"))

      _wallet = wallet_fixture(buyer)
      {:ok, _w, _txn} = Wallet.manual_credit(admin, buyer.id, Decimal.new("100.00"), "funds")
      {:ok, buyer} = Accounts.ban_user(admin, buyer, "test ban")

      assert {:error, :banned} = Wallet.subscribe_paid_room(buyer, room)
    end
  end

  describe "mark_transaction_failed/2" do
    test "flips a pending row exactly once" do
      user = user_fixture()
      pending = paystack_pending(user)

      assert {:ok, flipped} = Wallet.mark_transaction_failed(pending.id, "expired")
      assert flipped.status == "failed"

      assert {:error, :not_pending} = Wallet.mark_transaction_failed(pending.id, "expired")
    end
  end

  defp wallet_log_count(user) do
    Repo.aggregate(
      from(l in BeamChat.Moderation.ModerationLog,
        where: l.target_id == ^user.id and l.target_type == "user"
      ),
      :count,
      :id
    )
  end

  defp wallet_log(user) do
    Repo.all(
      from l in BeamChat.Moderation.ModerationLog,
        where: l.target_id == ^user.id and l.target_type == "user",
        order_by: [desc: l.inserted_at, desc: l.id]
    )
  end
end
