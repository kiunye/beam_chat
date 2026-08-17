# Setup a dedicated non-superuser database role for the BeamChat application.
#
# PostgreSQL Row Level Security (see CATEGORY_REDESIGN.md §9) is BYPASSED for
# superusers, so the app must connect as a non-superuser role. This script
# creates `beamchat_app` (password overridable via BEAMCHAT_APP_ROLE_PASSWORD)
# and grants it the privileges it needs on the dev and test databases so it can
# run migrations and ordinary queries while still being subject to RLS.
#
# Run with:  mix run priv/repo/setup_app_role.exs
# Must be run as a role that can CREATE ROLE / GRANT (e.g. the postgres superuser).

alias BeamChat.Repo

role = "beamchat_app"
password = System.get_env("BEAMCHAT_APP_ROLE_PASSWORD", "beamchat_app")
databases = ["beam_chat_dev", "beam_chat_test"]

# Create the role idempotently.
Ecto.Adapters.SQL.query!(Repo, """
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{role}') THEN
    CREATE ROLE #{role}
      LOGIN PASSWORD '#{password}'
      NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
END
$$;
""")

for db <- databases do
  # Allow connecting to the database.
  Ecto.Adapters.SQL.query!(Repo, "GRANT CONNECT ON DATABASE #{db} TO #{role}")

  # Work within the database to grant schema + object privileges.
  Ecto.Adapters.SQL.query!(Repo, "GRANT USAGE, CREATE ON SCHEMA public TO #{role}")
  Ecto.Adapters.SQL.query!(Repo, "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO #{role}")
  Ecto.Adapters.SQL.query!(Repo, "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO #{role}")
  Ecto.Adapters.SQL.query!(Repo, "GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO #{role}")

  # Future objects created by migrations (run as this role) are already owned by
  # it; for objects created by other roles, ensure the role keeps privileges.
  Ecto.Adapters.SQL.query!(Repo,
    "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO #{role}"
  )

  Ecto.Adapters.SQL.query!(Repo,
    "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO #{role}"
  )
end

IO.puts("Created/verified role `#{role}` and granted privileges on #{inspect(databases)}.")
IO.puts("Remember to run migrations:  mix ecto.migrate && MIX_ENV=test mix ecto.migrate")
