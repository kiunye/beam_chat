defmodule BeamChat.Rooms.Room do
  use Ecto.Schema
  import Ecto.Changeset

  alias BeamChat.Rooms.RoomServer

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rooms" do
    field(:name, :string)
    field(:slug, :string)
    field(:description, :string)
    field(:type, :string, default: "public")
    field(:password_hash, :string)
    field(:is_paid, :boolean, default: false)
    field(:price, :decimal)
    field(:currency, :string, default: "KES")
    field(:max_members, :integer, default: 500)
    field(:age_restriction, :integer)
    field(:metadata, :map, default: %{})
    field(:is_archived, :boolean, default: false)

    belongs_to(:category, BeamChat.Rooms.RoomCategory, foreign_key: :category_id)
    belongs_to(:owner, BeamChat.Accounts.User, foreign_key: :owner_id)

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [
      :name,
      :slug,
      :description,
      :category_id,
      :owner_id,
      :type,
      :password_hash,
      :is_paid,
      :price,
      :currency,
      :max_members,
      :age_restriction,
      :metadata,
      :is_archived
    ])
    |> validate_required([:name, :slug, :owner_id])
    |> validate_inclusion(:type, ~w(public private secret paid))
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:category_id)
    |> foreign_key_constraint(:owner_id)
  end

  ## Room Server Helpers

  @spec start_room_server(Ecto.UUID.t()) :: {:ok, pid()} | {:error, term()}
  def start_room_server(room_id) do
    RoomServer.start_link(room_id)
  end

  @spec stop_room_server(Ecto.UUID.t()) :: :ok | {:error, term()}
  def stop_room_server(room_id) do
    RoomServer.stop(room_id)
  end

  @spec join_room(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) :: :ok
  def join_room(room_id, user_id, user_name) do
    RoomServer.join_room(room_id, user_id, user_name)
  end

  @spec leave_room(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def leave_room(room_id, user_id) do
    RoomServer.leave_room(room_id, user_id)
  end

  @spec set_typing(Ecto.UUID.t(), Ecto.UUID.t(), boolean()) :: :ok
  def set_typing(room_id, user_id, is_typing) do
    RoomServer.set_typing(room_id, user_id, is_typing)
  end

  @spec get_room_state(Ecto.UUID.t()) ::
          {:ok, BeamChat.Rooms.RoomServer.state()} | {:error, :not_found}
  def get_room_state(room_id) do
    RoomServer.get_state(room_id)
  end
end
