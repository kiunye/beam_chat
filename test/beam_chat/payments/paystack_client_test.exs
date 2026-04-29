defmodule BeamChat.Payments.PaystackClientTest do
  use ExUnit.Case, async: false

  alias BeamChat.Payments.PaystackClient

  setup do
    prev = Application.get_env(:beam_chat, :paystack, [])
    Application.put_env(:beam_chat, :paystack, Keyword.put(prev, :secret_key, "sk_test_abc"))
    on_exit(fn -> Application.put_env(:beam_chat, :paystack, prev) end)
    :ok
  end

  test "valid_signature?/2 accepts HMAC-SHA512 of body" do
    secret = "sk_test_abc"
    body = ~s({"event":"charge.success"})
    expected = :crypto.mac(:hmac, :sha512, secret, body) |> Base.encode16(case: :lower)

    assert PaystackClient.valid_signature?(body, expected)
    refute PaystackClient.valid_signature?(body, "deadbeef")
  end
end
