defmodule BeamChat.Payments.RoomSubscription do
  @moduledoc """
  A time-boxed subscription to a paid room, purchased from the wallet in a
  single transaction that also records the debit (PRD §2.6, §3).

  Access is always gated on `expires_at` compared to the current time — a
  stale `active` row past its expiry is never trusted. The `status` flip to
  `"expired"` is bookkeeping done by a scheduled job.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active expired cancelled)

  schema "room_subscriptions" do
    field :started_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :status, :string, default: "active"

    belongs_to :user, BeamChat.Accounts.User, foreign_key: :user_id
    belongs_to :room, BeamChat.Rooms.Room, foreign_key: :room_id

    belongs_to :wallet_transaction, BeamChat.Wallet.WalletTransaction, foreign_key: :wallet_txn_id

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def changeset(room_subscription, attrs) do
    room_subscription
    |> cast(attrs, [:user_id, :room_id, :wallet_txn_id, :started_at, :expires_at, :status])
    |> validate_required([:user_id, :room_id, :started_at, :expires_at, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:room_id)
    |> foreign_key_constraint(:wallet_txn_id)
  end
end
