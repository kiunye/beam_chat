defmodule BeamChat.WalletTest do
  use BeamChat.DataCase, async: true

  import BeamChat.TestFixtures

  alias BeamChat.Payments.GroupSubscription
  alias BeamChat.Repo
  alias BeamChat.Wallet
  alias BeamChat.Wallet.WalletTransaction

  describe "complete_provider_credit/5" do
    test "is idempotent for the same Paystack reference" do
      user = user_fixture()
      {:ok, _} = Wallet.ensure_wallet(user.id)
      ref = Ecto.UUID.generate()
      amount = Decimal.new("50.00")

      assert {:ok, _, %WalletTransaction{status: "completed"}} =
               Wallet.complete_provider_credit(user.id, amount, "paystack", ref, %{})

      assert {:ok, _, %WalletTransaction{status: "completed"} = t2} =
               Wallet.complete_provider_credit(user.id, amount, "paystack", ref, %{})

      w = Wallet.get_wallet_for_user(user.id)
      assert Decimal.compare(w.balance, amount) == :eq

      assert Repo.aggregate(WalletTransaction, :count, :id) == 1
      assert t2.reference == ref
    end

    test "completes pending Paystack row then second call is noop" do
      user = user_fixture()
      ref = Ecto.UUID.generate()
      amount = Decimal.new("25.00")
      assert {:ok, _} = Wallet.create_pending_paystack_topup(user.id, amount, ref)

      assert {:ok, _, _} = Wallet.complete_provider_credit(user.id, amount, "paystack", ref, %{})

      assert {:ok, _, _} = Wallet.complete_provider_credit(user.id, amount, "paystack", ref, %{})

      w = Wallet.get_wallet_for_user(user.id)
      assert Decimal.compare(w.balance, amount) == :eq
      assert Repo.aggregate(WalletTransaction, :count, :id) == 1
    end

    test "rejects a webhook with non-KES currency in the no-pending-row branch (P1 #9)" do
      user = user_fixture()
      {:ok, _} = Wallet.ensure_wallet(user.id)
      ref = Ecto.UUID.generate()
      amount = Decimal.new("50.00")

      # Simulate the webhook path where the pending row was never created
      # (e.g. user closed the browser) but the webhook still arrives.
      assert {:error, {:unsupported_currency, "USD"}} =
               Wallet.complete_provider_credit(user.id, amount, "paystack", ref, %{
                 "currency" => "USD"
               })

      w = Wallet.get_wallet_for_user(user.id)
      assert Decimal.compare(w.balance, Decimal.new("0")) == :eq

      assert Repo.aggregate(WalletTransaction, :count, :id) == 0
    end

    test "accepts a webhook with currency: KES in the no-pending-row branch (P1 #9)" do
      user = user_fixture()
      {:ok, _} = Wallet.ensure_wallet(user.id)
      ref = Ecto.UUID.generate()
      amount = Decimal.new("50.00")

      assert {:ok, _, %WalletTransaction{status: "completed"}} =
               Wallet.complete_provider_credit(user.id, amount, "paystack", ref, %{
                 "currency" => "KES"
               })

      w = Wallet.get_wallet_for_user(user.id)
      assert Decimal.compare(w.balance, amount) == :eq
    end

    test "missing currency is allowed for legacy callers that do not pass it (P1 #9)" do
      user = user_fixture()
      {:ok, _} = Wallet.ensure_wallet(user.id)
      ref = Ecto.UUID.generate()
      amount = Decimal.new("50.00")

      # No "currency" key in extra metadata — preserved for the legacy
      # blank-metadata path so existing test setups and call sites do not
      # break. The KES constraint kicks in only when a currency is present
      # and is non-KES.
      assert {:ok, _, _} =
               Wallet.complete_provider_credit(user.id, amount, "paystack", ref, %{
                 "source" => "internal"
               })
    end
  end

  describe "subscribe_paid_room/2" do
    test "debits wallet and creates subscription" do
      owner = user_fixture()
      guest = user_fixture()
      room = room_fixture(owner, %{type: "paid", is_paid: true, price: Decimal.new("10.00")})
      {:ok, wallet} = Wallet.ensure_wallet(guest.id)

      {:ok, _} =
        wallet
        |> Ecto.Changeset.change(balance: Decimal.new("100.00"))
        |> Repo.update()

      assert {:ok, w_after, _txn, sub} = Wallet.subscribe_paid_room(guest, room)
      assert Decimal.compare(w_after.balance, Decimal.new("90.00")) == :eq
      assert sub.status == "active"
      assert sub.room_id == room.id
      assert sub.user_id == guest.id
    end

    test "returns insufficient_funds when balance too low" do
      owner = user_fixture()
      guest = user_fixture()
      room = room_fixture(owner, %{type: "paid", is_paid: true, price: Decimal.new("99.00")})
      {:ok, _} = Wallet.ensure_wallet(guest.id)

      assert {:error, :insufficient_funds} = Wallet.subscribe_paid_room(guest, room)
    end
  end

  describe "manual_credit/4" do
    test "allows staff to credit another user" do
      admin = user_fixture(%{role: "admin"})
      target = user_fixture()
      {:ok, _} = Wallet.ensure_wallet(target.id)

      assert {:ok, _, _} =
               Wallet.manual_credit(admin, target.id, Decimal.new("5.00"), "test grant")

      w = Wallet.get_wallet_for_user(target.id)
      assert Decimal.compare(w.balance, Decimal.new("5.00")) == :eq
    end

    test "forbids member when dev flag is off" do
      prev = Application.get_env(:beam_chat, :allow_dev_wallet_credit)
      Application.put_env(:beam_chat, :allow_dev_wallet_credit, false)

      member = user_fixture(%{role: "member"})
      target = user_fixture()
      {:ok, _} = Wallet.ensure_wallet(target.id)

      assert {:error, :forbidden} =
               Wallet.manual_credit(member, target.id, Decimal.new("1.00"), "nope")

      Application.put_env(:beam_chat, :allow_dev_wallet_credit, prev)
    end

    test "forbids moderator — wallet credit is a global admin power" do
      prev = Application.get_env(:beam_chat, :allow_dev_wallet_credit)
      Application.put_env(:beam_chat, :allow_dev_wallet_credit, false)

      moderator = user_fixture(%{role: "moderator"})
      target = user_fixture()
      {:ok, _} = Wallet.ensure_wallet(target.id)

      assert {:error, :forbidden} =
               Wallet.manual_credit(moderator, target.id, Decimal.new("1.00"), "nope")

      Application.put_env(:beam_chat, :allow_dev_wallet_credit, prev)
    end

    test "the credit is audited with the transaction it created" do
      admin = user_fixture(%{role: "admin"})
      target = user_fixture()
      {:ok, _} = Wallet.ensure_wallet(target.id)

      assert {:ok, _wallet, txn} =
               Wallet.manual_credit(admin, target.id, Decimal.new("5.00"), "audit grant")

      [audit] = BeamChat.Audit.list_recent(action: "wallet.manual_credit", limit: 1)
      assert audit.actor_id == admin.id
      assert audit.target_id == txn.id
      assert audit.metadata["amount"] == "5.00"
      assert audit.metadata["target_user_id"] == target.id
    end
  end

  describe "expire_subscriptions/0" do
    test "flips expired subscriptions to expired and returns the count" do
      owner = user_fixture()
      room = room_fixture(owner, %{type: "paid", is_paid: true, price: "10.00"})
      user = user_fixture()

      expired =
        group_subscription_fixture(user, room, %{
          status: "active",
          expires_at: DateTime.add(DateTime.utc_now(:second), -3600, :second)
        })

      assert Wallet.expire_subscriptions() == 1

      assert Repo.get(GroupSubscription, expired.id).status == "expired"
    end

    test "leaves active subscriptions untouched" do
      owner = user_fixture()
      room = room_fixture(owner, %{type: "paid", is_paid: true, price: "10.00"})
      user = user_fixture()

      active =
        group_subscription_fixture(user, room, %{
          status: "active",
          expires_at: DateTime.add(DateTime.utc_now(:second), 3600, :second)
        })

      assert Wallet.expire_subscriptions() == 0
      assert Repo.get(GroupSubscription, active.id).status == "active"
    end

    test "does not touch already-expired or cancelled rows" do
      owner = user_fixture()
      room = room_fixture(owner, %{type: "paid", is_paid: true, price: "10.00"})
      user = user_fixture()
      past = DateTime.add(DateTime.utc_now(:second), -3600, :second)

      group_subscription_fixture(user, room, %{status: "expired", expires_at: past})
      group_subscription_fixture(user, room, %{status: "cancelled", expires_at: past})

      assert Wallet.expire_subscriptions() == 0
    end
  end

  describe "list_transactions/3" do
    test "pages newest first with a stable id tie-break" do
      user = user_fixture()
      wallet = wallet_fixture(user)

      t1 = wallet_transaction_fixture(wallet, %{amount: "1.00"})
      t2 = wallet_transaction_fixture(wallet, %{amount: "2.00"})
      t3 = wallet_transaction_fixture(wallet, %{amount: "3.00"})

      {page1, more1} = Wallet.list_transactions(user.id, 2, 0)
      {page2, more2} = Wallet.list_transactions(user.id, 2, 2)

      assert [t3.id, t2.id] == Enum.map(page1, & &1.id)
      assert more1 == true
      assert [t1.id] == Enum.map(page2, & &1.id)
      assert more2 == false
    end

    test "returns has_more false when the page exactly covers all rows" do
      user = user_fixture()
      wallet = wallet_fixture(user)

      t1 = wallet_transaction_fixture(wallet, %{amount: "1.00"})
      t2 = wallet_transaction_fixture(wallet, %{amount: "2.00"})

      {txns, more} = Wallet.list_transactions(user.id, 2, 0)

      assert [t2.id, t1.id] == Enum.map(txns, & &1.id)
      assert more == false
    end

    test "returns an empty page with no more flag for a wallet without transactions" do
      user = user_fixture()
      wallet = wallet_fixture(user)

      assert {[], false} = Wallet.list_transactions(user.id, 20, 0)
      assert {[], false} = Wallet.list_transactions(user.id, 20, 1)
    end

    test "does not mix transactions between wallets" do
      user_a = user_fixture()
      user_b = user_fixture()
      wallet_a = wallet_fixture(user_a)
      wallet_b = wallet_fixture(user_b)

      ta = wallet_transaction_fixture(wallet_a, %{amount: "1.00"})
      tb = wallet_transaction_fixture(wallet_b, %{amount: "2.00"})

      {txns, false} = Wallet.list_transactions(user_a.id, 20, 0)
      assert Enum.map(txns, & &1.id) == [ta.id]
      refute Enum.any?(txns, &(&1.id == tb.id))
    end

    test "list_recent_transactions/2 keeps working as a non-paged wrapper" do
      user = user_fixture()
      wallet = wallet_fixture(user)
      wallet_transaction_fixture(wallet, %{amount: "1.00"})
      wallet_transaction_fixture(wallet, %{amount: "2.00"})

      assert [2, 1] ==
               Wallet.list_recent_transactions(user.id, 2)
               |> Enum.map(& &1.amount)
               |> Enum.map(&Decimal.to_integer/1)
    end
  end
end
