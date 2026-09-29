defmodule BeamChat.Rooms.Room do
  @moduledoc """
  A chat room. Rooms hang off a node in the category tree; they are never
  tree nodes themselves (PRD §1.3).

  Types:

  - `public` — anyone finds and enters it.
  - `private` — listed, but joining requires an explicit membership grant.
  - `secret` — not listed; reachable only by direct link plus a grant.
  - `paid` — listed per `is_listed`; entering the chat stream requires an
    active time-boxed subscription purchased from the wallet.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @types ~w(public private secret paid)

  schema "rooms" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :type, :string, default: "public"
    field :password_hash, :string
    field :is_paid, :boolean, default: false
    field :is_listed, :boolean, default: true
    field :price, :decimal
    field :max_members, :integer, default: 500
    field :is_archived, :boolean, default: false

    belongs_to :category, BeamChat.Categories.Category, foreign_key: :category_id
    belongs_to :owner, BeamChat.Accounts.User, foreign_key: :owner_id

    has_many :members, BeamChat.Rooms.RoomMember, foreign_key: :room_id

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc """
  Changeset for room creation. `owner_id` is set programmatically by the
  context (never cast from user input) and `is_paid` is derived from the
  chosen type.
  """
  def changeset(room, attrs) do
    room
    |> cast(attrs, [
      :name,
      :slug,
      :description,
      :type,
      :category_id,
      :price,
      :max_members,
      :is_listed
    ])
    |> validate_required([:name, :category_id])
    |> put_slug()
    |> validate_required([:slug])
    |> validate_inclusion(:type, @types)
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:description, max: 500)
    |> validate_number(:max_members, greater_than: 0, less_than_or_equal_to: 10_000)
    |> derive_is_paid()
    |> validate_price()
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:category_id)
  end

  @doc "Changeset for owner/admin edits: metadata only, never the owner."
  def update_changeset(room, attrs) do
    room
    |> cast(attrs, [:name, :description, :category_id, :type, :price, :max_members, :is_listed])
    |> validate_required([:name, :category_id])
    |> validate_inclusion(:type, @types)
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:description, max: 500)
    |> validate_number(:max_members, greater_than: 0, less_than_or_equal_to: 10_000)
    |> derive_is_paid()
    |> validate_price()
    |> foreign_key_constraint(:category_id)
  end

  @doc "Changeset for the archive toggle."
  def archive_changeset(room, is_archived) when is_boolean(is_archived) do
    change(room, is_archived: is_archived)
  end

  # `is_paid` mirrors the type so the payment side can key off one column;
  # it is derived, never cast (AGENTS.md: programmatic fields stay out of cast).
  defp derive_is_paid(changeset) do
    case get_field(changeset, :type) do
      "paid" -> put_change(changeset, :is_paid, true)
      _ -> put_change(changeset, :is_paid, false)
    end
  end

  defp validate_price(changeset) do
    case get_field(changeset, :type) do
      "paid" ->
        changeset
        |> validate_required([:price])
        |> validate_number(:price, greater_than: 0)

      _ ->
        changeset
    end
  end

  defp put_slug(changeset) do
    slug = get_field(changeset, :slug)

    slug =
      case slug do
        nil ->
          case fetch_change(changeset, :name) do
            {:ok, name} when is_binary(name) -> slugify(name)
            _ -> nil
          end

        value when is_binary(value) ->
          slugify(value)

        _ ->
          nil
      end

    if slug in [nil, ""] do
      add_error(changeset, :slug, "cannot be blank")
    else
      put_change(changeset, :slug, slug)
    end
  end

  defp slugify(value) do
    value
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 80)
  end
end
