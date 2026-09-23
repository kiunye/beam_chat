defmodule BeamChat.AccountsTest do
  use BeamChat.DataCase, async: true

  import BeamChat.TestFixtures
  import Ecto.Query

  alias BeamChat.Accounts
  alias BeamChat.Accounts.User
  alias BeamChat.Repo

  describe "ban_user/3" do
    test "sets is_banned and clears all session tokens in a single transaction" do
      admin = user_fixture(%{role: "admin"})
      user = registered_user_fixture()
      raw = Accounts.generate_user_session_token(user)

      assert {:ok, banned} = Accounts.ban_user(admin, user, "spam")
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
      admin = user_fixture(%{role: "admin"})
      user = registered_user_fixture()
      assert {:ok, _} = Accounts.ban_user(admin, user)
      assert {:ok, _} = Accounts.ban_user(admin, user, "again")
    end

    test "ban with a nil reason is allowed" do
      admin = user_fixture(%{role: "admin"})
      user = registered_user_fixture()
      assert {:ok, banned} = Accounts.ban_user(admin, user, nil)
      assert banned.is_banned == true
      assert banned.ban_reason == nil
    end

    test "magic link tokens are also invalidated by ban" do
      admin = user_fixture(%{role: "admin"})
      user = registered_user_fixture()
      assert :ok = Accounts.deliver_magic_link_instructions(user.email)

      assert {:ok, _} = Accounts.ban_user(admin, user)

      # No token rows remain for this user, regardless of context.
      remaining = Repo.all(from t in BeamChat.Accounts.UserToken, where: t.user_id == ^user.id)
      assert remaining == []
    end

    test "a moderator (also holding :user_ban) can ban" do
      moderator = user_fixture(%{role: "moderator"})
      user = registered_user_fixture()

      assert {:ok, banned} = Accounts.ban_user(moderator, user, "abuse")
      assert banned.is_banned == true
    end

    test "ban and unban write audit rows" do
      admin = user_fixture(%{role: "admin"})
      user = registered_user_fixture()

      assert {:ok, _} = Accounts.ban_user(admin, user, "audit probe")
      assert {:ok, _} = Accounts.unban_user(admin, user)

      [ban] = BeamChat.Audit.list_recent(action: "user.banned", limit: 1)
      assert ban.actor_id == admin.id
      assert ban.target_id == user.id
      assert ban.metadata["reason"] == "audit probe"

      [unban] = BeamChat.Audit.list_recent(action: "user.unbanned", limit: 1)
      assert unban.actor_id == admin.id
      assert unban.target_id == user.id
    end

    test "forbids an actor without the :user_ban permission and leaves the target untouched" do
      member = user_fixture(%{role: "member"})
      user = registered_user_fixture()
      raw = Accounts.generate_user_session_token(user)

      assert {:error, :forbidden} = Accounts.ban_user(member, user, "grudge")

      # Nothing changed: the user is not banned, the session token still
      # resolves, and no audit row was written for the denied action.
      reloaded = Accounts.get_user(user.id)
      assert reloaded.is_banned == false
      assert Accounts.get_user_by_session_token(raw) != nil
      assert BeamChat.Audit.list_recent(action: "user.banned", limit: 1) == []
    end
  end

  describe "set_global_role/3" do
    test "a global admin can change a user's role and the change is audited" do
      admin = user_fixture(%{role: "admin"})
      user = registered_user_fixture()

      assert {:ok, updated} = Accounts.set_global_role(admin, user, "moderator")
      assert updated.role == "moderator"

      [audit] = BeamChat.Audit.list_recent(action: "user.role_changed", limit: 1)
      assert audit.actor_id == admin.id
      assert audit.target_id == user.id
      assert audit.metadata["from"] == "member"
      assert audit.metadata["to"] == "moderator"
    end

    test "refuses to change your own global role (lockout protection)" do
      admin = user_fixture(%{role: "admin"})
      assert {:error, :self_role_change} = Accounts.set_global_role(admin, admin, "member")
    end

    test "refuses unknown roles" do
      admin = user_fixture(%{role: "admin"})
      user = registered_user_fixture()

      assert {:error, :invalid_role} = Accounts.set_global_role(admin, user, "superuser")
    end

    test "forbids actors without the :user_manage_roles permission" do
      moderator = user_fixture(%{role: "moderator"})
      user = registered_user_fixture()

      assert {:error, :forbidden} = Accounts.set_global_role(moderator, user, "admin")
    end
  end

  describe "unban_user/2" do
    test "clears the ban flag" do
      admin = user_fixture(%{role: "admin"})
      user = registered_user_fixture()
      {:ok, _} = Accounts.ban_user(admin, user, "abuse")

      assert {:ok, unbanned} = Accounts.unban_user(admin, user)
      assert unbanned.is_banned == false
      assert unbanned.ban_reason == nil
    end

    test "does not resurrect old session tokens — user must re-authenticate" do
      admin = user_fixture(%{role: "admin"})
      user = registered_user_fixture()
      raw = Accounts.generate_user_session_token(user)
      {:ok, _} = Accounts.ban_user(admin, user)

      # Token is gone after ban.
      assert Accounts.get_user_by_session_token(raw) == nil

      # Unban does not magically restore it.
      {:ok, _} = Accounts.unban_user(admin, user)
      assert Accounts.get_user_by_session_token(raw) == nil
    end

    test "forbids an actor without the :user_ban permission" do
      member = user_fixture(%{role: "member"})
      user = registered_user_fixture()

      assert {:error, :forbidden} = Accounts.unban_user(member, user)
    end

    test "returns error for unknown user id" do
      admin = user_fixture(%{role: "admin"})

      assert {:error, :not_found} =
               Accounts.unban_user(admin, %User{id: Ecto.UUID.generate()})
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

  describe "touch_last_seen/1" do
    test "sets last_seen_at when it has never been set" do
      user = registered_user_fixture()
      assert user.last_seen_at == nil

      assert {1, nil} = Accounts.touch_last_seen(user.id)
      assert %{last_seen_at: %DateTime{}} = Accounts.get_user(user.id)
    end

    test "is throttled: a fresh last_seen_at is not rewritten" do
      user = registered_user_fixture()
      assert {1, nil} = Accounts.touch_last_seen(user.id)

      assert {0, nil} = Accounts.touch_last_seen(user.id)
      assert {0, nil} = Accounts.touch_last_seen(user.id)
    end

    test "updates again once the 5-minute window has passed" do
      user = registered_user_fixture()

      stale = DateTime.add(DateTime.utc_now(), -6 * 60, :second)

      from(u in User, where: u.id == ^user.id, update: [set: [last_seen_at: ^stale]])
      |> Repo.update_all([])

      assert {1, nil} = Accounts.touch_last_seen(user.id)
    end

    test "does nothing for an unknown user" do
      assert {0, nil} = Accounts.touch_last_seen(Ecto.UUID.generate())
    end
  end
end
