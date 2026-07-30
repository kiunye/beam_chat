defmodule BeamChatWeb.Plugs.MpesaWebhookAuthTest do
  use BeamChatWeb.ConnCase, async: true

  alias BeamChatWeb.Plugs.MpesaWebhookAuth

  # The plug's default behaviour is to bypass enforcement in dev/test.
  # Tests set `Application.put_env(:beam_chat, :mpesa_webhook_enforce, true)`
  # to exercise the prod path; on_exit/1 restores the original config.

  describe "default (bypass) behaviour" do
    test "lets any request through in dev/test env" do
      conn =
        :post
        |> build_conn("/webhooks/mpesa/anything", %{})
        |> Map.put(:params, %{"secret" => "anything"})
        |> MpesaWebhookAuth.call([])

      refute conn.halted
      refute conn.assigns[:mpesa_webhook_verified]
    end
  end

  describe "enforced (prod-like) mode" do
    setup do
      original_mpesa = Application.get_env(:beam_chat, :mpesa, [])
      original_enforce = Application.get_env(:beam_chat, :mpesa_webhook_enforce)

      Application.put_env(:beam_chat, :mpesa_webhook_enforce, true)

      on_exit(fn ->
        Application.put_env(:beam_chat, :mpesa, original_mpesa)
        Application.put_env(:beam_chat, :mpesa_webhook_enforce, original_enforce)
      end)

      :ok
    end

    test "rejects with 403 when configured secret is empty (fail-closed)" do
      Application.put_env(:beam_chat, :mpesa, callback_secret: "")

      conn =
        :post
        |> build_conn("/webhooks/mpesa/anything", %{})
        |> Map.put(:params, %{"secret" => "anything"})
        |> MpesaWebhookAuth.call([])

      assert conn.status == 403
      assert conn.halted
      assert conn.resp_body =~ "missing_config"
    end

    test "rejects with 403 when path secret does not match" do
      Application.put_env(:beam_chat, :mpesa, callback_secret: "configured-secret")

      conn =
        :post
        |> build_conn("/webhooks/mpesa/wrong", %{})
        |> Map.put(:params, %{"secret" => "wrong"})
        |> MpesaWebhookAuth.call([])

      assert conn.status == 403
      assert conn.halted
      assert conn.resp_body =~ "mismatch"
    end

    test "rejects with 403 when path secret is missing" do
      Application.put_env(:beam_chat, :mpesa, callback_secret: "configured-secret")

      conn =
        :post
        |> build_conn("/webhooks/mpesa", %{})
        |> Map.put(:params, %{})
        |> MpesaWebhookAuth.call([])

      assert conn.status == 403
      assert conn.halted
      assert conn.resp_body =~ "missing_path_secret"
    end

    test "lets the request through when secrets match" do
      Application.put_env(:beam_chat, :mpesa, callback_secret: "configured-secret")

      conn =
        :post
        |> build_conn("/webhooks/mpesa/configured-secret", %{})
        |> Map.put(:params, %{"secret" => "configured-secret"})
        |> MpesaWebhookAuth.call([])

      refute conn.halted
      assert conn.assigns[:mpesa_webhook_verified] == true
      # Secret is stripped from params so downstream controllers don't log it.
      refute Map.has_key?(conn.params, "secret")
    end

    test "uses constant-time comparison (no early-return on prefix match)" do
      # Trivially: the plug delegates to Plug.Crypto.secure_compare/2, which
      # is itself constant-time. We assert that a longer secret with the
      # correct prefix is still rejected.
      Application.put_env(:beam_chat, :mpesa, callback_secret: "abc123")

      conn =
        :post
        |> build_conn("/webhooks/mpesa/abc123-extra", %{})
        |> Map.put(:params, %{"secret" => "abc123-extra"})
        |> MpesaWebhookAuth.call([])

      assert conn.status == 403
      assert conn.halted
    end
  end
end
