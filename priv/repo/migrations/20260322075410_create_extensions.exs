defmodule BeamChat.Repo.Migrations.CreateExtensions do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS pgcrypto", ""
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm", ""
    execute "CREATE EXTENSION IF NOT EXISTS btree_gist", ""
  end

  def down do
    execute "DROP EXTENSION IF EXISTS btree_gist"
    execute "DROP EXTENSION IF EXISTS pg_trgm"
    execute "DROP EXTENSION IF EXISTS pgcrypto"
  end
end
