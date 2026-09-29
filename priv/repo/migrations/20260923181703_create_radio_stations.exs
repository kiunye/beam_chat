defmodule BeamChat.Repo.Migrations.CreateRadioStations do
  use Ecto.Migration

  # Radio stations (LiveKit feature carried into v2): stream sources
  # published into LiveKit rooms ("radio-" <> slug) via the LiveKit
  # Ingress service. Platform-wide — no tenant boundary, no RLS.

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

      timestamps(type: :utc_datetime)
    end

    create unique_index(:radio_stations, [:slug])
    create index(:radio_stations, [:ingress_id])

    create constraint(:radio_stations, :radio_stations_source_type_check,
             check: "source_type IN ('url','rtmp','whip')"
           )

    create constraint(:radio_stations, :radio_stations_status_check,
             check: "status IN ('offline','starting','live','error')"
           )
  end
end
