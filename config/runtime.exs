import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/beam_chat start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :beam_chat, BeamChatWeb.Endpoint, server: true
end

config :beam_chat, BeamChatWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :beam_chat, BeamChat.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :beam_chat, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :beam_chat, BeamChatWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :beam_chat, BeamChatWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :beam_chat, BeamChatWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  sso_jwt_secret =
    System.get_env("SSO_JWT_SECRET") ||
      raise """
      environment variable SSO_JWT_SECRET is missing.
      Use a long random string (shared with your SSO issuer).
      """

  config :beam_chat, :sso_jwt_secret, sso_jwt_secret

  # Optional comma-separated list of accepted secrets (current first, then
  # previous secret(s)) for zero-downtime SSO secret rotation. Empty/absent
  # falls back to SSO_JWT_SECRET alone. See SECURITY_REVIEW.md P2 #19.
  sso_jwt_secrets =
    System.get_env("SSO_JWT_SECRETS")
    |> case do
      nil -> []
      "" -> []
      value -> value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    end

  config :beam_chat, :sso_jwt_secrets, sso_jwt_secrets

  # Oban queue concurrency limits (SECURITY_REVIEW.md P3 #27). Format:
  # "QUEUE:CONCURRENCY[,QUEUE:CONCURRENCY,...]", e.g. "default:20,payments:10".
  # Unset/empty falls back to the config.exs defaults. Queue names must already
  # exist as atoms (`:default`, `:payments`, ...) — no atom creation from input.
  oban_queues_env = System.get_env("OBAN_QUEUES")

  if is_binary(oban_queues_env) and oban_queues_env != "" do
    oban_queues =
      oban_queues_env
      |> String.split(",")
      |> Enum.map(fn entry ->
        case String.split(entry, ":") do
          [name, concurrency] ->
            try do
              {String.to_existing_atom(String.trim(name)),
               String.to_integer(String.trim(concurrency))}
            rescue
              ArgumentError ->
                raise "invalid OBAN_QUEUES entry #{inspect(entry)}: expected a known " <>
                        "queue name and an integer concurrency (e.g. \"default:10\")"
            end

          _ ->
            raise "invalid OBAN_QUEUES entry #{inspect(entry)}: expected " <>
                    "QUEUE:CONCURRENCY (e.g. \"default:10\")"
        end
      end)

    config :beam_chat, Oban, queues: oban_queues
  end

  # LiveKit: required in production so we never accidentally use dev keys.
  livekit_url =
    System.get_env("LIVEKIT_URL") ||
      raise """
      environment variable LIVEKIT_URL is missing.
      Should be the public WebSocket URL the browser will connect to,
      e.g. wss://livekit.example.com
      """

  livekit_api_key =
    System.get_env("LIVEKIT_API_KEY") ||
      raise "environment variable LIVEKIT_API_KEY is missing."

  livekit_api_secret =
    System.get_env("LIVEKIT_API_SECRET") ||
      raise "environment variable LIVEKIT_API_SECRET is missing."

  config :livekit,
    api_key: livekit_api_key,
    api_secret: livekit_api_secret,
    url: livekit_url

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :beam_chat, BeamChat.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
