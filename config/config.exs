# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :beam_chat,
  ecto_repos: [BeamChat.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :beam_chat, Oban,
  repo: BeamChat.Repo,
  queues: [default: 10, payments: 5],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       # Flip expired group_subscriptions to "expired" (SECURITY_REVIEW.md P2 #13)
       {"0 * * * *", BeamChat.Workers.ExpireSubscriptions},
       # Keep the ETS moderation rule cache fresh (SECURITY_REVIEW.md P2 #21)
       {"*/5 * * * *", BeamChat.Workers.RefreshModerationCache},
       # Bound the lifetime of pending M-Pesa top-ups (SECURITY_REVIEW.md P1 #10)
       {"*/5 * * * *", BeamChat.Payments.ObanWorkers.MpesaPendingExpiry}
     ]}
  ]

config :beam_chat, :allow_dev_wallet_credit, false

# Boot-time gate for the dev wallet-credit escape hatch (SECURITY_REVIEW.md
# P2 #20): computed from the config environment, so it is only ever true in
# dev. Prod/test builds bake `false` here, which means a stray
# `allow_dev_wallet_credit: true` left in a prod config can never enable
# non-staff wallet credit at runtime.
config :beam_chat, :dev_wallet_credit_build, config_env() == :dev

# Usernames that may not be self-claimed via OAuth/SSO/registration. Prevents
# phishing/impersonation of staff roles and system accounts. See SECURITY_REVIEW.md
# P1 #12. Hosts may add to this list at runtime via Application.put_env.
config :beam_chat, :reserved_usernames, [
  # Generic privileged names
  "admin",
  "administrator",
  "root",
  "superuser",
  "system",
  "support",
  "staff",
  "moderator",
  "mod",
  "owner",
  "official",
  # Brand-internal
  "beam_chat",
  "beamchat",
  "beam-chat",
  "beamtalk",
  # Common abuse handles
  "null",
  "undefined",
  "none",
  "anonymous",
  "anon",
  # Reserved pronouns/safety
  "everyone",
  "here",
  "channel",
  "all"
]

config :beam_chat, :paystack,
  secret_key: System.get_env("PAYSTACK_SECRET_KEY", ""),
  public_key: System.get_env("PAYSTACK_PUBLIC_KEY", ""),
  base_url: System.get_env("PAYSTACK_BASE_URL", "https://api.paystack.co")

config :beam_chat, :mpesa,
  consumer_key: System.get_env("MPESA_CONSUMER_KEY", ""),
  consumer_secret: System.get_env("MPESA_CONSUMER_SECRET", ""),
  shortcode: System.get_env("MPESA_SHORTCODE", ""),
  passkey: System.get_env("MPESA_PASSKEY", ""),
  base_url: System.get_env("MPESA_BASE_URL", "https://sandbox.safaricom.co.ke"),
  stk_callback_url: System.get_env("MPESA_STK_CALLBACK_URL", ""),
  # Shared secret embedded in the callback URL path. **Required in prod** —
  # empty default fails closed. See BeamChatWeb.Plugs.MpesaWebhookAuth.
  callback_secret: System.get_env("MPESA_CALLBACK_SECRET", "")

config :beam_chat,
  oauth: [
    google: [
      client_id: System.get_env("GOOGLE_CLIENT_ID", ""),
      client_secret: System.get_env("GOOGLE_CLIENT_SECRET", "")
    ],
    github: [
      client_id: System.get_env("GITHUB_CLIENT_ID", ""),
      client_secret: System.get_env("GITHUB_CLIENT_SECRET", "")
    ]
  ]

config :beam_chat, :sso_jwt_secret, "dev_sso_jwt_secret_change_me_min_32_chars___"

# Ordered list of accepted SSO HS256 secrets: current first, then previous
# secret(s) during rotation. When empty, `BeamChat.SSO` falls back to the
# single `:sso_jwt_secret`. See SECURITY_REVIEW.md P2 #19.
config :beam_chat, :sso_jwt_secrets, []

# LiveKit: read from env in dev; runtime.exs may override in prod.
# In dev the values default to livekit-server's --dev mode (devkey/secret).
config :livekit,
  api_key: System.get_env("LIVEKIT_API_KEY", "devkey"),
  api_secret: System.get_env("LIVEKIT_API_SECRET", "secret"),
  url: System.get_env("LIVEKIT_URL", "ws://localhost:7880")

config :assent, :http_adapter, Assent.HTTPAdapter.Req

# Configure the endpoint
config :beam_chat, BeamChatWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BeamChatWeb.ErrorHTML, json: BeamChatWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: BeamChat.PubSub,
  live_view: [signing_salt: "7c9+t9Cl"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :beam_chat, BeamChat.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  beam_chat: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{
      "NODE_PATH" => [
        Path.expand("../deps", __DIR__),
        Path.expand("../assets/node_modules", __DIR__),
        Mix.Project.build_path()
      ]
    }
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  beam_chat: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :id, :reason]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
