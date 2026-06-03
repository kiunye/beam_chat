defmodule BeamChat.Video.TokenServiceTest do
  use ExUnit.Case, async: true

  alias BeamChat.Accounts.User
  alias BeamChat.Video.TokenService

  @moduletag :livekit

  setup do
    # Make sure dev defaults are applied in test env so tokens can be issued.
    original_key = Application.get_env(:livekit, :api_key)
    original_secret = Application.get_env(:livekit, :api_secret)
    original_url = Application.get_env(:livekit, :url)

    Application.put_env(:livekit, :api_key, "test_api_key_xxxxxxxxxxxxxxxxxxxxxx")
    Application.put_env(:livekit, :api_secret, "test_api_secret_xxxxxxxxxxxxxxxxxxxxxxxxxxxx")
    Application.put_env(:livekit, :url, "ws://test.livekit.local")

    on_exit(fn ->
      Application.put_env(:livekit, :api_key, original_key)
      Application.put_env(:livekit, :api_secret, original_secret)
      Application.put_env(:livekit, :url, original_url)
    end)

    :ok
  end

  describe "generate_token/2" do
    test "returns a payload with token, url, identity, name, room" do
      user = %User{id: "11111111-1111-1111-1111-111111111111", username: "alice"}
      room_id = "22222222-2222-2222-2222-222222222222"

      assert {:ok, payload} = TokenService.generate_token(user, room_id)

      assert is_binary(payload.token)
      assert payload.url == "ws://test.livekit.local"
      assert payload.identity == "user-11111111-1111-1111-1111-111111111111"
      assert payload.room == room_id
      assert payload.name == "alice"
    end

    test "token is a three-part JWT" do
      user = %User{id: "11111111-1111-1111-1111-111111111111", username: "alice"}
      room_id = "22222222-2222-2222-2222-222222222222"

      {:ok, %{token: jwt}} = TokenService.generate_token(user, room_id)

      assert length(String.split(jwt, ".")) == 3
    end

    test "token claims contain expected room and identity" do
      user = %User{id: "11111111-1111-1111-1111-111111111111", username: "alice"}
      room_id = "22222222-2222-2222-2222-222222222222"

      {:ok, %{token: jwt}} = TokenService.generate_token(user, room_id)
      {:ok, claims} = TokenService.verify_token(jwt)

      assert claims["sub"] == "user-11111111-1111-1111-1111-111111111111"
      assert get_in(claims, ["video", "room"]) == room_id
      assert get_in(claims, ["video", "roomJoin"]) == true
      assert get_in(claims, ["video", "canPublish"]) == true
      assert get_in(claims, ["video", "canSubscribe"]) == true
    end

    test "token has 1h TTL by default" do
      user = %User{id: "11111111-1111-1111-1111-111111111111", username: "alice"}
      room_id = "22222222-2222-2222-2222-222222222222"

      {:ok, %{token: jwt}} = TokenService.generate_token(user, room_id)
      {:ok, claims} = TokenService.verify_token(jwt)

      exp = claims["exp"]
      iat = claims["iat"]
      assert is_integer(exp) and is_integer(iat)
      # 3600s default; allow ±5s for clock skew.
      assert_in_delta exp - iat, 3_600, 5
    end

    test "honours custom ttl option" do
      user = %User{id: "11111111-1111-1111-1111-111111111111", username: "alice"}
      room_id = "22222222-2222-2222-2222-222222222222"

      {:ok, %{token: jwt}} = TokenService.generate_token(user, room_id, ttl: 120)
      {:ok, claims} = TokenService.verify_token(jwt)

      assert_in_delta claims["exp"] - claims["iat"], 120, 5
    end

    test "uses full_name as display name when present" do
      user = %User{
        id: "11111111-1111-1111-1111-111111111111",
        username: "alice",
        full_name: "Alice Smith"
      }

      room_id = "22222222-2222-2222-2222-222222222222"
      {:ok, payload} = TokenService.generate_token(user, room_id)
      assert payload.name == "Alice Smith"
    end

    test "falls back to username when full_name is blank" do
      user = %User{id: "11111111-1111-1111-1111-111111111111", username: "alice", full_name: nil}

      room_id = "22222222-2222-2222-2222-222222222222"
      {:ok, payload} = TokenService.generate_token(user, room_id)
      assert payload.name == "alice"
    end

    test "identity is derived from user id and contains no PII" do
      user = %User{id: "abcdef00-0000-0000-0000-000000000001", username: "alice"}
      assert TokenService.identity(user) == "user-abcdef00-0000-0000-0000-000000000001"
    end

    test "returns :not_configured when livekit api_key is missing" do
      Application.put_env(:livekit, :api_key, "")
      user = %User{id: "11111111-1111-1111-1111-111111111111", username: "alice"}
      room_id = "22222222-2222-2222-2222-222222222222"

      assert {:error, :not_configured} = TokenService.generate_token(user, room_id)
    end

    test "returns :not_configured when livekit api_secret is missing" do
      Application.put_env(:livekit, :api_secret, "")
      user = %User{id: "11111111-1111-1111-1111-111111111111", username: "alice"}
      room_id = "22222222-2222-2222-2222-222222222222"

      assert {:error, :not_configured} = TokenService.generate_token(user, room_id)
    end

    test "returns :not_configured when livekit url is missing" do
      Application.put_env(:livekit, :url, "")
      user = %User{id: "11111111-1111-1111-1111-111111111111", username: "alice"}
      room_id = "22222222-2222-2222-2222-222222222222"

      assert {:error, :not_configured} = TokenService.generate_token(user, room_id)
    end
  end

  describe "verify_token/1" do
    test "round-trips a generated token" do
      user = %User{id: "11111111-1111-1111-1111-111111111111", username: "alice"}
      room_id = "22222222-2222-2222-2222-222222222222"

      {:ok, %{token: jwt}} = TokenService.generate_token(user, room_id)
      assert {:ok, _claims} = TokenService.verify_token(jwt)
    end

    test "rejects a tampered token" do
      user = %User{id: "11111111-1111-1111-1111-111111111111", username: "alice"}
      room_id = "22222222-2222-2222-2222-222222222222"

      {:ok, %{token: jwt}} = TokenService.generate_token(user, room_id)
      tampered = String.replace_suffix(jwt, "a", "b")
      assert {:error, _} = TokenService.verify_token(tampered)
    end
  end
end
