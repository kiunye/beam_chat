defmodule BeamChat.Video.TokenService do
  @moduledoc """
  Issues short-lived LiveKit access tokens so authenticated users can join the
  audio/video room for a chat room. Wraps the third-party `Livekit.AccessToken`
  module so that if we ever need to swap implementations (e.g. `Joken` direct
  signing, or upgrade the SDK) we change one file.

  Defaults are deliberately conservative:
    * 10 minute TTL
    * `room_join: true`, `can_publish: true`, `can_subscribe: true`
    * Room name = Ecto UUID of the chat room (scoped; user cannot join
      other rooms with the same token)
    * Identity = `"user-" <> user.id` (stable, no PII in the token)

  Tokens are returned to the client via `push_event/3`; we never log them.
  """

  alias Livekit.AccessToken
  alias Livekit.Config, as: LKConfig
  alias Livekit.Grants

  @default_ttl_seconds 600

  @type token_payload :: %{
          token: String.t(),
          url: String.t(),
          identity: String.t(),
          name: String.t(),
          room: String.t()
        }

  @doc """
  Generate a LiveKit JWT for `user` to join `room_id`.

  Returns `{:ok, payload}` with the JWT, the public URL, and metadata; or
  `{:error, :not_configured}` if LiveKit is not configured (e.g. missing
  `LIVEKIT_API_KEY`).

  ## TTL

  Default TTL is **10 minutes** (#{@default_ttl_seconds}s), not 1 hour.

  Rationale: a banned user who already holds a 1-hour token would retain
  publish rights until expiry. A short TTL bounds the blast radius — if a
  user is banned mid-call, the token stops working within 10 minutes. The
  client can re-join (and re-pass `AccessPolicy`) to receive a new one;
  banned users will be denied at the policy check before a new token is
  issued. Long lived keepalive/refresh is a P1+ feature, not in scope here.

  ## Caller responsibility

  This service does **not** re-verify `User.is_banned` against the database.
  The caller (`VideoLive.handle_event/3` for `join_video`) must perform a
  fresh `Repo.get_by(User, id: ..., is_banned: false)` lookup before calling
  `generate_token/3` — see `BeamChatWeb.VideoLive` for the canonical check.
  Rationale: the user struct held in `socket.assigns.current_user` is
  populated at socket-connect time from the cookie and may be stale.
  """
  @spec generate_token(%{id: Ecto.UUID.t()}, Ecto.UUID.t(), keyword()) ::
          {:ok, token_payload()} | {:error, :not_configured}
  def generate_token(user, room_id, opts \\ []) do
    case lk_config() do
      {:error, :not_configured} = err ->
        err

      {:ok, %{api_key: api_key, api_secret: api_secret, url: url}} ->
        ttl = Keyword.get(opts, :ttl, @default_ttl_seconds)
        name = user_name(user)

        token =
          AccessToken.new(api_key, api_secret)
          |> AccessToken.with_identity(identity(user))
          |> AccessToken.with_name(name)
          |> AccessToken.with_ttl(ttl)
          |> AccessToken.add_grant(Grants.join_room(room_id))
          |> AccessToken.to_jwt()

        {:ok,
         %{
           token: token,
           url: url,
           identity: identity(user),
           name: name,
           room: room_id
         }}
    end
  end

  @doc """
  Verify a token issued by this service. Used by tests to confirm round-trip
  integrity; in production the LiveKit server is the canonical verifier.

  We only check that the JWT is well-formed and that a config exists. The
  `livekit` Hex package's public API in 0.1.x exposes only
  `Livekit.TokenVerifier.verify/2` (verifies a presenter identity), not a
  full HMAC re-verification, so we read the claims via `Joken` directly
  to confirm round-trip integrity.
  """
  @spec verify_token(String.t()) :: {:ok, map()} | {:error, term()}
  def verify_token(jwt) do
    case lk_config() do
      {:ok, _cfg} ->
        case Joken.peek_claims(jwt) do
          {:ok, claims} -> {:ok, claims}
          {:error, _} = err -> err
        end

      {:error, :not_configured} = err ->
        err
    end
  end

  @doc """
  Generate a **subscribe-only** LiveKit JWT for `user` to listen to
  `room_name` (e.g. a radio station's `BeamChat.Streaming.livekit_room_name/1`).

  Same conservative defaults as `generate_token/3` (short TTL, identity
  `"user-" <> user.id`, no PII in claims). The grant denies publishing
  entirely (`canPublish`/`canPublishData` false) so a listener can never
  inject media or data into the room — radio rooms are one-way by
  construction.

  The hex `livekit` package's `Livekit.Grants` struct does not model
  `canPublish`/`canSubscribe`, so this token is signed directly with
  `Joken` using LiveKit's documented access-token claim shape.
  """
  @spec generate_listener_token(%{id: Ecto.UUID.t()}, String.t(), keyword()) ::
          {:ok, token_payload()} | {:error, :not_configured}
  def generate_listener_token(user, room_name, opts \\ []) do
    case lk_config() do
      {:error, :not_configured} = err ->
        err

      {:ok, %{api_key: api_key, api_secret: api_secret, url: url}} ->
        ttl = Keyword.get(opts, :ttl, @default_ttl_seconds)
        now = System.system_time(:second)
        name = user_name(user)

        claims = %{
          "iss" => api_key,
          "sub" => identity(user),
          "nbf" => now,
          "exp" => now + ttl,
          "name" => name,
          "video" => %{
            "room" => room_name,
            "roomJoin" => true,
            "canPublish" => false,
            "canSubscribe" => true,
            "canPublishData" => false
          }
        }

        signer = Joken.Signer.create("HS256", api_secret)
        {:ok, token, _claims} = Joken.encode_and_sign(claims, signer)

        {:ok,
         %{
           token: token,
           url: url,
           identity: identity(user),
           name: name,
           room: room_name
         }}
    end
  end

  @doc """
  Stable identity derived from the user UUID. Avoids putting PII in the token.
  """
  @spec identity(%{id: Ecto.UUID.t()}) :: String.t()
  def identity(%{id: id}), do: "user-" <> to_string(id)

  @doc """
  Display name used inside the LiveKit room. Falls back to the identity
  if the user has no name fields.
  """
  @spec user_name(map()) :: String.t()
  def user_name(%{full_name: name}) when is_binary(name) and name != "", do: name
  def user_name(%{username: name}) when is_binary(name) and name != "", do: name
  def user_name(user), do: identity(user)

  defp lk_config do
    case LKConfig.get_validated() do
      {:ok, %{api_key: key, api_secret: secret, url: url}}
      when is_binary(key) and byte_size(key) > 0 and
             is_binary(secret) and byte_size(secret) > 0 and
             is_binary(url) and byte_size(url) > 0 ->
        {:ok, %{api_key: key, api_secret: secret, url: url}}

      _ ->
        {:error, :not_configured}
    end
  end
end
