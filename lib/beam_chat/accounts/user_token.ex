defmodule BeamChat.Accounts.UserToken do
  @moduledoc """
  Hashed tokens for browser sessions and magic-link login (see PRD auth).
  """
  use Ecto.Schema
  import Ecto.Query

  alias BeamChat.Accounts.User

  @hash_algorithm :sha256
  @rand_size 32
  @session_validity_days 60
  @magic_link_validity_minutes 15

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string

    belongs_to :user, User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Returns `{raw_token, user_token_changeset}` for a session. Persist only the struct fields (hash in `token`).
  """
  def build_session_token(%User{} = user) do
    raw = :crypto.strong_rand_bytes(@rand_size)

    {Base.url_encode64(raw, padding: false),
     %__MODULE__{token: hash(raw), context: "session", user_id: user.id}}
  end

  @doc """
  Magic-link token tied to `sent_to` email for audit; `{raw, struct}`.
  """
  def build_magic_link_token(%User{} = user, email) when is_binary(email) do
    raw = :crypto.strong_rand_bytes(@rand_size)

    {Base.url_encode64(raw, padding: false),
     %__MODULE__{
       token: hash(raw),
       context: "magic_link",
       user_id: user.id,
       sent_to: email
     }}
  end

  def hash(raw) when is_binary(raw), do: :crypto.hash(@hash_algorithm, raw)

  @doc false
  def session_validity_cutoff do
    DateTime.add(DateTime.utc_now(:second), -@session_validity_days * 86_400, :second)
  end

  @doc false
  def magic_link_validity_cutoff do
    DateTime.add(DateTime.utc_now(:second), -@magic_link_validity_minutes * 60, :second)
  end

  def session_user_query(encoded_token) when is_binary(encoded_token) do
    case Base.url_decode64(encoded_token, padding: false) do
      :error ->
        from(t in __MODULE__, where: false)

      {:ok, raw} ->
        hashed = hash(raw)
        cutoff = session_validity_cutoff()

        from t in __MODULE__,
          join: u in assoc(t, :user),
          where: t.token == ^hashed and t.context == "session",
          where: t.inserted_at > ^cutoff,
          select: u
    end
  end

  def magic_link_user_and_token_query(encoded_token) when is_binary(encoded_token) do
    case Base.url_decode64(encoded_token, padding: false) do
      :error ->
        from(t in __MODULE__, where: false)

      {:ok, raw} ->
        hashed = hash(raw)
        cutoff = magic_link_validity_cutoff()

        from t in __MODULE__,
          join: u in assoc(t, :user),
          where: t.token == ^hashed and t.context == "magic_link",
          where: t.inserted_at > ^cutoff,
          select: {u, t}
    end
  end
end
