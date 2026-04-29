defmodule BeamChat.Accounts.User do
  @moduledoc "User identity for Beam Chat (PRD §4.2, §8)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field :username, :string
    field :email, :string
    field :phone, :string
    field :password_hash, :string
    field :password, :string, virtual: true, redact: true
    field :avatar_url, :string
    field :first_name, :string
    field :last_name, :string
    field :full_name, :string, read_after_writes: true
    field :role, :string, default: "member"
    field :sso_provider, :string
    field :sso_uid, :string
    field :metadata, :map, default: %{}
    field :is_banned, :boolean, default: false
    field :ban_reason, :string
    field :last_seen_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "General insert (e.g. tests, OAuth) without password handling."
  def create_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :username,
      :email,
      :phone,
      :password_hash,
      :avatar_url,
      :first_name,
      :last_name,
      :role,
      :sso_provider,
      :sso_uid,
      :metadata,
      :is_banned,
      :ban_reason,
      :last_seen_at
    ])
    |> validate_required([:username])
    |> validate_length(:username, min: 2, max: 64)
    |> maybe_validate_email()
    |> validate_inclusion(:role, ~w(member moderator admin))
    |> unique_constraint(:username)
    |> unique_constraint(:email)
    |> unique_constraint(:phone)
    |> unique_constraint([:sso_provider, :sso_uid], name: :users_sso_unique)
  end

  @doc "Email + password registration."
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:username, :email, :password])
    |> validate_required([:username, :email, :password])
    |> validate_length(:username, min: 2, max: 64)
    |> validate_email_format()
    |> validate_length(:password, min: 8, max: 72)
    |> unique_constraint(:username)
    |> unique_constraint(:email)
    |> maybe_hash_password(opts)
  end

  @doc "OAuth / SSO upsert (no password)."
  def oauth_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :username,
      :email,
      :avatar_url,
      :sso_provider,
      :sso_uid,
      :metadata
    ])
    |> validate_required([:username, :sso_provider, :sso_uid])
    |> maybe_validate_email()
    |> unique_constraint(:username)
    |> unique_constraint(:email)
    |> unique_constraint([:sso_provider, :sso_uid], name: :users_sso_unique)
  end

  def admin?(%__MODULE__{role: "admin"}), do: true
  def admin?(%__MODULE__{role: "moderator"}), do: false
  def admin?(%__MODULE__{role: "member"}), do: false

  def staff?(%__MODULE__{role: role}) when role in ~w(admin moderator), do: true
  def staff?(%__MODULE__{}), do: false

  def valid_password?(%__MODULE__{password_hash: hashed}, password)
      when is_binary(hashed) and is_binary(password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end

  defp maybe_hash_password(changeset, opts) do
    password = get_change(changeset, :password)

    if password && Keyword.get(opts, :hash_password, true) do
      changeset
      |> put_change(:password_hash, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  defp validate_email_format(changeset) do
    changeset
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> unique_constraint(:email)
  end

  defp maybe_validate_email(changeset) do
    case get_change(changeset, :email) || get_field(changeset, :email) do
      nil ->
        changeset

      "" ->
        put_change(changeset, :email, nil)

      _email ->
        validate_format(changeset, :email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    end
  end
end
