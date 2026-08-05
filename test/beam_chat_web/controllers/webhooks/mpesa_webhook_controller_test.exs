defmodule BeamChatWeb.Webhooks.MpesaWebhookControllerTest do
  use BeamChatWeb.ConnCase, async: true

  import BeamChat.TestFixtures
  import Ecto.Query

  alias BeamChat.Repo
  alias BeamChat.Wallet
  alias BeamChat.Wallet.WalletTransaction

  setup do
    user = user_fixture()
    wallet = wallet_fixture(user)
    {:ok, user: user, wallet: wallet}
  end

  defp mpesa_webhook(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/webhooks/mpesa/test-secret", Jason.encode!(body))
  end

  defp stk_callback(checkout_id, result_code) do
    %{
      "Body" => %{
        "stkCallback" => %{"CheckoutRequestID" => checkout_id, "ResultCode" => result_code}
      }
    }
  end

  defp pending_mpesa_txn(wallet, checkout_id) do
    {:ok, txn} = Wallet.create_pending_mpesa_topup(wallet.user_id, Decimal.new("100"))
    {:ok, txn} = Wallet.attach_mpesa_checkout_id(txn, checkout_id)
    txn
  end

  defp flip_to_failed_expired(txn) do
    Repo.update_all(
      from(t in WalletTransaction, where: t.id == ^txn.id),
      set: [status: "failed", metadata: %{"error" => "pending_expired_no_callback"}]
    )
  end

  describe "create/2 with a successful stkCallback" do
    test "completes a pending row and credits the wallet", %{conn: conn, wallet: wallet} do
      checkout_id = "ws_pending_" <> Ecto.UUID.generate()
      txn = pending_mpesa_txn(wallet, checkout_id)

      conn = mpesa_webhook(conn, stk_callback(checkout_id, 0))

      assert response(conn, 200) == "ok"

      reloaded = Repo.reload!(txn)
      assert reloaded.status == "completed"
      assert reloaded.metadata["source"] == "webhook"

      reloaded_wallet = Repo.reload!(wallet)
      assert Decimal.compare(reloaded_wallet.balance, Decimal.new("100")) == :eq
    end

    test "completes a failed+expired row when M-Pesa reports success", %{
      conn: conn,
      wallet: wallet
    } do
      checkout_id = "ws_expired_paid_" <> Ecto.UUID.generate()
      txn = pending_mpesa_txn(wallet, checkout_id)
      flip_to_failed_expired(txn)

      conn = mpesa_webhook(conn, stk_callback(checkout_id, 0))

      assert response(conn, 200) == "ok"

      reloaded = Repo.reload!(txn)
      assert reloaded.status == "completed"
      assert reloaded.metadata["error"] == "pending_expired_no_callback"
      assert reloaded.metadata["late_completion"] == true

      reloaded_wallet = Repo.reload!(wallet)
      assert Decimal.compare(reloaded_wallet.balance, Decimal.new("100")) == :eq
    end
  end

  describe "create/2 with a failed stkCallback" do
    test "records mpesa_result_code on a failed+expired row", %{conn: conn, wallet: wallet} do
      checkout_id = "ws_expired_declined_" <> Ecto.UUID.generate()
      txn = pending_mpesa_txn(wallet, checkout_id)
      flip_to_failed_expired(txn)

      conn = mpesa_webhook(conn, stk_callback(checkout_id, 1))

      assert response(conn, 200) == "ok"

      reloaded = Repo.reload!(txn)
      assert reloaded.status == "failed"
      assert reloaded.metadata["error"] == "pending_expired_no_callback"
      assert reloaded.metadata["mpesa_result_code"] == 1

      reloaded_wallet = Repo.reload!(wallet)
      assert Decimal.compare(reloaded_wallet.balance, Decimal.new("0")) == :eq
    end

    test "never completes a genuinely-declined row even if ResultCode is 0", %{
      conn: conn,
      wallet: wallet
    } do
      checkout_id = "ws_genuine_decline_" <> Ecto.UUID.generate()
      txn = pending_mpesa_txn(wallet, checkout_id)

      Repo.update_all(
        from(t in WalletTransaction, where: t.id == ^txn.id),
        set: [status: "failed", metadata: %{"mpesa_result_code" => 1}]
      )

      conn = mpesa_webhook(conn, stk_callback(checkout_id, 0))

      assert response(conn, 200) == "ok"

      reloaded = Repo.reload!(txn)
      assert reloaded.status == "failed"
      assert reloaded.metadata == %{"mpesa_result_code" => 1}

      reloaded_wallet = Repo.reload!(wallet)
      assert Decimal.compare(reloaded_wallet.balance, Decimal.new("0")) == :eq
    end
  end

  describe "create/2 with an unknown or malformed callback" do
    test "responds ok and creates nothing for an unknown CheckoutRequestID", %{conn: conn} do
      conn = mpesa_webhook(conn, stk_callback("does-not-exist", 0))

      assert response(conn, 200) == "ok"
      assert Repo.all(WalletTransaction) == []
    end

    test "responds ignored when CheckoutRequestID is missing", %{conn: conn} do
      conn = mpesa_webhook(conn, %{"Body" => %{"stkCallback" => %{"ResultCode" => 0}}})

      assert response(conn, 200) == "ignored"
      assert Repo.all(WalletTransaction) == []
    end
  end
end
