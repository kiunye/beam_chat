defmodule BeamChat.Repo.Migrations.DisableRlsOnScopedTables do
  use Ecto.Migration

  # The core identity migration explicitly states "no Row Level Security layer"
  # (see 20260322075411_create_core_identity_and_rooms.exs). RLS was accidentally
  # enabled on several tables (categories, rooms, room_members, messages), blocking
  # seed inserts and ordinary application operations. Disable RLS on all affected
  # tables to match the documented intent. These tables are admin-managed or
  # application-scoped, not tenant-scoped — the CATEGORY_REDESIGN.md RLS plan
  # (which requires tenants, tenant_members, and GUCs) is not yet implemented.
  def change do
    execute "ALTER TABLE categories DISABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE rooms DISABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE room_members DISABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE messages DISABLE ROW LEVEL SECURITY"
  end
end
