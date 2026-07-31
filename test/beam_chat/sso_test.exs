defmodule BeamChat.SSOTest do
  use ExUnit.Case, async: false

  alias BeamChat.SSO

  setup do
    on_exit(fn ->
      Application.delete_env(:beam_chat, :sso_jwt_secrets)
    end)
  end

  defp sign(secret, claims) do
    Joken.Signer.create("HS256", secret)
    |> Joken.generate_and_get!(claims)
  end

  defp with_secrets(secrets, fun) do
    Application.put_env(:beam_chat, :sso_jwt_secrets, secrets)
    fun.()
  end

  describe "verify_shared_secret_jwt/1" do
    test "verifies tokens signed with the legacy single secret" do
      secret = "legacy_sso_secret_min_32_chars_________"

      Application.put_env(:beam_chat, :sso_jwt_secret, secret)
      Application.put_env(:beam_chat, :sso_jwt_secrets, [])

      token = sign(secret, %{"sub" => "user-123", "role" => "member"})
      assert {:ok, claims} = SSO.verify_shared_secret_jwt(token)
      assert claims["sub"] == "user-123"
      assert claims["role"] == "member"
    end

    test "accepts tokens signed by any secret in the rotation list (P2 #19)" do
      current = "current_sso_secret_min_32_chars________"
      previous = "previous_sso_secret_min_32_chars______"

      with_secrets([current, previous], fn ->
        assert {:ok, %{"sub" => "a"}} =
                 SSO.verify_shared_secret_jwt(sign(current, %{"sub" => "a"}))

        assert {:ok, %{"sub" => "b"}} =
                 SSO.verify_shared_secret_jwt(sign(previous, %{"sub" => "b"}))
      end)
    end

    test "rejects tokens signed with an unknown secret" do
      with_secrets(["current_sso_secret_min_32_chars________"], fn ->
        token = sign("unknown_sso_secret_min_32_chars_______", %{"sub" => "x"})
        assert {:error, :invalid_token} = SSO.verify_shared_secret_jwt(token)
      end)
    end

    test "rejects tokens without a sub claim" do
      secret = "current_sso_secret_min_32_chars________"

      with_secrets([secret], fn ->
        token = sign(secret, %{"role" => "admin"})
        assert {:error, :missing_sub} = SSO.verify_shared_secret_jwt(token)
      end)
    end

    test "coerces non-string sub claims to strings" do
      secret = "current_sso_secret_min_32_chars________"

      with_secrets([secret], fn ->
        token = sign(secret, %{"sub" => 42})
        assert {:ok, %{"sub" => "42"}} = SSO.verify_shared_secret_jwt(token)
      end)
    end
  end
end
