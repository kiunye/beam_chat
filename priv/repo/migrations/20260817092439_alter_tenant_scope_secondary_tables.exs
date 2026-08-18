defmodule BeamChat.Repo.Migrations.AlterTenantScopeSecondaryTables do
  use Ecto.Migration

  def up do
    # Ensure a bootstrap "default" tenant exists (idempotent across all T2 migrations).
    execute """
    INSERT INTO tenants (id, name, slug, metadata, inserted_at, updated_at)
    SELECT gen_random_uuid(), 'Default', 'default', '{}'::jsonb, now(), now()
    WHERE NOT EXISTS (SELECT 1 FROM tenants)
    """

    # --- room_categories ---
    alter table(:room_categories) do
      add :tenant_id,
          references(:tenants, type: :binary_id, on_delete: :delete_all),
          null: true
    end

    execute """
    UPDATE room_categories
    SET tenant_id = (SELECT id FROM tenants WHERE slug = 'default' LIMIT 1)
    WHERE tenant_id IS NULL
    """

    execute "ALTER TABLE room_categories ALTER COLUMN tenant_id SET NOT NULL"
    create index(:room_categories, [:tenant_id], name: :room_categories_tenant_idx)

    # --- room_members ---
    alter table(:room_members) do
      add :tenant_id,
          references(:tenants, type: :binary_id, on_delete: :delete_all),
          null: true
    end

    execute """
    UPDATE room_members
    SET tenant_id = (SELECT id FROM tenants WHERE slug = 'default' LIMIT 1)
    WHERE tenant_id IS NULL
    """

    execute "ALTER TABLE room_members ALTER COLUMN tenant_id SET NOT NULL"
    create index(:room_members, [:tenant_id], name: :room_members_tenant_idx)

    # --- group_subscriptions ---
    alter table(:group_subscriptions) do
      add :tenant_id,
          references(:tenants, type: :binary_id, on_delete: :delete_all),
          null: true
    end

    execute """
    UPDATE group_subscriptions
    SET tenant_id = (SELECT id FROM tenants WHERE slug = 'default' LIMIT 1)
    WHERE tenant_id IS NULL
    """

    execute "ALTER TABLE group_subscriptions ALTER COLUMN tenant_id SET NOT NULL"
    create index(:group_subscriptions, [:tenant_id], name: :group_subscriptions_tenant_idx)
  end

  def down do
    drop index(:group_subscriptions, :group_subscriptions_tenant_idx)

    alter table(:group_subscriptions) do
      remove :tenant_id
    end

    drop index(:room_members, :room_members_tenant_idx)

    alter table(:room_members) do
      remove :tenant_id
    end

    drop index(:room_categories, :room_categories_tenant_idx)

    alter table(:room_categories) do
      remove :tenant_id
    end

    # Bootstrap "default" tenant intentionally left in place on rollback.
  end
end
