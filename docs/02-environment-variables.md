# 02 — Environment Variables

Every runtime variable the application reads, where it is used, and what
happens when it is missing. The canonical template is
[`.env.example`](../.env.example) at the app root.

## Reading model

- `config/runtime.exs` runs for **all** environments after compilation,
  before the system starts. It is the only place prod secrets are read.
- Dev/test fall back to values in `config/dev.exs` / `config/test.exs`
  when an env var is absent.
- In production, `config/runtime.exs` **raises** at boot when a required
  variable is missing — the app refuses to start with a clear message
  rather than booting half-configured.

## Required in production

These raise at boot if unset (`config/runtime.exs`):

| Variable | Purpose | Example |
|---|---|---|
| `DATABASE_URL` | Postgres connection string | `postgresql://user:pass@host:5432/beam_chat_prod` |
| `SECRET_KEY_BASE` | Signs/encrypts cookies and sessions | `mix phx.gen.secret` output |
| `SSO_JWT_SECRET` | HS256 secret shared with your SSO issuer (`/api/sso/exchange`) | 32+ random chars |
| `LIVEKIT_URL` | Public WebSocket URL browsers connect to | `wss://livekit.example.com` |
| `LIVEKIT_API_KEY` | LiveKit API key | (from your LiveKit setup) |
| `LIVEKIT_API_SECRET` | LiveKit API secret | (from your LiveKit setup) |

In the swarm stack these are injected by `docker-compose.swarm.yml` from
the host `.env` (`--env-file .env`) — see [04 — Deployment](./04-deployment-docker-swarm.md).

## Optional / environment-specific

| Variable | Default | Notes |
|---|---|---|
| `PHX_SERVER` | — | Set `true` to bind the HTTP server (`bin/beam_chat start`); the Docker image sets it for you |
| `PHX_HOST` | `"example.com"` (prod) | Public hostname; used in `Endpoint.url/0` |
| `PORT` | `4000` | HTTP port |
| `POOL_SIZE` | `10` | Ecto pool size |
| `ECTO_IPV6` | — | `true`/`1` enables `:inet6` socket options |
| `DNS_CLUSTER_QUERY` | — | DNS query for Phoenix pub/sub auto-clustering (e.g. `tasks.beam_chat_app` in swarm) |
| `RELEASE_COOKIE` | — | Erlang distribution cookie; all replicas must share it (set via `rel/env.sh.eex` when present) |
| `SSO_JWT_SECRETS` | — | Comma-separated accepted secrets (current first) for zero-downtime SSO secret rotation |
| `OBAN_QUEUES` | config defaults | `QUEUE:CONCURRENCY[,QUEUE:CONCURRENCY]` e.g. `default:20,payments:10`; unknown queue names fail startup |
| `MAILGUN_API_KEY` / `MAILGUN_DOMAIN` | — | Magic-link email (dev uses the local mailbox at `/dev/mailbox`) |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | — | Assent OAuth (Google) |
| `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` | — | Assent OAuth (GitHub) |
| `PAYSTACK_SECRET_KEY` / `PAYSTACK_PUBLIC_KEY` / `PAYSTACK_BASE_URL` | `https://api.paystack.co` | Wallet top-ups |
| `MPESA_CONSUMER_KEY` / `MPESA_CONSUMER_SECRET` / `MPESA_SHORTCODE` / `MPESA_PASSKEY` / `MPESA_BASE_URL` | sandbox base URL | M-Pesa Daraja STK push |
| `MPESA_STK_CALLBACK_URL` / `MPESA_CALLBACK_SECRET` | — | Webhook URL **must include** the callback secret in the path; an empty secret **fails closed** (403) in prod |

## Swarm-only deployment variables

Consumed by `docker-compose.swarm.yml` at deploy time (interpolated by
`docker stack deploy --env-file .env`), not by the app itself:

| Variable | Purpose |
|---|---|
| `PHX_HOST` | App FQDN; Traefik `Host(...)` rule + ACME cert |
| `LIVEKIT_HOST` | LiveKit signaling FQDN; Traefik TCP `HostSNI(...)` rule + ACME cert |
| `DB_USER` / `DB_PASSWORD` | Postgres credentials for the swarm Postgres service |
| `ACME_EMAIL` | Let's Encrypt account email |
| `RELEASE_COOKIE` | Erlang distribution cookie (all app replicas) |
| `IMAGE_TAG` | Image tag to deploy (set by CI to `$CI_COMMIT_SHORT_SHA`) |
| `CI_PROJECT_PATH` | Namespaces the image name `registry.gitlab.com/${CI_PROJECT_PATH}` |

## Dev/test defaults (not required)

- **Dev** (`config/dev.exs`): DB `postgres:postgres@localhost:5432/beam_chat_dev`;
  fixed dev `secret_key_base`; `LIVEKIT_URL`/keys from `.env.example`
  (`ws://localhost:7880`, `devkey`/`secret`).
- **Test** (`config/test.exs`): DB `postgres:postgres@<PGHOST|localhost>:5432/beam_chat_test`;
  `PGHOST` overrides the host (GitLab CI sets it to the `postgres` service
  alias); Oban runs `:inline` with plugins cleared; fixed test
  `sso_jwt_secret`.

## Secret handling rules

- `.env` is gitignored — never commit it.
- `.env.example` is a template only; real secrets come from your secrets
  store (GitLab CI masked variables, Vault, Docker Swarm secrets).
- The Docker image **never** bakes secrets in: the `Dockerfile` only
  enables `PHX_SERVER=true`; everything else comes from the environment at
  runtime.
