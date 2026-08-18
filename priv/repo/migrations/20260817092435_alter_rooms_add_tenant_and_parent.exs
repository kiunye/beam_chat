defmodule BeamChat.Repo.Migrations.AlterRoomsAddTenantAndParent do
  use Ecto.Migration

  def up do
    # a. Add tenant_id nullable (existing rooms must be backfilled first).
    alter table(:rooms) do
      add :tenant_id,
          references(:tenants, type: :binary_id, on_delete: :delete_all),
          null: true
    end

    # b. Bootstrap a single "default" tenant if none exists yet.
    #    (Other T2 migrations also guard with WHERE NOT EXISTS — only one inserts.)
    execute """
    INSERT INTO tenants (id, name, slug, metadata, inserted_at, updated_at)
    SELECT gen_random_uuid(), 'Default', 'default', '{}'::jsonb, now(), now()
    WHERE NOT EXISTS (SELECT 1 FROM tenants)
    """

    # c. Backfill every room to the default tenant.
    execute """
    UPDATE rooms
    SET tenant_id = (SELECT id FROM tenants WHERE slug = 'default' LIMIT 1)
    WHERE tenant_id IS NULL
    """

    # d. Now that all rows are scoped, enforce NOT NULL.
    execute "ALTER TABLE rooms ALTER COLUMN tenant_id SET NOT NULL"

    # Self-referencing parent for the recursive room tree (top-level rooms = NULL).
    alter table(:rooms) do
      add :parent_id,
          references(:rooms, type: :binary_id, on_delete: :nilify_all),
          null: true
    end

    # Subtree queries filter on (tenant_id, parent_id). The leading column also
    # serves tenant_id-only scans (RLS/tenant-scoped lookups), so a separate
    # standalone (tenant_id) index is intentionally omitted to avoid redundancy.
    create index(:rooms, [:tenant_id, :parent_id], name: :rooms_tenant_parent_idx)

    # Block direct self-reference. Deeper cycle prevention is enforced in app code.
    create constraint(:rooms, :rooms_no_self_parent, check: "id <> parent_id")
  end

  def down do
    drop constraint(:rooms, :rooms_no_self_parent)
    drop index(:rooms, :rooms_tenant_parent_idx)

    alter table(:rooms) do
      remove :parent_id
      remove :tenant_id
    end

    # NOTE: the bootstrap "default" tenant (if inserted by this migration) is
    # intentionally left in place on rollback to avoid destroying data; T3/T4
    # work and re-runs of `up` are idempotent via the WHERE NOT EXISTS guard.
  end
end
