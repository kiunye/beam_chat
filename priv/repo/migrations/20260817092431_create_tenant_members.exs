defmodule BeamChat.Repo.Migrations.CreateTenantMembers do
  use Ecto.Migration

  def change do
    create table(:tenant_members, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :tenant_id,
          references(:tenants, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id,
          references(:users, type: :binary_id, on_delete: :delete_all),
          null: false

      add :role, :text, null: false, default: "member"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tenant_members, [:tenant_id, :user_id])

    create constraint(:tenant_members, :tenant_members_role_check,
             check: "role IN ('admin','member')"
           )

    # Partial index to speed up "is this user a tenant admin?" hot checks.
    create index(:tenant_members, [:tenant_id],
             name: :tenant_members_admin_idx,
             where: "role = 'admin'"
           )
  end
end
