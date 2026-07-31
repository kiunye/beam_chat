defmodule BeamChat.Accounts do
  @moduledoc "Registration, credentials, sessions, magic links, and OAuth user upserts."

  import Ecto.Query

  alias BeamChat.Accounts.{User, UserToken}
  alias BeamChat.AuthEmail
  alias BeamChat.Mailer
  alias BeamChat.Repo

  ## Registration & login (password)

  def register_user(attrs \\ %{}) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc "Changeset for the registration form (password not hashed until submit)."
  def change_registration(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs, hash_password: false)
  end

  def authenticate_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = get_user_by_email(email)

    if User.valid_password?(user, password) do
      {:ok, user}
    else
      {:error, :invalid_credentials}
    end
  end

  def get_user(id), do: Repo.get(User, id)

  def get_user_by_email(email) when is_binary(email), do: Repo.get_by(User, email: email)

  ## Session tokens

  def generate_user_session_token(user) do
    {raw, token} = UserToken.build_session_token(user)
    Repo.insert!(token)
    raw
  end

  def get_user_by_session_token(nil), do: nil

  def get_user_by_session_token(token) when is_binary(token) do
    UserToken.session_user_query(token) |> Repo.one()
  end

  def delete_user_session_token(token) when is_binary(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, raw} ->
        hashed = UserToken.hash(raw)

        Repo.delete_all(
          from t in UserToken,
            where: t.token == ^hashed and t.context == "session"
        )

      :error ->
        :ok
    end
  end

  ## Magic link

  def deliver_magic_link_instructions(email) when is_binary(email) do
    if user = get_user_by_email(email) do
      {raw, token} = UserToken.build_magic_link_token(user, email)
      Repo.insert!(token)

      url_fun = fn ->
        BeamChatWeb.Endpoint.url() <> "/auth/magic-link/verify?token=" <> URI.encode_www_form(raw)
      end

      AuthEmail.magic_link_email(user, url_fun)
      |> Mailer.deliver()

      :ok
    else
      # Do not reveal whether the email exists
      :ok
    end
  end

  def login_user_by_magic_link(token) when is_binary(token) do
    case UserToken.magic_link_user_and_token_query(token) |> Repo.one() do
      nil ->
        {:error, :invalid_or_expired}

      {user, token_row} ->
        Repo.delete!(token_row)
        {:ok, user}
    end
  end

  ## OAuth

  def register_or_update_oauth_user(provider, claims)
      when is_binary(provider) and is_map(claims) do
    case normalize_oauth_sub(claims) do
      {:ok, sub} ->
        do_register_or_update_oauth_user(provider, sub, claims)

      :error ->
        {:error, :invalid_claims}
    end
  end

  defp do_register_or_update_oauth_user(provider, sub, claims) do
    email = claims["email"]
    name = claims["name"] || claims["preferred_username"] || email || "user"
    avatar = claims["picture"] || claims["avatar_url"]

    attrs = %{
      username: unique_username_from_oauth(name, email, provider, sub),
      email: email,
      avatar_url: avatar,
      sso_provider: provider,
      sso_uid: sub,
      metadata: %{"oauth_claims" => claims}
    }

    case Repo.get_by(User, sso_provider: provider, sso_uid: sub) do
      nil ->
        %User{}
        |> User.oauth_changeset(attrs)
        |> Repo.insert()

      %User{} = user ->
        user
        |> User.oauth_changeset(Map.put(attrs, :username, user.username))
        |> Repo.update()
    end
  end

  defp normalize_oauth_sub(claims) do
    case Map.get(claims, "sub") do
      sub when is_binary(sub) and sub != "" -> {:ok, sub}
      sub when is_integer(sub) -> {:ok, Integer.to_string(sub)}
      _ -> :error
    end
  end

  defp unique_username_from_oauth(name, _email, provider, sub) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]+/u, "_")
      |> String.slice(0, 40)
      |> then(fn s -> if s == "", do: "user", else: s end)

    suffix =
      :crypto.hash(:sha256, "#{provider}:#{sub}")
      |> Base.encode16(case: :lower)
      |> String.slice(0, 8)

    candidate = "#{base}_#{suffix}"

    cond do
      reserved_username?(candidate) ->
        "#{base}_#{suffix}_#{System.unique_integer([:positive])}"

      Repo.get_by(User, username: candidate) ->
        "#{base}_#{suffix}_#{System.unique_integer([:positive])}"

      true ->
        candidate
    end
  end

  ## Last seen

  @last_seen_stale_after 5 * 60

  @doc """
  Best-effort touch of `users.last_seen_at`, throttled so a user is written at
  most once per 5-minute window (SECURITY_REVIEW.md P3 #22).

  Uses a guarded `update_all` — no read-modify-write, safe under concurrency.
  Returns `{count, nil}` of updated rows; callers should not block on this.
  """
  @spec touch_last_seen(String.t()) :: {non_neg_integer(), nil}
  def touch_last_seen(user_id) when is_binary(user_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -@last_seen_stale_after, :second)

    Repo.update_all(
      from(u in User,
        where: u.id == ^user_id and (is_nil(u.last_seen_at) or u.last_seen_at < ^cutoff),
        update: [set: [last_seen_at: ^DateTime.utc_now()]]
      ),
      []
    )
  end

  @doc """
  Returns true if `username` is on the configured reserved-username list.

  Reserved usernames may not be self-claimed via OAuth/SSO/registration.
  See `config :beam_chat, :reserved_usernames` and SECURITY_REVIEW.md P1 #12.

  Comparison is case-insensitive and ignores leading/trailing whitespace.
  """
  @spec reserved_username?(String.t()) :: boolean()
  def reserved_username?(username) when is_binary(username) do
    normalised = username |> String.trim() |> String.downcase()

    reserved_usernames()
    |> Enum.any?(&(&1 == normalised))
  end

  def reserved_username?(_), do: false

  defp reserved_usernames do
    Application.get_env(:beam_chat, :reserved_usernames, [])
    |> Enum.map(fn
      s when is_binary(s) -> s |> String.trim() |> String.downcase()
      other -> other
    end)
    |> Enum.reject(&is_nil/1)
  end

  ## Banning

  @doc """
  Bans a user and invalidates all active sessions/magic-link tokens atomically.

  Returns `{:ok, user}` with the refreshed user struct, or `{:error, changeset}`.
  After this call, any cookie previously held by `user_id` is dead: the
  `users_tokens` rows are gone, so `get_user_by_session_token/1` will return `nil`,
  and the `BeamChatWeb.UserAuth.fetch_current_user` plug will treat the request
  as logged out (defence in depth, since `is_banned: true` also short-circuits).
  """
  def ban_user(%User{id: user_id}, reason \\ nil) when is_binary(user_id) do
    Repo.transaction(fn ->
      user = Repo.get!(User, user_id)

      changeset =
        user
        |> Ecto.Changeset.change(is_banned: true)
        |> Ecto.Changeset.put_change(:ban_reason, reason)

      with {:ok, updated} <- Repo.update(changeset),
           {:ok, _count} <- delete_user_tokens(user_id) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Clears the ban flag on a user. Tokens are not restored — the user simply
  re-authenticates via password, magic link, OAuth, or SSO. `ban_reason` is cleared.
  """
  def unban_user(%User{id: user_id}) when is_binary(user_id) do
    case Repo.get(User, user_id) do
      nil ->
        {:error, :not_found}

      user ->
        user
        |> Ecto.Changeset.change(is_banned: false, ban_reason: nil)
        |> Repo.update()
    end
  end

  defp delete_user_tokens(user_id) do
    Repo.delete_all(from t in UserToken, where: t.user_id == ^user_id)
  end

  ## SSO JWT (shared secret)

  def upsert_user_from_sso_jwt_claims(%{} = claims) do
    case normalize_oauth_sub(claims) do
      {:ok, sub} ->
        claims = Map.put(claims, "sub", sub)
        do_upsert_user_from_sso_jwt_claims(sub, claims)

      :error ->
        {:error, :invalid_claims}
    end
  end

  def upsert_user_from_sso_jwt_claims(_), do: {:error, :invalid_claims}

  defp do_upsert_user_from_sso_jwt_claims(sub, claims) do
    email = claims["email"]
    name = claims["name"] || email || "sso_user"

    attrs = %{
      username: unique_username_from_oauth(name, email, "sso_jwt", sub),
      email: email,
      sso_provider: "sso_jwt",
      sso_uid: sub,
      metadata: %{"sso_jwt" => claims}
    }

    case Repo.get_by(User, sso_provider: "sso_jwt", sso_uid: sub) do
      nil ->
        %User{}
        |> User.oauth_changeset(attrs)
        |> Repo.insert()

      %User{} = user ->
        user
        |> User.oauth_changeset(Map.put(attrs, :username, user.username))
        |> Repo.update()
    end
  end
end
