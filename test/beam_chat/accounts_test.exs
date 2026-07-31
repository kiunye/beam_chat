defmodule BeamChat.AccountsTest do
  use BeamChat.DataCase, async: true

  import BeamChat.TestFixtures
  import Ecto.Query

  alias BeamChat.Accounts
  alias BeamChat.Accounts.User

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
               Accounts.unban_user(%User{id: Ecto.UUID.generate()})
    end
  end

  describe "reserved_username?/1" do
    test "matches the default blocklist case-insensitively" do
      assert Accounts.reserved_username?("admin")
      assert Accounts.reserved_username?("ADMIN")
      assert Accounts.reserved_username?("Admin")
      assert Accounts.reserved_username?(" beam_chat ")
      assert Accounts.reserved_username?("staff")
      assert Accounts.reserved_username?("moderator")
    end

    test "returns false for ordinary usernames" do
      refute Accounts.reserved_username?("chris")
      refute Accounts.reserved_username?("alice_42")
      refute Accounts.reserved_username?("normal_user")
    end

    test "returns false for non-binary input" do
      refute Accounts.reserved_username?(nil)
      refute Accounts.reserved_username?(123)
      refute Accounts.reserved_username?(%{})
    end

    test "reflects runtime overrides to :reserved_usernames" do
      original = Application.get_env(:beam_chat, :reserved_usernames, [])

      try do
        Application.put_env(:beam_chat, :reserved_usernames, ["custom_reserved_xyz"])

        assert Accounts.reserved_username?("custom_reserved_xyz")
        refute Accounts.reserved_username?("admin")
      after
        Application.put_env(:beam_chat, :reserved_usernames, original)
      end
    end
  end

  describe "registration changeset reserved-username guard" do
    test "rejects a reserved username at the changeset level" do
      changeset =
        User.registration_changeset(%User{}, %{
          username: "admin",
          email: "x@example.com",
          password: "password12"
        })

      refute changeset.valid?
      assert %{username: ["is reserved and cannot be used"]} = errors_on(changeset)
    end

    test "is case-insensitive and ignores leading whitespace" do
      changeset =
        User.registration_changeset(%User{}, %{
          username: "  ADMIN  ",
          email: "x@example.com",
          password: "password12"
        })

      refute changeset.valid?
    end

    test "accepts an ordinary username" do
      changeset =
        User.registration_changeset(%User{}, %{
          username: "alice_42",
          email: "x@example.com",
          password: "password12"
        })

      assert changeset.valid?
    end
  end

  describe "OAuth username generation avoids reserved names" do
    test "an OAuth display name that would yield a reserved handle is suffixed" do
      # `Admin Support` -> sanitised `admin_support` -> candidate `admin_support_<hex>`.
      # Because the sanitised `admin_support` is also a reserved-root, the candidate
      # itself collides with the blocklist and we append a numeric suffix.
      claims = %{"sub" => "12345", "email" => "x@example.com", "name" => "Admin Support"}

      assert {:ok, user} = Accounts.register_or_update_oauth_user("google", claims)

      refute Accounts.reserved_username?(user.username)
      assert String.starts_with?(user.username, "admin_support_")
    end

    test "a non-reserving display name is passed through unchanged" do
      claims = %{"sub" => "67890", "email" => "y@example.com", "name" => "Alice Walker"}

      assert {:ok, user} = Accounts.register_or_update_oauth_user("github", claims)

      assert String.starts_with?(user.username, "alice_walker_")
      refute Accounts.reserved_username?(user.username)
    end
  end
end
