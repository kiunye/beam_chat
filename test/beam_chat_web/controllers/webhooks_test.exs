defmodule BeamChatWeb.WebhooksTest do
  @moduledoc """
  End-to-end coverage for the payment webhook surface:

    * `POST /webhooks/paystack`  — HMAC-SHA512-verified charge.success events
      credit the wallet exactly once.
    * `POST /webhooks/mpesa/:secret` — Daraja STK callbacks gated by the
      path-secret plug (enforcement forced on via
      `:mpesa_webhook_enforce` in these tests).
  """

  use BeamChatWeb.ConnCase, async: false

  alias BeamChat.Wallet

  @paystack_secret "sk_test_demo"

  # -- Helpers ------------------------------------------------------------------

  defp paystack_signature(body, secret) do
    :crypto.mac(:hmac, :sha512, secret, body) |> Base.encode16(case: :lower)
  end

  defp paystack_body(reference, amount_major) do
    Jason.encode!(%{
      "event" => "charge.success",
      "data" => %{
        "reference" => reference,
        # Paystack reports subunits (kobo/cents).
        "amount" => Decimal.mult(amount_major, 100) |> Decimal.round(0) |> Decimal.to_integer(),
        "status" => "success"
      }
    })
  end

  defp post_paystack(conn, body, signature) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-paystack-signature", signature)
    |> post("/webhooks/paystack", body)
  end

  defp mpesa_body(checkout_id, amount, result_code \\ 0) do
    callback = %{
      "CheckoutRequestID" => checkout_id,
      "ResultCode" => result_code,
      "ResultDesc" => if(result_code == 0, do: "ok", else: "failed")
    }

    callback =
      if result_code == 0 do
        Map.put(callback, "CallbackMetadata", %{
          # Amount is reported in major units (KES).
          "Item" => [
            %{"Name" => "Amount", "Value" => Decimal.to_integer(amount)},
            %{"Name" => "MpesaReceiptNumber", "Value" => "RCPT-#{checkout_id}"}
          ]
        })
      else
        callback
      end

    Jason.encode!(%{"Body" => %{"stkCallback" => callback}})
  end

  defp post_mpesa(conn, secret, body) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post("/webhooks/mpesa/#{secret}", body)
  end

  defp balance_of(user) do
    user.id
    |> Wallet.get_wallet_for_user()
    |> Map.fetch!(:balance)
  end

  defp setup_paystack(_context) do
    provider_config_fixture("paystack", %{
      credentials: %{"secret_key" => @paystack_secret, "base_url" => "https://api.paystack.co"}
    })

    on_exit(fn ->
      {:ok, _} =
        BeamChat.Payments.update_provider_config("paystack", %{is_enabled: false})

      :ok
    end)

    :ok
  end

  defp setup_mpesa(_context) do
    provider_config_fixture("mpesa", %{
      credentials: %{"callback_secret" => "sec-webhook", "shortcode" => "123456"}
    })

    Application.put_env(:beam_chat, :mpesa_webhook_enforce, true)

    on_exit(fn ->
      Application.delete_env(:beam_chat, :mpesa_webhook_enforce)

      {:ok, _} =
        BeamChat.Payments.update_provider_config("mpesa", %{is_enabled: false})

      :ok
    end)

    :ok
  end

  # -- Paystack -----------------------------------------------------------------

  describe "POST /webhooks/paystack" do
    setup :setup_paystack

    test "valid charge.success credits the wallet once", %{conn: conn} do
      user = user_fixture()
      wallet_fixture(user)
      amount = Decimal.new("250")
      reference = Ecto.UUID.generate()
      _txn = pending_topup_fixture(user, amount, "paystack", reference)

      body = paystack_body(reference, amount)
      conn = post_paystack(conn, body, paystack_signature(body, @paystack_secret))

      assert response(conn, 200) == "ok"
      assert Decimal.equal?(balance_of(user), amount)

      txn = Wallet.get_by_provider_reference(reference)
      assert txn.status == "completed"
    end

    test "invalid signature is rejected with 401", %{conn: conn} do
      user = user_fixture()
      wallet_fixture(user)
      amount = Decimal.new("250")
      reference = Ecto.UUID.generate()
      pending_topup_fixture(user, amount, "paystack", reference)

      body = paystack_body(reference, amount)
      conn = post_paystack(conn, body, "deadbeef")

      assert response(conn, 401) == "invalid signature"
      assert Decimal.equal?(balance_of(user), Decimal.new("0"))
    end

    test "replayed callback does not double-credit", %{conn: conn} do
      user = user_fixture()
      wallet_fixture(user)
      amount = Decimal.new("250")
      reference = Ecto.UUID.generate()
      pending_topup_fixture(user, amount, "paystack", reference)

      body = paystack_body(reference, amount)
      signature = paystack_signature(body, @paystack_secret)

      conn = post_paystack(conn, body, signature)
      assert response(conn, 200) == "ok"

      conn2 =
        build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("x-paystack-signature", signature)
        |> post("/webhooks/paystack", body)

      assert response(conn2, 200)
      assert Decimal.equal?(balance_of(user), amount)
    end

    test "unknown pending reference returns 200 without crediting", %{conn: conn} do
      user = user_fixture()
      wallet_fixture(user)
      amount = Decimal.new("250")

      body = paystack_body("PSK-unknown-reference", amount)
      conn = post_paystack(conn, body, paystack_signature(body, @paystack_secret))

      assert response(conn, 200)
      assert Decimal.equal?(balance_of(user), Decimal.new("0"))
    end
  end

  # -- M-Pesa -------------------------------------------------------------------

  describe "POST /webhooks/mpesa/:secret" do
    setup :setup_mpesa

    test "valid STK callback credits the wallet", %{conn: conn} do
      user = user_fixture()
      wallet_fixture(user)
      amount = Decimal.new("300")
      checkout_id = "ws_CO_#{System.unique_integer([:positive])}"
      pending_topup_fixture(user, amount, "mpesa", checkout_id)

      conn = post_mpesa(conn, "sec-webhook", mpesa_body(checkout_id, amount))

      assert response(conn, 200) == "ok"
      assert Decimal.equal?(balance_of(user), amount)

      txn = Wallet.get_by_provider_reference(checkout_id)
      assert txn.status == "completed"
      assert txn.metadata["receipt"] == "RCPT-#{checkout_id}"
    end

    test "wrong path secret is rejected with 403", %{conn: conn} do
      user = user_fixture()
      wallet_fixture(user)
      amount = Decimal.new("300")
      checkout_id = "ws_CO_#{System.unique_integer([:positive])}"
      pending_topup_fixture(user, amount, "mpesa", checkout_id)

      conn = post_mpesa(conn, "wrong-secret", mpesa_body(checkout_id, amount))

      assert response(conn, 403) =~ "forbidden"
      assert Decimal.equal?(balance_of(user), Decimal.new("0"))
      assert Wallet.get_by_provider_reference(checkout_id).status == "pending"
    end

    test "missing configured callback_secret fails closed with 403", %{conn: conn} do
      # Replace credentials with a blob that has no callback_secret.
      provider_config_fixture("mpesa", %{
        credentials: %{"shortcode" => "123456"}
      })

      user = user_fixture()
      wallet_fixture(user)
      amount = Decimal.new("300")
      checkout_id = "ws_CO_#{System.unique_integer([:positive])}"
      pending_topup_fixture(user, amount, "mpesa", checkout_id)

      conn = post_mpesa(conn, "any-secret", mpesa_body(checkout_id, amount))

      assert response(conn, 403) =~ "missing_config"
      assert Decimal.equal?(balance_of(user), Decimal.new("0"))
    end

    test "non-zero ResultCode finalizes the pending row as failed without crediting",
         %{conn: conn} do
      user = user_fixture()
      wallet_fixture(user)
      amount = Decimal.new("300")
      checkout_id = "ws_CO_#{System.unique_integer([:positive])}"
      pending_topup_fixture(user, amount, "mpesa", checkout_id)

      conn = post_mpesa(conn, "sec-webhook", mpesa_body(checkout_id, amount, 1))

      assert response(conn, 200) == "ok"
      assert Decimal.equal?(balance_of(user), Decimal.new("0"))
      assert Wallet.get_by_provider_reference(checkout_id).status == "failed"
    end
  end
end
