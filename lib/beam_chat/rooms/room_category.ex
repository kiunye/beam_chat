defmodule BeamChat.Rooms.RoomCategory do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "room_categories" do
    field :name, :string
    field :slug, :string

    belongs_to :tenant, BeamChat.Tenants.Tenant, foreign_key: :tenant_id

    timestamps(type: :utc_datetime)
  end

  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name, :slug, :tenant_id])
    |> validate_required([:name, :slug])
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:tenant_id)
  end
end
