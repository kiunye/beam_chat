# 05 — Troubleshooting

Common failures and their fixes. If something here doesn't match what you
see, check `docker compose logs` (dev) / `docker service logs` (swarm)
first — the app logs startup problems loudly because `config/runtime.exs`
**raises** on missing production config.

## Boot / release failures

### `Error relocating ... EVP_PKEY_sign_message_init: symbol not found` → `Kernel pid terminated (application_controller)`

The image was built and run on **different Alpine major versions**. The
BEAM's crypto NIF is compiled against the builder's OpenSSL and cannot load
against a different one (e.g. alpine:3.19 OpenSSL 3.1.x vs alpine:3.23
OpenSSL 3.5.x).

**Fix:** keep the `Dockerfile` builder and runtime stages on the same
Alpine major. Verify:

```bash
docker run --rm --entrypoint /bin/sh elixir:1.19.5-alpine -c "cat /etc/alpine-release"
docker run --rm --entrypoint /bin/sh alpine:3.23 -c "cat /etc/alpine-release"
```

Never bump one stage alone.

### `environment variable DATABASE_URL is missing` / `SECRET_KEY_BASE is missing` / ...

Production startup requires `DATABASE_URL`, `SECRET_KEY_BASE`,
`SSO_JWT_SECRET`, `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`
(see [02 — Environment Variables](./02-environment-variables.md)).

**Fix:** ensure the host `.env` (or the service environment) provides them
before `docker stack deploy --env-file .env`. In dev, they fall back to
`config/dev.exs` defaults — no action needed.

### Release runs but nothing binds a port

The image sets `PHX_SERVER=true`, but a **local** `bin/beam_chat start`
does not. `rel/env.sh.eex` deliberately does not set `PHX_SERVER`; start
with:

```bash
PHX_SERVER=true bin/beam_chat start
```

### Migrations: `mix ecto.migrate` fails in the swarm / `psql: FATAL: password authentication failed`

The one-shot migrate container connects via `--network <stack>_beam_net`
with `--env-file .env` and an `ecto://` → `postgres://` URL rewrite. If
auth fails, the `.env` `DATABASE_URL` credentials don't match the
`DB_USER`/`DB_PASSWORD` used by the swarm Postgres service.

**Fix:** keep `DATABASE_URL`'s user/password in sync with `DB_USER` /
`DB_PASSWORD` on the host `.env`.

## Network / LiveKit

### Video tiles never appear; hook reports `video_error`

- **Dev:** confirm the LiveKit container is up and the app has
  `LIVEKIT_URL` matching `.env.example` (`ws://localhost:7880`). The
  browser must reach the signaling URL; in dev that's localhost, in
  production it's `wss://${LIVEKIT_HOST}:7880` (Traefik TCP entrypoint).
- **Prod:** signaling goes `wss://${LIVEKIT_HOST}` → Traefik :7880 →
  livekit:7880. Check the TCP router label
  (`traefik.tcp.routers.livekit.rule=HostSNI(...)`) and that
  `LIVEKIT_HOST` DNS points at the swarm manager.
- **Media:** ICE/UDP is `host`-published on the LiveKit node — the node
  must have a public IP / NAT forwarding (`rtc.use_external_ip: true` in
  `livekit_config.yaml`) and firewalls open for `7881/tcp` + `7882/udp`.
  If media fails but signaling works, this is the usual cause.

### `room: auto_create: true` but joining fails with an auth error

Token TTL is **10 minutes** and tokens are single-room scoped. A token
minted against a different `LIVEKIT_API_KEY`/`LIVEKIT_API_SECRET` than the
server's `LIVEKIT_KEYS` is rejected. Verify key/secret parity between the
app env and `LIVEKIT_KEYS: "${LIVEKIT_API_KEY}: ${LIVEKIT_API_SECRET}"` in
the swarm compose.

## CI / deploy

### Deploy job: `echo "$CI_REGISTRY_PASSWORD" | ssh ... docker login` fails

- `CI_REGISTRY_USER` / `CI_REGISTRY_PASSWORD` are auto-provided by GitLab
  only when the project's Container Registry is enabled.
- The ssh command must be `-u "$CI_REGISTRY_USER" --password-stdin` —
  never pass the password as an argument (it would leak into the remote
  process table). The `|| exit 1` makes login failure fail the job loudly.

### App service never has a running task after deploy

The convergence guard forces `docker service update --force` after 60 s.
If the guard itself fires, look at the service logs:

```bash
docker service ps --no-trunc <stack>_app          # current + previous tasks
docker service logs <stack>_app
```

Common causes: missing env var (boot raise), image pull failure, or the
healthcheck (`wget -qO- http://localhost:4000/health`) failing — the app
service won't be "running" until healthy.

### Fresh stack: app crash-loops against missing `moderation_rules` table

This is exactly what `docker-compose.bootstrap.yml` prevents (app pinned
to `replicas: 0` until migrations complete). If you see it, the bootstrap
override wasn't used — deploy fresh DBs with both compose files, in order
(see [04 — Deployment](./04-deployment-docker-swarm.md)).

## Local dev

### `mix assets.deploy` hangs on Windows

The tailwind/esbuild binaries are platform-specific and the win32 variants
misbehave in interactive shells. On Windows, treat the Docker image build
as the authoritative asset gate and avoid `mix assets.deploy` locally
(use `mix assets.build` for dev).

### Port 4000 already in use

Another `mix phx.server` (or release) is running. Find and stop it, or set
`PORT=4001 mix phx.server`.

### LiveKit dev keys rejected

The dev compose runs LiveKit with `--dev` defaults
(`devkey`/`secret`). If you changed `.env` keys, the app and the server
disagree — keep `.env.example` values for local dev.
