defmodule BeamChat.Wallet.Wallet do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "wallets" do
    field :balance, :decimal
    field :currency, :string, default: "KES"

    belongs_to :user, BeamChat.Accounts.User, foreign_key: :user_id

    timestamps(type: :utc_datetime)
  end

  def changeset(wallet, attrs) do
    wallet
    |> cast(attrs, [:user_id, :balance, :currency])
    |> validate_required([:user_id, :balance, :currency])
    |> validate_number(:balance, greater_than_or_equal_to: 0)
    |> unique_constraint(:user_id)
    |> foreign_key_constraint(:user_id)
  end
end
