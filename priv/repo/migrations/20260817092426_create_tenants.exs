defmodule BeamChat.Repo.Migrations.CreateTenants do
  use Ecto.Migration

  def change do
    create table(:tenants, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :slug, :text, null: false
      add :metadata, :jsonb, null: false, default: fragment("'{}'::jsonb")

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tenants, [:slug])
  end
end
