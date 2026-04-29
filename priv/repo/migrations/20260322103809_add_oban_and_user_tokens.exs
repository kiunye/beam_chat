defmodule BeamChat.Repo.Migrations.AddObanAndUserTokens do
  use Ecto.Migration

  def up do
    Oban.Migrations.up()

    create table(:users_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :text, null: false
      add :sent_to, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:users_tokens, [:user_id])
    create unique_index(:users_tokens, [:context, :token])
  end

  def down do
    drop table(:users_tokens)
    Oban.Migrations.down()
  end
end
