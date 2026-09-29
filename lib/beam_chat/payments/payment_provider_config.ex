defmodule BeamChat.Payments.PaymentProviderConfig do
  @moduledoc """
  One row per payment provider: enabled flag plus credentials encrypted at
  rest (PRD §2.8, §3). Credentials are write-only through Settings — once
  saved, a secret is never redisplayed, only replaced. A disabled row's
  credentials, if present from a prior configuration, are simply not used.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @providers ~w(paystack mpesa stripe)

  schema "payment_provider_configs" do
    field :provider, :string
    field :is_enabled, :boolean, default: false
    field :credentials, :string
    field :credentials_set_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:provider, :is_enabled, :credentials, :credentials_set_at])
    |> validate_required([:provider, :is_enabled])
    |> validate_inclusion(:provider, @providers)
    |> unique_constraint(:provider)
  end
end
