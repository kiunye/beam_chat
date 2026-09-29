defmodule BeamChat.PaymentsTest do
  use BeamChat.DataCase, async: false

  alias BeamChat.Payments
  alias BeamChat.Payments.ConfigCrypto
  alias BeamChat.Payments.PaymentProviderConfig
  alias BeamChat.Payments.Providers.Mpesa
  alias BeamChat.Payments.Providers.Paystack
  alias BeamChat.Repo
  alias BeamChat.Wallet

  import BeamChat.TestFixtures

  @paystack_creds %{"secret_key" => "sk_test_123", "base_url" => "https://api.paystack.co"}

  setup do
    # Clean slate for provider config rows between tests (this file is not async).
    Repo.delete_all(PaymentProviderConfig)
    :ok
  end

  defp stub_paystack! do
    stub = Module.concat(__MODULE__, PaystackStub)
    original = Application.get_env(:req, :default_options)

    Req.Test.stub(stub, fn conn ->
      Req.Test.json(conn, %{
        "status" => true,
        "data" => %{"authorization_url" => "https://paystack.test/checkout/abc"}
      })
    end)

    Application.put_env(:req, :default_options, plug: {Req.Test, stub})

    on_exit(fn ->
      if original do
        Application.put_env(:req, :default_options, original)
      else
        Application.delete_env(:req, :default_options)
      end
    end)
  end

  describe "facade structure" do
    test "provider_modules/0 returns paystack and mpesa keyed by string" do
      modules = Payments.provider_modules()
      assert modules["paystack"] == Paystack
      assert modules["mpesa"] == Mpesa
      assert map_size(modules) == 2
    end

    test "configurable_providers/0 lists paystack, mpesa, and stripe" do
      providers = Payments.configurable_providers()
      assert "paystack" in providers
      assert "mpesa" in providers
      assert "stripe" in providers
    end

    test "provider_module/1 resolves known keys and nil for anything else" do
      assert Payments.provider_module("paystack") == Paystack
      assert Payments.provider_module("mpesa") == Mpesa
      assert Payments.provider_module("stripe") == nil
      assert Payments.provider_module("bogus") == nil
    end
  end

  describe "provider config lifecycle" do
    test "update_provider_config stores encrypted credentials and enables the provider" do
      assert {:ok, %PaymentProviderConfig{} = config} =
               Payments.update_provider_config("paystack", %{
                 is_enabled: true,
                 credentials: @paystack_creds
               })

      assert config.is_enabled == true
      assert %DateTime{} = config.credentials_set_at

      stored = Payments.get_config("paystack")
      assert stored.is_enabled == true
      # Stored blob is encrypted, not plaintext
      refute stored.credentials =~ "sk_test_123"
      assert String.starts_with?(stored.credentials, "v1.")

      assert Payments.fetch_credentials("paystack") == @paystack_creds
    end

    test "re-saving with only is_enabled: false keeps existing credentials" do
      provider_config_fixture("paystack", credentials: @paystack_creds)

      assert {:ok, config} =
               Payments.update_provider_config("paystack", %{is_enabled: false})

      assert config.is_enabled == false
      assert Payments.fetch_credentials("paystack") == @paystack_creds
      assert Payments.enabled?("paystack") == false
    end

    test "re-saving with new credentials replaces the blob" do
      provider_config_fixture("paystack", credentials: @paystack_creds)

      new_creds = %{"secret_key" => "sk_live_456", "base_url" => "https://api.paystack.co"}

      assert {:ok, _config} =
               Payments.update_provider_config("paystack", %{
                 is_enabled: true,
                 credentials: new_creds
               })

      assert Payments.fetch_credentials("paystack") == new_creds
    end

    test "update_provider_config rejects a bogus provider key" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Payments.update_provider_config("bogus", %{is_enabled: true})

      error_fields = for {field, {_msg, _opts}} <- changeset.errors, do: field
      assert :provider in error_fields
    end
  end

  describe "ConfigCrypto" do
    test "encrypt/1 produces a v1.<base64> blob that decrypts to string keys" do
      blob = ConfigCrypto.encrypt(%{"nested" => "x", secret_key: "sk"})
      assert String.starts_with?(blob, "v1.")

      [_version, encoded] = String.split(blob, ".", parts: 2)
      assert {:ok, _} = Base.decode64(encoded, padding: false)

      assert {:ok, %{"secret_key" => "sk", "nested" => "x"}} = ConfigCrypto.decrypt(blob)
    end

    test "decrypt/1 of a truncated blob fails cleanly" do
      blob = ConfigCrypto.encrypt(%{"secret_key" => "sk"})
      truncated = binary_part(blob, 0, div(byte_size(blob), 2))

      assert {:error, :decrypt_failed} = ConfigCrypto.decrypt(truncated)
    end

    test "decrypt/1 with a different passphrase fails" do
      original = Application.get_env(:beam_chat, :config_encryption_key)

      blob = ConfigCrypto.encrypt(%{"secret_key" => "sk"})

      on_exit(fn ->
        if original do
          Application.put_env(:beam_chat, :config_encryption_key, original)
        else
          Application.delete_env(:beam_chat, :config_encryption_key)
        end
      end)

      Application.put_env(:beam_chat, :config_encryption_key, "other-secret-32-chars-min-xxxxx")
      assert {:error, :decrypt_failed} = ConfigCrypto.decrypt(blob)
    end
  end

  describe "facade dispatch" do
    test "enabled?/1 is false with no row, false for a disabled row, true when enabled" do
      assert Payments.enabled?("paystack") == false

      provider_config_fixture("paystack", is_enabled: false)
      assert Payments.enabled?("paystack") == false

      provider_config_fixture("paystack", is_enabled: true)
      assert Payments.enabled?("paystack") == true
    end

    test "mpesa_callback_secret/0 is nil until enabled and configured with a secret" do
      assert Payments.mpesa_callback_secret() == nil

      # Enabled but no credentials at all
      provider_config_fixture("mpesa", is_enabled: true)
      assert Payments.mpesa_callback_secret() == nil

      # Configured with the secret
      provider_config_fixture("mpesa",
        is_enabled: true,
        credentials: %{"callback_secret" => "s3cret"}
      )

      assert Payments.mpesa_callback_secret() == "s3cret"

      # Disabled again — the door closes
      Payments.update_provider_config("mpesa", %{is_enabled: false})
      assert Payments.mpesa_callback_secret() == nil
    end

    test "initiate_topup via paystack succeeds when enabled and configured" do
      stub_paystack!()
      user = user_fixture()
      provider_config_fixture("paystack", credentials: @paystack_creds)

      assert {:ok, %{transaction: txn, redirect_url: redirect_url}} =
               Payments.initiate_topup("paystack", user, Decimal.new("100.00"),
                 callback_url: "https://x/y"
               )

      assert redirect_url == "https://paystack.test/checkout/abc"
      assert txn.id
      assert txn.status == "pending"
      assert txn.provider == "paystack"
      assert is_binary(txn.provider_reference)

      # The pending row is committed and resolvable by its provider reference
      assert Wallet.get_by_provider_reference(txn.provider_reference).id == txn.id
    end

    test "initiate_topup fails when the provider is not configured" do
      stub_paystack!()
      user = user_fixture()

      # Enabled row, but no credentials on file → provider reports unconfigured
      provider_config_fixture("paystack", is_enabled: true)

      assert {:error, :provider_not_configured} =
               Payments.initiate_topup("paystack", user, Decimal.new("100.00"),
                 callback_url: "https://x/y"
               )
    end

    test "initiate_topup with an unregistered provider key returns :unknown_provider" do
      user = user_fixture()

      assert {:error, :unknown_provider} =
               Payments.initiate_topup("stripe", user, Decimal.new("100.00"))

      assert {:error, :unknown_provider} =
               Payments.initiate_topup("bogus", user, Decimal.new("100.00"))
    end

    test "initiate_topup fails when the provider is disabled" do
      user = user_fixture()
      provider_config_fixture("paystack", is_enabled: false, credentials: @paystack_creds)

      assert {:error, :provider_disabled} =
               Payments.initiate_topup("paystack", user, Decimal.new("100.00"),
                 callback_url: "https://x/y"
               )
    end
  end

  describe "provider confirm flows" do
    test "paystack confirm_topup with a bogus reference is rejected, not a crash" do
      payload = %{
        "reference" => "no-such-ref",
        "status" => "success",
        "amount" => 10_000,
        "currency" => "KES"
      }

      assert {:error, :unknown_reference} = Payments.confirm_topup("paystack", payload)
    end

    test "mpesa confirm_topup with a successful callback completes the pending row" do
      user = user_fixture()
      reference = "ws_CO_#{System.unique_integer([:positive])}"
      pending = pending_topup_fixture(user, Decimal.new("100.00"), "mpesa", reference)

      payload = %{
        "Body" => %{
          "stkCallback" => %{
            "CheckoutRequestID" => reference,
            "ResultCode" => 0,
            "ResultDesc" => "The service request is processed successfully.",
            "CallbackMetadata" => %{
              "Item" => [
                %{"Name" => "Amount", "Value" => 100},
                %{"Name" => "MpesaReceiptNumber", "Value" => "ABC123"}
              ]
            }
          }
        }
      }

      assert {:ok, completed} = Payments.confirm_topup("mpesa", payload)
      assert completed.id == pending.id
      assert completed.status == "completed"

      # The pending row is cleared — no longer pending in the database
      assert Repo.get(BeamChat.Wallet.WalletTransaction, pending.id).status == "completed"
    end

    test "mpesa confirm_topup with an unknown reference is rejected" do
      payload = %{
        "Body" => %{
          "stkCallback" => %{
            "CheckoutRequestID" => "ws_CO_bogus",
            "ResultCode" => 0,
            "ResultDesc" => "ok"
          }
        }
      }

      assert {:error, :unknown_reference} = Payments.confirm_topup("mpesa", payload)
    end
  end
end
