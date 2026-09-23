defmodule BeamChat.Repo.Migrations.CreateRadioStations do
  use Ecto.Migration

  # Radio stations: tenant-scoped stream sources published into LiveKit
  # rooms via the LiveKit Ingress service.
  #
  # RLS follows the `rooms` precedent: write policies check only that the
  # row belongs to the tenant GUC (authorization is enforced by the
  # `:radio_manage` permission check in `BeamChat.Streaming`); the select
  # policy additionally allows any member of the tenant to discover and
  # listen to its stations.

  def change do
    create table(:radio_stations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :string
      add :source_type, :string, null: false, default: "url"
      add :source_url, :string
      add :status, :string, null: false, default: "offline"
      add :is_active, :boolean, null: false, default: false
      add :ingress_id, :string
      add :metadata, :map, default: %{}

      add :tenant_id,
          references(:tenants, type: :binary_id, on_delete: :delete_all),
          null: false

      add :room_id, references(:rooms, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:radio_stations, [:slug])
    create index(:radio_stations, [:tenant_id])
    create index(:radio_stations, [:ingress_id])

    execute "ALTER TABLE radio_stations ENABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE radio_stations FORCE ROW LEVEL SECURITY;"

    execute """
    CREATE POLICY radio_stations_select ON radio_stations
      FOR SELECT
      USING (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
      );
    """

    execute """
    CREATE POLICY radio_stations_insert ON radio_stations
      FOR INSERT
      WITH CHECK (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
      );
    """

    execute """
    CREATE POLICY radio_stations_update ON radio_stations
      FOR UPDATE
      USING (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
      )
      WITH CHECK (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
      );
    """

    execute """
    CREATE POLICY radio_stations_delete ON radio_stations
      FOR DELETE
      USING (
        tenant_id = current_setting('app.current_tenant_id', true)::uuid
      );
    """
  end
end
