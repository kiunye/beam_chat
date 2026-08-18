defmodule BeamChat.Rooms.RoomMember do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "room_members" do
    field :role, :string, default: "member"
    field :joined_at, :utc_datetime
    field :expires_at, :utc_datetime

    belongs_to :room, BeamChat.Rooms.Room, foreign_key: :room_id
    belongs_to :user, BeamChat.Accounts.User, foreign_key: :user_id
    belongs_to :tenant, BeamChat.Tenants.Tenant, foreign_key: :tenant_id
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:room_id, :user_id, :tenant_id, :role, :joined_at, :expires_at])
    |> validate_required([:room_id, :user_id, :role])
    |> validate_inclusion(:role, ~w(member moderator owner))
    |> unique_constraint([:room_id, :user_id])
    |> foreign_key_constraint(:room_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:tenant_id)
  end
end
