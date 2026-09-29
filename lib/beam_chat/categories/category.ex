defmodule BeamChat.Categories.Category do
  @moduledoc """
  A node in the admin-managed category/subcategory tree (PRD §1.3, §3).

  The tree is self-referential through `parent_id`; rooms are a separate
  thing that hangs off a node. A category can nest as deep as an admin
  wants. `position` orders siblings; `is_hidden` hides a category (and its
  subtree) from non-staff browsing.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "categories" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :position, :integer, default: 0
    field :is_hidden, :boolean, default: false

    belongs_to :parent, __MODULE__, foreign_key: :parent_id

    has_many :children, __MODULE__, foreign_key: :parent_id
    has_many :rooms, BeamChat.Rooms.Room, foreign_key: :category_id

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name, :slug, :description, :parent_id, :position, :is_hidden])
    |> validate_required([:name, :slug])
    |> put_slug()
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:description, max: 500)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_self_parent()
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:parent_id)
  end

  @doc "Changeset for renames/description edits that never touch the tree shape."
  def update_changeset(category, attrs) do
    category
    |> cast(attrs, [:name, :description, :position, :is_hidden])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:description, max: 500)
    |> validate_number(:position, greater_than_or_equal_to: 0)
  end

  @doc """
  Changeset for reparenting. The cycle guard itself lives in
  `BeamChat.Categories.reparent/2` because it needs database access to walk
  ancestors; this changeset only blocks the direct self-parent case.
  """
  def reparent_changeset(category, attrs) do
    category
    |> cast(attrs, [:parent_id])
    |> validate_self_parent()
    |> foreign_key_constraint(:parent_id)
  end

  # A category may never be its own direct parent. Deeper cycles are
  # caught by the context's ancestor walk.
  defp validate_self_parent(changeset) do
    id = get_field(changeset, :id)
    parent_id = get_field(changeset, :parent_id)

    if id != nil and parent_id == id do
      add_error(changeset, :parent_id, "cannot be its own parent")
    else
      changeset
    end
  end

  defp put_slug(changeset) do
    case get_field(changeset, :slug) do
      nil ->
        changeset
        |> fetch_change(:name)
        |> case do
          {:ok, name} when is_binary(name) -> put_change(changeset, :slug, slugify(name))
          _ -> changeset
        end
        |> validate_required([:slug])

      slug when is_binary(slug) ->
        changeset
        |> put_change(:slug, slugify(slug))
        |> validate_required([:slug])

      _ ->
        changeset
        |> validate_required([:slug])
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
