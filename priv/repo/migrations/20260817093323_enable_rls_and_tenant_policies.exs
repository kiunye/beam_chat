defmodule BeamChat.Repo.Migrations.EnableRlsAndTenantPolicies do
  use Ecto.Migration

  # Multi-tenant isolation via PostgreSQL Row Level Security (RLS).
  #
  # Every scoped table is protected by policies that read the per-connection
  # session GUCs `app.current_tenant_id` and `app.current_user_id`. Those GUCs
  # are set with `SET LOCAL` inside `BeamChat.Repo.with_tenant/3` (see design
  # doc section 3.6). `current_setting(..., true)` returns NULL when the GUC is
  # unset (missing_ok = true), so the `::uuid` cast yields NULL and the row is
  # denied — a safe default-deny.
  #
  # IMPORTANT: enabling RLS subjects INSERT/UPDATE/DELETE to policy too. If no
  # policy permits a command it is DENIED, so we create BOTH select AND write
  # policies for every table. `messages` is partitioned; RLS is enabled on the
  # parent only and is automatically inherited by all partitions (PostgreSQL 12+).
  # Policies for a partitioned table are defined on the parent and apply to every
  # partition — partitions cannot have their own independent policies.

  def up do
    # ----------------------------------------------------------------------
    # Helper SQL function: is this user a tenant admin?
    # ----------------------------------------------------------------------
    execute """
    CREATE OR REPLACE FUNCTION is_tenant_admin(p_user uuid, p_tenant uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    AS $$
      SELECT EXISTS (
        SELECT 1 FROM tenant_members
        WHERE tenant_id = p_tenant
          AND user_id = p_user
          AND role = 'admin'
      )
    $$;
    """

    # ----------------------------------------------------------------------
    # Enable RLS on every tenant-scoped table.
    # ----------------------------------------------------------------------
    # ENABLE forces policy checks for normal roles. FORCE additionally applies
    # RLS to the table owner (defense-in-depth). NOTE: PostgreSQL superusers
    # bypass RLS regardless of FORCE — the application MUST connect as a
    # NON-superuser role for these policies to provide any protection. See the
    # security note in CATEGORY_REDESIGN.md and the build summary.
    execute "ALTER TABLE rooms ENABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE rooms FORCE ROW LEVEL SECURITY;"
    execute "ALTER TABLE room_members ENABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE room_members FORCE ROW LEVEL SECURITY;"
    execute "ALTER TABLE room_categories ENABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE room_categories FORCE ROW LEVEL SECURITY;"
    execute "ALTER TABLE group_subscriptions ENABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE group_subscriptions FORCE ROW LEVEL SECURITY;"
    execute "ALTER TABLE messages ENABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE messages FORCE ROW LEVEL SECURITY;"

    # ======================================================================
    # rooms
    # ======================================================================
    execute """
    CREATE POLICY rooms_select ON rooms
      FOR SELECT
      USING (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
        AND (
          is_tenant_admin(current_setting('app.current_user_id', true)::uuid, tenant_id)
          OR EXISTS (
            SELECT 1 FROM room_members rm
            WHERE rm.room_id = rooms.id
              AND rm.user_id = current_setting('app.current_user_id', true)::uuid
              AND rm.tenant_id = rooms.tenant_id
          )
        )
      );
    """

    execute """
    CREATE POLICY rooms_insert ON rooms
      FOR INSERT
      WITH CHECK (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
      );
    """

    execute """
    CREATE POLICY rooms_update ON rooms
      FOR UPDATE
      USING (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
      )
      WITH CHECK (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
      );
    """

    execute """
    CREATE POLICY rooms_delete ON rooms
      FOR DELETE
      USING (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
      );
    """

    # ======================================================================
    # room_members
    # ======================================================================
    execute """
    CREATE POLICY room_members_select ON room_members
      FOR SELECT
      USING (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
        AND (
          is_tenant_admin(current_setting('app.current_user_id', true)::uuid, tenant_id)
          OR user_id = current_setting('app.current_user_id', true)::uuid
        )
      );
    """

    execute """
    CREATE POLICY room_members_insert ON room_members
      FOR INSERT
      WITH CHECK (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
        AND (
          user_id = current_setting('app.current_user_id', true)::uuid
          OR is_tenant_admin(current_setting('app.current_user_id', true)::uuid, tenant_id)
        )
      );
    """

    execute """
    CREATE POLICY room_members_update ON room_members
      FOR UPDATE
      USING (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
        AND (
          is_tenant_admin(current_setting('app.current_user_id', true)::uuid, tenant_id)
          OR user_id = current_setting('app.current_user_id', true)::uuid
        )
      )
      WITH CHECK (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
      );
    """

    execute """
    CREATE POLICY room_members_delete ON room_members
      FOR DELETE
      USING (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
        AND (
          is_tenant_admin(current_setting('app.current_user_id', true)::uuid, tenant_id)
          OR user_id = current_setting('app.current_user_id', true)::uuid
        )
      );
    """

    # ======================================================================
    # room_categories
    # ======================================================================
    execute """
    CREATE POLICY room_categories_select ON room_categories
      FOR SELECT
      USING (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
      );
    """

    execute """
    CREATE POLICY room_categories_insert ON room_categories
      FOR INSERT
      WITH CHECK (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
      );
    """

    execute """
    CREATE POLICY room_categories_update ON room_categories
      FOR UPDATE
      USING (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
      )
      WITH CHECK (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
      );
    """

    execute """
    CREATE POLICY room_categories_delete ON room_categories
      FOR DELETE
      USING (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
      );
    """

    # ======================================================================
    # group_subscriptions (same shape as room_members, using its own columns)
    # ======================================================================
    execute """
    CREATE POLICY group_subscriptions_select ON group_subscriptions
      FOR SELECT
      USING (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
        AND (
          is_tenant_admin(current_setting('app.current_user_id', true)::uuid, tenant_id)
          OR user_id = current_setting('app.current_user_id', true)::uuid
        )
      );
    """

    execute """
    CREATE POLICY group_subscriptions_insert ON group_subscriptions
      FOR INSERT
      WITH CHECK (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
        AND (
          user_id = current_setting('app.current_user_id', true)::uuid
          OR is_tenant_admin(current_setting('app.current_user_id', true)::uuid, tenant_id)
        )
      );
    """

    execute """
    CREATE POLICY group_subscriptions_update ON group_subscriptions
      FOR UPDATE
      USING (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
        AND (
          is_tenant_admin(current_setting('app.current_user_id', true)::uuid, tenant_id)
          OR user_id = current_setting('app.current_user_id', true)::uuid
        )
      )
      WITH CHECK (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
      );
    """

    execute """
    CREATE POLICY group_subscriptions_delete ON group_subscriptions
      FOR DELETE
      USING (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
        AND (
          is_tenant_admin(current_setting('app.current_user_id', true)::uuid, tenant_id)
          OR user_id = current_setting('app.current_user_id', true)::uuid
        )
      );
    """

    # ======================================================================
    # messages (partitioned — policies on the parent apply to every partition)
    # ======================================================================
    execute """
    CREATE POLICY messages_select ON messages
      FOR SELECT
      USING (
        EXISTS (
          SELECT 1 FROM rooms r
          WHERE r.id = messages.room_id
            AND r.tenant_id = current_setting('app.current_tenant_id', true)::uuid
            AND (
              is_tenant_admin(current_setting('app.current_user_id', true)::uuid, r.tenant_id)
              OR EXISTS (
                SELECT 1 FROM room_members rm
                WHERE rm.room_id = r.id
                  AND rm.user_id = current_setting('app.current_user_id', true)::uuid
                  AND rm.tenant_id = r.tenant_id
              )
            )
        )
      );
    """

    execute """
    CREATE POLICY messages_insert ON messages
      FOR INSERT
      WITH CHECK (
        EXISTS (
          SELECT 1 FROM rooms r
          WHERE r.id = messages.room_id
            AND r.tenant_id = current_setting('app.current_tenant_id', true)::uuid
        )
      );
    """

    execute """
    CREATE POLICY messages_update ON messages
      FOR UPDATE
      USING (
        EXISTS (
          SELECT 1 FROM rooms r
          WHERE r.id = messages.room_id
            AND r.tenant_id = current_setting('app.current_tenant_id', true)::uuid
            AND (
              is_tenant_admin(current_setting('app.current_user_id', true)::uuid, r.tenant_id)
              OR EXISTS (
                SELECT 1 FROM room_members rm
                WHERE rm.room_id = r.id
                  AND rm.user_id = current_setting('app.current_user_id', true)::uuid
                  AND rm.tenant_id = r.tenant_id
              )
            )
        )
      )
      WITH CHECK (
        EXISTS (
          SELECT 1 FROM rooms r
          WHERE r.id = messages.room_id
            AND r.tenant_id = current_setting('app.current_tenant_id', true)::uuid
        )
      );
    """

    execute """
    CREATE POLICY messages_delete ON messages
      FOR DELETE
      USING (
        EXISTS (
          SELECT 1 FROM rooms r
          WHERE r.id = messages.room_id
            AND r.tenant_id = current_setting('app.current_tenant_id', true)::uuid
            AND (
              is_tenant_admin(current_setting('app.current_user_id', true)::uuid, r.tenant_id)
              OR EXISTS (
                SELECT 1 FROM room_members rm
                WHERE rm.room_id = r.id
                  AND rm.user_id = current_setting('app.current_user_id', true)::uuid
                  AND rm.tenant_id = r.tenant_id
              )
            )
        )
      );
    """
  end

  def down do
    # Drop policies first (drop is order-independent across tables).
    execute "DROP POLICY IF EXISTS messages_delete ON messages;"
    execute "DROP POLICY IF EXISTS messages_update ON messages;"
    execute "DROP POLICY IF EXISTS messages_insert ON messages;"
    execute "DROP POLICY IF EXISTS messages_select ON messages;"

    execute "DROP POLICY IF EXISTS group_subscriptions_delete ON group_subscriptions;"
    execute "DROP POLICY IF EXISTS group_subscriptions_update ON group_subscriptions;"
    execute "DROP POLICY IF EXISTS group_subscriptions_insert ON group_subscriptions;"
    execute "DROP POLICY IF EXISTS group_subscriptions_select ON group_subscriptions;"

    execute "DROP POLICY IF EXISTS room_categories_delete ON room_categories;"
    execute "DROP POLICY IF EXISTS room_categories_update ON room_categories;"
    execute "DROP POLICY IF EXISTS room_categories_insert ON room_categories;"
    execute "DROP POLICY IF EXISTS room_categories_select ON room_categories;"

    execute "DROP POLICY IF EXISTS room_members_delete ON room_members;"
    execute "DROP POLICY IF EXISTS room_members_update ON room_members;"
    execute "DROP POLICY IF EXISTS room_members_insert ON room_members;"
    execute "DROP POLICY IF EXISTS room_members_select ON room_members;"

    execute "DROP POLICY IF EXISTS rooms_delete ON rooms;"
    execute "DROP POLICY IF EXISTS rooms_update ON rooms;"
    execute "DROP POLICY IF EXISTS rooms_insert ON rooms;"
    execute "DROP POLICY IF EXISTS rooms_select ON rooms;"

    # Disable RLS (parent only for messages; partitions inherit the disabled state).
    execute "ALTER TABLE messages DISABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE group_subscriptions DISABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE room_categories DISABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE room_members DISABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE rooms DISABLE ROW LEVEL SECURITY;"

    # Drop the helper function using the exact signature.
    execute "DROP FUNCTION IF EXISTS is_tenant_admin(uuid, uuid);"
  end
end
