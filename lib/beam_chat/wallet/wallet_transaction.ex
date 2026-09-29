defmodule BeamChat.Wallet.WalletTransaction do
  @moduledoc """
  The wallet ledger: credit/debit rows with resulting balance, provider,
  status, and the provider reference — unique when present — that makes
  provider confirmations idempotent (PRD §2.7, §3).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @types ~w(credit debit)
  @statuses ~w(pending completed failed reversed)
  @providers ~w(mpesa paystack stripe internal)

  schema "wallet_transactions" do
    field :type, :string
    field :amount, :decimal
    field :balance_after, :decimal
    field :description, :string
    field :provider_reference, :string
    field :provider, :string
    field :metadata, :map, default: %{}
    field :status, :string, default: "pending"

    belongs_to :wallet, BeamChat.Wallet.Wallet, foreign_key: :wallet_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}

  def changeset(wallet_transaction, attrs) do
    wallet_transaction
    |> cast(attrs, [
      :wallet_id,
      :type,
      :amount,
      :balance_after,
      :description,
      :provider_reference,
      :provider,
      :metadata,
      :status
    ])
    |> validate_required([:wallet_id, :type, :amount, :status])
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:provider, @providers)
    |> validate_number(:amount, greater_than: 0)
    |> foreign_key_constraint(:wallet_id)
    |> unique_constraint(:provider_reference,
      name: :wallet_transactions_provider_reference_unique
    )
  end
end
