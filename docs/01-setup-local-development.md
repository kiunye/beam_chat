# 01 — Setup & Local Development

How to get BEAM Chat running on your machine.

## Prerequisites

- **Elixir `~> 1.19`** with a compatible Erlang/OTP (Phoenix 1.8 baseline;
  the CI/build image pins `elixir:1.19.5-alpine`)
- **[Docker](https://docs.docker.com/get-docker/)** with Compose v2 — the dev
  stack runs PostgreSQL and LiveKit in containers
- **Node.js + npm** (for `assets/`, required by `mix setup`)

## 1. Start the dev services

The dev services live in `beam_chat/docker-compose.yml` — run them **from
this directory** (the compose file's directory):

```bash
cd beam_chat
docker compose up -d
```

This starts:

| Service | Image | Purpose | Ports |
|---|---|---|---|
| `postgres` | `postgres:16-alpine` | Main database | `5432` |
| `livekit` | `livekit/livekit-server:v1.13.5` | Local LiveKit server (`--dev`) | `7880` (HTTP/WS), `7881` (ICE/TCP), `7882/udp` (ICE/UDP) |

The LiveKit dev server uses LiveKit's built-in `--dev` defaults:
`LIVEKIT_API_KEY=devkey`, `LIVEKIT_API_SECRET=secret`. These match the
values in [`.env.example`](../.env.example) so the Phoenix server can mint
tokens against it. Do not use these keys in production.

## 2. Set up the app

```bash
mix setup
```

`mix setup` runs, in order:

1. `deps.get` — fetch Hex dependencies (includes `livekit`, `oban`,
   `assent`, `joken`, …)
2. `ecto.setup` — create the `beam_chat_dev` database, run migrations,
   seed `priv/repo/seeds.exs`
3. `assets.setup` — install the tailwind/esbuild binaries
4. `assets.build` — compile the app and bundle assets

## 3. Run the server

```bash
mix phx.server
```

Open <http://localhost:4000>. The dev endpoint binds `127.0.0.1:4000` by
default (see `config/dev.exs`).

If you want configuration from a file instead of the shell, copy
`.env.example` to `.env` and adjust values — the app reads the same
variables from either source (see [02 — Environment Variables](./02-environment-variables.md)).

## Local LiveKit (audio/video)

The chat room page shows a **Video room** panel in the sidebar. Clicking
**Join video** opens a LiveKit audio/video session for the room; **Leave
video** hangs up.

- Tokens are issued by `BeamChat.Video.TokenService`
  ([`lib/beam_chat/video/token_service.ex`](../lib/beam_chat/video/token_service.ex)),
  scoped to a single room with identity `"user-" <> user_id` (no PII).
- Default token TTL is **10 minutes** (`@default_ttl_seconds 600`) so a
  leaked token expires quickly; clients re-mint transparently on
  disconnect/rejoin.
- Banned users and viewers without room access get no token (see
  `BeamChat.Rooms.AccessPolicy.can_video?/2`).
- The browser connects to `LIVEKIT_URL` (`ws://localhost:7880` in dev)
  delivered to the client as part of the token payload.

To verify locally: open two browser windows, log in as two users, join the
same room, and click **Join video** in both — you should see both
participants' video tiles after granting camera/mic access.

## Useful commands

```bash
mix phx.server          # run the dev server
mix ecto.reset          # drop + recreate + migrate + seed
mix ecto.migrate        # run pending migrations
iex -S mix phx.server   # run with an IEx shell
docker compose logs -f postgres livekit   # service logs
docker compose down     # stop the dev services (keeps the volume)
```

## Database notes

- Dev defaults: `postgres` / `postgres`, database `beam_chat_dev`,
  host `localhost`, port `5432` — set `DATABASE_URL` to override (see
  `config/dev.exs`).
- The Postgres data volume (`beam_chat_pgdata`) persists across
  `docker compose down`; use `docker compose down -v` to wipe it.
- The app has **no Redis**: Oban job queues run on PostgreSQL
  (`config :beam_chat, Oban, ...`), and pub/sub clustering uses
  `dns_cluster` in production.
