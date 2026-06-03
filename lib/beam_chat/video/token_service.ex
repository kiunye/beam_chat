defmodule BeamChat.Video.TokenService do
  @moduledoc """
  Issues short-lived LiveKit access tokens so authenticated users can join the
  audio/video room for a chat room. Wraps the third-party `Livekit.AccessToken`
  module so that if we ever need to swap implementations (e.g. `Joken` direct
  signing, or upgrade the SDK) we change one file.

  Defaults are deliberately conservative:
    * 1 hour TTL
    * `room_join: true`, `can_publish: true`, `can_subscribe: true`
    * Room name = Ecto UUID of the chat room (scoped; user cannot join
      other rooms with the same token)
    * Identity = `"user-" <> user.id` (stable, no PII in the token)

  Tokens are returned to the client via `push_event/3`; we never log them.
  """

  alias Livekit.AccessToken
  alias Livekit.Config, as: LKConfig
  alias Livekit.Grants
  alias Livekit.TokenVerifier

  @default_ttl_seconds 3_600

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
  """
  @spec verify_token(String.t()) :: {:ok, map()} | {:error, term()}
  def verify_token(jwt) do
    case lk_config() do
      {:ok, %{api_key: api_key, api_secret: api_secret}} ->
        TokenVerifier.verify(jwt, api_key, api_secret)

      {:error, :not_configured} = err ->
        err
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
