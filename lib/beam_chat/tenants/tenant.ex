defmodule BeamChat.Tenants.Tenant do
  @moduledoc """
  A tenant is the top-level containment unit for the multi-tenant room
  hierarchy (e.g. a county). See CATEGORY_REDESIGN.md §3.1.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tenants" do
    field :name, :string
    field :slug, :string
    field :metadata, :map, default: %{}

    has_many :members, BeamChat.Tenants.TenantMember

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "Default changeset for creating/updating tenants."
  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:name, :slug, :metadata])
    |> validate_required([:name, :slug])
    |> unique_constraint(:slug)
  end
end
