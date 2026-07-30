defmodule BeamChat.AccountsTest do
  use BeamChat.DataCase, async: true

  import BeamChat.TestFixtures
  import Ecto.Query

  alias BeamChat.Accounts

  describe "ban_user/2" do
    test "sets is_banned and clears all session tokens in a single transaction" do
      user = registered_user_fixture()
      raw = Accounts.generate_user_session_token(user)

      assert {:ok, banned} = Accounts.ban_user(user, "spam")
      assert banned.is_banned == true
      assert banned.ban_reason == "spam"

      # The persisted row reflects the ban.
      reloaded = Accounts.get_user(user.id)
      assert reloaded.is_banned == true
      assert reloaded.ban_reason == "spam"

      # The previously valid session token no longer resolves.
      assert Accounts.get_user_by_session_token(raw) == nil
    end

    test "banning twice is idempotent and still returns ok" do
      user = registered_user_fixture()
      assert {:ok, _} = Accounts.ban_user(user)
      assert {:ok, _} = Accounts.ban_user(user, "again")
    end

    test "ban with a nil reason is allowed" do
      user = registered_user_fixture()
      assert {:ok, banned} = Accounts.ban_user(user, nil)
      assert banned.is_banned == true
      assert banned.ban_reason == nil
    end

    test "magic link tokens are also invalidated by ban" do
      user = registered_user_fixture()
      assert :ok = Accounts.deliver_magic_link_instructions(user.email)

      assert {:ok, _} = Accounts.ban_user(user)

      # No token rows remain for this user, regardless of context.
      remaining = Repo.all(from t in BeamChat.Accounts.UserToken, where: t.user_id == ^user.id)
      assert remaining == []
    end
  end

  describe "unban_user/1" do
    test "clears the ban flag" do
      user = registered_user_fixture()
      {:ok, _} = Accounts.ban_user(user, "abuse")

      assert {:ok, unbanned} = Accounts.unban_user(user)
      assert unbanned.is_banned == false
      assert unbanned.ban_reason == nil
    end

    test "does not resurrect old session tokens — user must re-authenticate" do
      user = registered_user_fixture()
      raw = Accounts.generate_user_session_token(user)
      {:ok, _} = Accounts.ban_user(user)

      # Token is gone after ban.
      assert Accounts.get_user_by_session_token(raw) == nil

      # Unban does not magically restore it.
      {:ok, _} = Accounts.unban_user(user)
      assert Accounts.get_user_by_session_token(raw) == nil
    end

    test "returns error for unknown user id" do
      assert {:error, :not_found} =
               Accounts.unban_user(%BeamChat.Accounts.User{id: Ecto.UUID.generate()})
    end
  end
end
