defmodule BeamChat.Rooms.RoomMember do
  @moduledoc """
  A user's membership of a room, with a room-scoped role layered under
  their platform role (PRD §2.1).

  `expires_at` is an optional time-box on the grant (e.g. a temporary
  membership); the access policy treats an expired row as absent.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(member moderator owner)

  schema "room_members" do
    field :role, :string, default: "member"
    field :joined_at, :utc_datetime
    field :expires_at, :utc_datetime

    belongs_to :room, BeamChat.Rooms.Room, foreign_key: :room_id
    belongs_to :user, BeamChat.Accounts.User, foreign_key: :user_id

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def changeset(room_member, attrs) do
    room_member
    |> cast(attrs, [:room_id, :user_id, :role, :joined_at, :expires_at])
    |> validate_required([:room_id, :user_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:room_id, :user_id])
    |> foreign_key_constraint(:room_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc "Changeset for a room-role change; the pair itself is immutable."
  def role_changeset(room_member, role) do
    room_member
    |> change(role: role)
    |> validate_inclusion(:role, @roles)
  end
end
