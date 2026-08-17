defmodule BeamChat.Tenants.TenantMember do
  @moduledoc """
  Join between a tenant and a user. A user may belong to multiple tenants
  (CATEGORY_REDESIGN.md §3.2, decision D4). The `role` is `admin` or `member`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tenant_members" do
    belongs_to :tenant, BeamChat.Tenants.Tenant, foreign_key: :tenant_id
    belongs_to :user, BeamChat.Accounts.User, foreign_key: :user_id

    field :role, :string, default: "member"

    timestamps(type: :utc_datetime)
  end

  @doc "Default changeset for creating/updating tenant memberships."
  def changeset(member, attrs) do
    member
    |> cast(attrs, [:tenant_id, :user_id, :role])
    |> validate_required([:tenant_id, :user_id])
    |> validate_inclusion(:role, ~w(admin member))
    |> unique_constraint([:tenant_id, :user_id])
  end
end
