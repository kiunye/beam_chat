defmodule BeamChatWeb.Plugs.MpesaWebhookAuth do
  @moduledoc """
  Authenticates inbound M-Pesa STK callbacks.

  Safaricom's Daraja API does not sign callbacks (unlike Paystack's HMAC).
  The simplest reliable defence is to **embed a shared secret in the callback
  URL path** — e.g. `https://example.com/webhooks/mpesa/<secret>` — and have
  the operator configure the same secret via `MPESA_CALLBACK_SECRET`. Daraja
  preserves the configured URL verbatim, so the secret segment reaches us
  untouched.

  ## Failure modes

  | Env            | Configured secret | Result                                |
  |----------------|-------------------|---------------------------------------|
  | `dev` / `test` | (any)             | Always allowed (no enforcement)       |
  | `prod`         | `""` or `nil`     | `403` — **fail closed**                |
  | `prod`         | `<configured>`    | `403` unless path secret matches      |

  Fail-closed in prod is intentional: an unauthenticated webhook paying real
  money into real wallets is unacceptable, and operator misconfiguration is
  exactly the risk we're protecting against. See `SECURITY_REVIEW.md` P0 #3.

  ## Forcing enforcement in tests

  Tests can opt into the prod code path by setting
  `Application.put_env(:beam_chat, :mpesa_webhook_enforce, true)`. This is the
  only mechanism that flips the bypass off regardless of `Mix.env/0`, and is
  read on every request — safe to set per-test with `on_exit/1` cleanup.
  """

  @behaviour Plug

  import Plug.Conn

  alias Plug.Crypto

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if bypass_enforcement?() do
      conn
    else
      verify_secret(conn)
    end
  end

  # In dev/test, the webhook is open by default — matches the existing dev
  # ergonomics and lets the existing test suite run without secret config.
  # Production never sets `:mpesa_webhook_enforce`, so we always fall through
  # to `verify_secret/1`.
  #
  # Tests that want to exercise the verify path set
  # `Application.put_env(:beam_chat, :mpesa_webhook_enforce, true)` — which
  # *disables* the bypass (i.e. enforces). The name reads as "enforce?" from
  # the prod perspective; here we use `bypass_enforcement?/0` so the logic
  # stays in plain English at the call site.
  defp bypass_enforcement? do
    cond do
      Application.get_env(:beam_chat, :mpesa_webhook_enforce, false) == true ->
        # Test/prod is forcing enforcement — bypass is OFF.
        false

      Mix.env() in [:dev, :test] ->
        true

      true ->
        false
    end
  end

  defp verify_secret(conn) do
    configured = configured_secret()

    cond do
      configured in ["", nil] ->
        # Fail closed in prod.
        reject(conn, :missing_config)

      not is_binary(conn.params["secret"]) ->
        reject(conn, :missing_path_secret)

      not Crypto.secure_compare(configured, conn.params["secret"]) ->
        reject(conn, :mismatch)

      true ->
        # Strip the secret from the path so downstream code doesn't log it.
        conn
        |> delete_param("secret")
        |> assign(:mpesa_webhook_verified, true)
    end
  end

  defp configured_secret do
    Application.get_env(:beam_chat, :mpesa, [])
    |> Keyword.get(:callback_secret, "")
    |> to_string()
  end

  defp reject(conn, reason) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "forbidden: #{reason}")
    |> halt()
  end

  # Deletes a param from the conn without re-triggering Plug.Parsers.
  # `conn.params` is a map; rewriting it on a GET-style path param is safe.
  defp delete_param(conn, key) do
    %{conn | params: Map.delete(conn.params, key)}
  end
end
