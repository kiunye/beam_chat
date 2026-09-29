defmodule BeamChat.AccountsTest do
  @moduledoc """
  Registration, credentials, magic links, session tokens, banning, global
  role changes, and the bootstrap-admin promotion (PRD §2.1, §2.2).
  """

  use BeamChat.DataCase, async: false

  alias BeamChat.Accounts
  alias BeamChat.Accounts.User
  alias BeamChat.Accounts.UserToken
  alias BeamChat.Moderation.ModerationLog

  setup do
    # Registration fixtures hash passwords with bcrypt; keep the suite fast.
    # Restored in on_exit so nothing else observes the tweaked cost.
    Application.put_env(:bcrypt_elixir, :log_rounds, 1)

    on_exit(fn -> Application.delete_env(:bcrypt_elixir, :log_rounds) end)

    :ok
  end

  describe "register_user/1" do
    test "creates a member with valid attributes" do
      attrs = valid_user_attrs(username: "newcomer_#{System.unique_integer([:positive])}")

      assert {:ok, %User{} = user} = Accounts.register_user(attrs)
      assert user.role == "member"
      assert user.username == attrs.username
      assert user.email == attrs.email
      # the plaintext password never reaches the struct; the hash does
      assert is_nil(user.password)
      assert is_binary(user.password_hash)
      refute user.is_banned
    end

    test "rejects reserved usernames" do
      for reserved <- ["admin", "mod"] do
        attrs = valid_user_attrs(username: reserved)

        assert {:error, changeset} = Accounts.register_user(attrs)
        assert_error_message(changeset, :username, "is reserved and cannot be used")
      end
    end

    test "rejects usernames that are too short or too long" do
      for bad <- ["a", String.duplicate("u", 65)] do
        attrs = valid_user_attrs(username: bad)

        assert {:error, changeset} = Accounts.register_user(attrs)
        assert_error_on(changeset, :username)
      end
    end

    test "rejects usernames outside lowercase alphanumerics and underscore" do
      for bad <- ["UPPER", "user name", "user-1", "user.name", "user!"] do
        attrs = valid_user_attrs(username: bad)

        assert {:error, changeset} = Accounts.register_user(attrs)

        assert_error_message(
          changeset,
          :username,
          "must contain only lowercase letters, numbers, and underscores"
        )
      end
    end

    test "accepts usernames of lowercase alphanumerics and underscore, 2..64" do
      for good <- ["ab", "user_01", "user2", String.duplicate("u", 64)] do
        assert {:ok, %User{username: ^good}} =
                 Accounts.register_user(valid_user_attrs(username: good))
      end
    end

    test "rejects a duplicate email" do
      user = user_fixture()

      assert {:error, changeset} = Accounts.register_user(valid_user_attrs(email: user.email))
      assert_error_message(changeset, :email, "has already been taken")
    end
  end

  describe "authenticate_user_by_email_and_password/2" do
    test "authenticates with the right password" do
      user = user_fixture()

      assert {:ok, authed} =
               Accounts.authenticate_user_by_email_and_password(user.email, valid_user_password())

      assert authed.id == user.id
    end

    test "rejects a wrong password" do
      user = user_fixture()

      assert {:error, :invalid_credentials} =
               Accounts.authenticate_user_by_email_and_password(user.email, "wrong-password-1")
    end

    test "rejects an unknown email" do
      assert {:error, :invalid_credentials} =
               Accounts.authenticate_user_by_email_and_password(
                 "nobody@example.com",
                 "wrong-password-1"
               )
    end
  end

  describe "magic link login" do
    test "deliver_magic_link_instructions/1 emails a working, single-use token" do
      user = user_fixture()

      assert :ok = Accounts.deliver_magic_link_instructions(user.email)

      # Swoosh's test adapter delivers to the calling process.
      assert_receive {:email, email}, 1_000
      %{text_body: text} = email

      captured = Regex.run(~r{token=([A-Za-z0-9_-]+)}, text)
      refute is_nil(captured)
      token = Enum.at(captured, 1)

      assert {:ok, logged_in} = Accounts.login_user_by_magic_link(token)
      assert logged_in.id == user.id

      # The token is consumed: a second use fails.
      assert {:error, :invalid_or_expired} = Accounts.login_user_by_magic_link(token)
    end

    test "deliver_magic_link_instructions/1 with unknown email reveals nothing" do
      assert :ok = Accounts.deliver_magic_link_instructions("nobody@example.com")
      refute_receive {:email, _}
    end

    test "login_user_by_magic_link/1 rejects a garbage token" do
      assert {:error, :invalid_or_expired} = Accounts.login_user_by_magic_link("garbage-token")
    end
  end

  describe "session tokens" do
    test "generate → lookup → delete round-trip" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert is_binary(token)

      assert %User{id: id} = Accounts.get_user_by_session_token(token)
      assert id == user.id

      assert {1, _} = Accounts.delete_user_session_token(token)
      refute Accounts.get_user_by_session_token(token)

      assert Accounts.get_user_by_session_token(nil) == nil
    end
  end

  describe "ban_user/3" do
    test "admin ban flags the user, kills every session, and writes the log" do
      admin = admin_fixture()
      user = user_fixture()

      token = Accounts.generate_user_session_token(user)
      assert %User{} = Accounts.get_user_by_session_token(token)

      assert {:ok, banned} = Accounts.ban_user(admin, user, "spamming the directory")

      assert banned.is_banned
      assert banned.ban_reason == "spamming the directory"
      assert Accounts.get_user(user.id).is_banned

      # All of the user's tokens are gone — the cookie is dead.
      refute Accounts.get_user_by_session_token(token)

      tokens_left =
        Repo.one(from t in UserToken, where: t.user_id == ^user.id, select: count(t.id))

      assert tokens_left == 0

      log =
        Repo.one(
          from l in ModerationLog,
            where: l.target_id == ^user.id and l.action == "user_banned"
        )

      refute is_nil(log)
      assert log.target_type == "user"
      assert log.actor_id == admin.id
      assert log.reason == "spamming the directory"
    end

    test "a platform moderator is forbidden" do
      moderator = moderator_fixture()
      user = user_fixture()

      assert {:error, :forbidden} = Accounts.ban_user(moderator, user, "reason")

      # the target was left untouched
      refute Accounts.get_user(user.id).is_banned
    end
  end

  describe "unban_user/2" do
    test "clears the ban and logs the reversal" do
      admin = admin_fixture()
      user = banned_user_fixture()

      assert {:ok, unbanned} = Accounts.unban_user(admin, user)
      refute unbanned.is_banned
      assert is_nil(unbanned.ban_reason)
      refute Accounts.get_user(user.id).is_banned

      log =
        Repo.one(
          from l in ModerationLog,
            where: l.target_id == ^user.id and l.action == "user_unbanned"
        )

      refute is_nil(log)
      assert log.target_type == "user"
      assert log.actor_id == admin.id
    end
  end

  describe "set_global_role/3" do
    test "admin promotes and demotes between member/moderator/admin and logs it" do
      admin = admin_fixture()
      target = user_fixture()

      assert {:ok, moderator} = Accounts.set_global_role(admin, target, "moderator")
      assert moderator.role == "moderator"

      assert {:ok, back} = Accounts.set_global_role(admin, moderator, "member")
      assert back.role == "member"

      assert {:ok, promoted} = Accounts.set_global_role(admin, back, "admin")
      assert promoted.role == "admin"
      assert Accounts.get_user(target.id).role == "admin"

      logs =
        Repo.all(
          from l in ModerationLog,
            where: l.target_id == ^target.id and l.action == "user_role_changed"
        )

      assert Enum.count(logs) == 3

      first_change =
        Enum.find(logs, fn log ->
          log.metadata["from"] == "member" and log.metadata["to"] == "moderator"
        end)

      refute is_nil(first_change)
      assert first_change.actor_id == admin.id
    end

    test "refuses to change your own role" do
      admin = admin_fixture()

      assert {:error, :self_role_change} = Accounts.set_global_role(admin, admin, "moderator")
      assert Accounts.get_user(admin.id).role == "admin"
    end

    test "a platform moderator is forbidden" do
      moderator = moderator_fixture()
      target = user_fixture()

      assert {:error, :forbidden} = Accounts.set_global_role(moderator, target, "moderator")
      assert Accounts.get_user(target.id).role == "member"
    end

    test "rejects an unknown role" do
      admin = admin_fixture()
      target = user_fixture()

      assert {:error, :invalid_role} = Accounts.set_global_role(admin, target, "superadmin")
    end
  end

  describe "maybe_promote_bootstrap_admin/1" do
    @bootstrap_email "root@example.com"

    test "promotes the matching user to admin when no admin exists" do
      set_bootstrap_email(@bootstrap_email)

      user = user_fixture(email: @bootstrap_email)

      assert {:ok, promoted} = Accounts.maybe_promote_bootstrap_admin(user)
      assert promoted.role == "admin"
      assert Accounts.get_user(user.id).role == "admin"

      log =
        Repo.one(
          from l in ModerationLog,
            where: l.target_id == ^user.id and l.action == "user_bootstrap_promoted"
        )

      refute is_nil(log)
    end

    test "matches the bootstrap email case-insensitively" do
      set_bootstrap_email(@bootstrap_email)

      user = user_fixture(email: "ROOT@Example.COM")

      assert {:ok, promoted} = Accounts.maybe_promote_bootstrap_admin(user)
      assert promoted.role == "admin"
    end

    test "never promotes once an admin already exists" do
      set_bootstrap_email(@bootstrap_email)

      _existing = admin_fixture()
      user = user_fixture(email: @bootstrap_email)

      assert {:ok, unchanged} = Accounts.maybe_promote_bootstrap_admin(user)
      assert unchanged.role == "member"
      assert Accounts.get_user(user.id).role == "member"
    end

    test "never promotes a non-matching email" do
      set_bootstrap_email(@bootstrap_email)

      user = user_fixture(email: "someone_else@example.com")

      assert {:ok, unchanged} = Accounts.maybe_promote_bootstrap_admin(user)
      assert unchanged.role == "member"
    end
  end

  # The promotion reads System.get_env first, then the app env, so the
  # system variable is cleared (and restored) to make the app env the
  # deterministic source for the test.
  defp set_bootstrap_email(email) do
    original_system = System.get_env("BOOTSTRAP_ADMIN_EMAIL")
    original_app = Application.get_env(:beam_chat, :bootstrap_admin_email)

    System.delete_env("BOOTSTRAP_ADMIN_EMAIL")
    Application.put_env(:beam_chat, :bootstrap_admin_email, email)

    on_exit(fn ->
      Application.delete_env(:beam_chat, :bootstrap_admin_email)

      if original_app do
        Application.put_env(:beam_chat, :bootstrap_admin_email, original_app)
      end

      if original_system do
        System.put_env("BOOTSTRAP_ADMIN_EMAIL", original_system)
      else
        System.delete_env("BOOTSTRAP_ADMIN_EMAIL")
      end
    end)

    :ok
  end

  defp assert_error_on(changeset, field) do
    assert Enum.any?(changeset.errors, fn {error_field, _details} -> error_field == field end),
           "expected an error on #{inspect(field)}, got: #{inspect(changeset.errors)}"
  end

  defp assert_error_message(changeset, field, message) do
    assert Enum.any?(changeset.errors, fn {error_field, {error_message, _details}} ->
             error_field == field and error_message == message
           end),
           "expected an error on #{inspect(field)} with message #{inspect(message)}, got: #{inspect(changeset.errors)}"
  end
end
