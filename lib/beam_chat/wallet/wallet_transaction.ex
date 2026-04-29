defmodule BeamChat.Wallet.WalletTransaction do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "wallet_transactions" do
    field :type, :string
    field :amount, :decimal
    field :balance_after, :decimal
    field :description, :string
    field :reference, :string
    field :provider, :string
    field :metadata, :map, default: %{}
    field :status, :string, default: "pending"

    belongs_to :wallet, BeamChat.Wallet.Wallet, foreign_key: :wallet_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @types ~w(credit debit)
  @statuses ~w(pending completed failed reversed)
  @providers ~w(mpesa paystack internal)

  def changeset(txn, attrs) do
    txn
    |> cast(attrs, [
      :wallet_id,
      :type,
      :amount,
      :balance_after,
      :description,
      :reference,
      :provider,
      :metadata,
      :status
    ])
    |> validate_required([:wallet_id, :type, :amount, :balance_after, :description, :status])
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:amount, greater_than: 0)
    |> validate_provider()
    |> unique_constraint(:reference, name: :wallet_transactions_reference_unique)
    |> foreign_key_constraint(:wallet_id)
  end

  defp validate_provider(changeset) do
    case get_field(changeset, :provider) do
      nil -> changeset
      p when p in @providers -> changeset
      _ -> add_error(changeset, :provider, "is invalid")
    end
  end
end
