import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :beam_chat, BeamChat.Repo,
  username: System.get_env("BEAMCHAT_DB_USERNAME", "beamchat_app"),
  password: System.get_env("BEAMCHAT_DB_PASSWORD", "beamchat_app"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: "beam_chat_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# SECURITY: connect as a non-superuser role so Row Level Security applies in
# tests. Create it with: `mix run priv/repo/setup_app_role.exs`.

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :beam_chat, BeamChatWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "NNJA1XzSEbh8ur76i47rfxvfCZdZ6BCasRalGEcjnkf7PZLfOx4Qy3VfvpROUrrD",
  server: false

# In test we don't send emails
config :beam_chat, BeamChat.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Inline testing executes jobs synchronously. Plugins are cleared so the
# Cron jobs (subscription expiry, moderation cache refresh) never fire
# mid-suite — tests invoke those workers explicitly instead.
config :beam_chat, Oban, testing: :inline, plugins: []

config :beam_chat, :sso_jwt_secret, "test_sso_jwt_secret_min_32_chars______"
