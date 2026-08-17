defmodule BeamChat.Payments.GroupSubscription do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_subscriptions" do
    field :started_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :status, :string, default: "active"

    belongs_to :user, BeamChat.Accounts.User, foreign_key: :user_id
    belongs_to :room, BeamChat.Rooms.Room, foreign_key: :room_id

    belongs_to :tenant, BeamChat.Tenants.Tenant, foreign_key: :tenant_id
    belongs_to :wallet_transaction, BeamChat.Wallet.WalletTransaction, foreign_key: :wallet_txn_id
  end

  @statuses ~w(active expired cancelled)

  def changeset(sub, attrs) do
    sub
    |> cast(attrs, [
      :user_id,
      :room_id,
      :tenant_id,
      :wallet_txn_id,
      :started_at,
      :expires_at,
      :status
    ])
    |> validate_required([:user_id, :room_id, :expires_at, :status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:user_id, :room_id, :started_at])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:room_id)
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:wallet_txn_id)
  end
end
