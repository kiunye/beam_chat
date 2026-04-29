defmodule BeamChat.Repo.Migrations.CreateCoreIdentityAndRooms do
  use Ecto.Migration

  def change do
    create table(:room_categories, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :slug, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:room_categories, [:slug])

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :username, :text, null: false
      add :email, :text
      add :phone, :text
      add :password_hash, :text
      add :avatar_url, :text
      add :first_name, :text
      add :last_name, :text
      add :role, :text, null: false, default: "member"
      add :sso_provider, :text
      add :sso_uid, :text
      add :metadata, :map, null: false, default: fragment("'{}'::jsonb")
      add :is_banned, :boolean, null: false, default: false
      add :ban_reason, :text
      add :last_seen_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    execute """
            ALTER TABLE users ADD COLUMN full_name text GENERATED ALWAYS AS (
              COALESCE(
                NULLIF(BTRIM(COALESCE(first_name, '') || ' ' || COALESCE(last_name, '')), ''),
                username
              )
            ) STORED;
            """,
            "ALTER TABLE users DROP COLUMN IF EXISTS full_name"

    create unique_index(:users, [:username])

    create unique_index(:users, [:email],
             name: :users_email_unique,
             where: "email IS NOT NULL"
           )

    create unique_index(:users, [:phone],
             name: :users_phone_unique,
             where: "phone IS NOT NULL"
           )

    execute "CREATE INDEX users_username_trgm ON users USING gin (username gin_trgm_ops)"

    create unique_index(:users, [:sso_provider, :sso_uid],
             name: :users_sso_unique,
             where: "sso_provider IS NOT NULL AND sso_uid IS NOT NULL"
           )

    create constraint(:users, :users_role_check, check: "role IN ('member','moderator','admin')")

    create table(:rooms, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :slug, :text, null: false
      add :description, :text
      add :category_id, references(:room_categories, type: :binary_id, on_delete: :nilify_all)
      add :owner_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :type, :text, null: false, default: "public"
      add :password_hash, :text
      add :is_paid, :boolean, null: false, default: false
      add :price, :decimal, precision: 12, scale: 2
      add :currency, :text, default: "KES"
      add :max_members, :integer, default: 500
      add :age_restriction, :integer
      add :metadata, :map, null: false, default: fragment("'{}'::jsonb")
      add :is_archived, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:rooms, [:slug])

    execute "CREATE INDEX rooms_name_trgm ON rooms USING gin (name gin_trgm_ops)"

    create index(:rooms, [:id], name: :rooms_active_idx, where: "is_archived = FALSE")

    create constraint(:rooms, :rooms_type_check,
             check: "type IN ('public','private','secret','paid')"
           )

    create table(:room_members, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :text, null: false, default: "member"
      add :joined_at, :utc_datetime, null: false, default: fragment("now()")
      add :expires_at, :utc_datetime
    end

    create unique_index(:room_members, [:room_id, :user_id])
    create index(:room_members, [:user_id], name: :room_members_user_idx)

    create index(:room_members, [:expires_at],
             name: :room_members_expires_idx,
             where: "expires_at IS NOT NULL"
           )

    create constraint(:room_members, :room_members_role_check,
             check: "role IN ('member','moderator','owner')"
           )
  end
end
