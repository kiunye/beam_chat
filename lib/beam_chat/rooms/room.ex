defmodule BeamChat.Rooms.Room do
  use Ecto.Schema
  import Ecto.Changeset

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

    belongs_to(:tenant, BeamChat.Tenants.Tenant, foreign_key: :tenant_id)
    belongs_to(:parent, __MODULE__, foreign_key: :parent_id)
    has_many(:children, __MODULE__, foreign_key: :parent_id)

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room =
      room
      |> cast(attrs, [
        :name,
        :slug,
        :description,
        :category_id,
        :owner_id,
        :tenant_id,
        :parent_id,
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
      |> foreign_key_constraint(:tenant_id)
      |> foreign_key_constraint(:parent_id)

    parent_id = get_field(room, :parent_id)
    id = get_field(room, :id)

    if not is_nil(parent_id) and parent_id == id do
      add_error(room, :parent_id, "cannot be its own parent")
    else
      room
    end
  end
end
