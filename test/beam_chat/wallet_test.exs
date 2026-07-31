defmodule BeamChat.WalletTest do
  use BeamChat.DataCase, async: true

  import BeamChat.TestFixtures

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
  end
end
