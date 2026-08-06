# 04 — Deployment (Docker Swarm)

Production runs as a **Docker Swarm stack** fronted by **Traefik**
(TLS), with a **GitLab CI** pipeline building and shipping the image.
This document is the operational contract — read it alongside
[`docker-compose.swarm.yml`](../docker-compose.swarm.yml),
[`docker-compose.bootstrap.yml`](../docker-compose.bootstrap.yml),
[`livekit_config.yaml`](../livekit_config.yaml), and
[`.gitlab-ci.yml`](../../.gitlab-ci.yml) at the repo root.

## Topology

```
                        ┌──────────────────────── swarm managers ────────────────────────┐
 Browser ──https──▶ Traefik :443 ──▶ app :4000 (3 replicas, sticky cookie)               │
 Browser ──wss───▶  Traefik :7880 ──▶ livekit :7880 (signaling, TLS via TCP router)      │
 LiveKit media ──▶ livekit :7881/tcp + 7882/udp (host mode, direct — NOT via Traefik)    │
 app ──▶ postgres :5432 (Oban jobs live here too — no Redis)                             │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

- **TLS** is terminated by Traefik with Let's Encrypt certificates using
  the **HTTP-01** challenge (not TLS-ALPN-01): TLS-ALPN-01 can only be
  validated on port 443, but LiveKit signaling terminates on :7880.
  HTTP-01 validates both domains via port 80 — so DNS for `PHX_HOST` and
  `LIVEKIT_HOST` must point at the swarm managers and **port 80 must be
  reachable from the internet**.
- **LiveKit media** (ICE/UDP 7882 + RTC TCP 7881) is published with
  `mode: host` on the LiveKit node — Swarm's routing mesh is unreliable
  for UDP (PRD §11.2). `rtc.use_external_ip: true` (see
  `livekit_config.yaml`) requires that node to have a public IP / NAT
  forwarding; LiveKit detects its external IP via STUN at startup.
- **No Redis**: Oban persists jobs in PostgreSQL. Pub/sub clustering uses
  `dns_cluster` (`DNS_CLUSTER_QUERY=tasks.beam_chat_app`).
- **Sticky sessions** are required for LiveView WebSockets and enabled via
  the Traefik `sticky.cookie` service label.
- **Per-replica Erlang nodes**: `rel/env.sh.eex` derives
  `RELEASE_NODE="beam_chat@${HOSTNAME}"` at boot, so replicas never share a
  fixed node name; `RELEASE_COOKIE` must be shared by all replicas and is
  exported only when set.

## Host prerequisites (before the first deploy)

On each swarm host, pre-provision (documented in the compose header and
`.gitlab-ci.yml`):

1. `~/beam_chat/.env` containing **all** required variables
   (see [02 — Environment Variables](./02-environment-variables.md)):
   `DATABASE_URL, SECRET_KEY_BASE, RELEASE_COOKIE, SSO_JWT_SECRET,
   LIVEKIT_API_KEY, LIVEKIT_API_SECRET, LIVEKIT_URL, LIVEKIT_HOST,
   MPESA_CONSUMER_KEY, MPESA_CONSUMER_SECRET, PAYSTACK_SECRET_KEY, DB_USER,
   DB_PASSWORD, ACME_EMAIL, PHX_HOST`.
2. An SSH deploy user (`deploy@`) with docker access.
3. Swarm node labels on managers:
   - LiveKit node: `docker node update --label-add livekit=true <node-id>`
   - Postgres node: `docker node update --label-add db=true <node-id>`
4. Firewall openings: `80`/`443` on managers; `7880/tcp` on the manager
   running Traefik; `7881/tcp` + `7882/udp` on the LiveKit node.

`docker stack deploy` does **not** auto-read a `.env` file — every deploy
passes `--env-file .env` explicitly (CI does this; see below).

## CI deploy flow (staging and production)

The deploy jobs (`.gitlab-ci.yml`) scp
`docker-compose.swarm.yml`, `docker-compose.bootstrap.yml`, and
`livekit_config.yaml` to `~/beam_chat/` on the host, then:

1. **Registry login on the host** — `CI_REGISTRY_PASSWORD` is streamed
   over ssh via stdin (`echo "$CI_REGISTRY_PASSWORD" | ssh ... "docker login
   -u ... --password-stdin ..."`) so the password never appears in a remote
   process table or on the runner's command line. `|| exit 1` fails the job
   on a bad login.
2. **Decide migrate-before vs bootstrap**:
   - `db_migrated` probes `to_regclass('public.schema_migrations')` via a
     `postgres:16-alpine` psql container on the stack network (rewriting
     `ecto://` → `postgres://`).
   - **Already migrated** → run migrations **before** `docker stack deploy`
     (a boot crash after deploy would trigger start-first rollback and
     silently strand the stack on the previous image with the new schema).
   - **Fresh DB** → deploy with `docker-compose.bootstrap.yml` (app pinned
     to `replicas: 0` so it cannot crash-loop against missing tables), run
     migrations, then `docker service scale <stack>_app=3`.
3. **Migrations** run in a one-shot container:
   ```bash
   docker run --rm --network "<stack>_beam_net" --env-file .env \
     <image> eval 'BeamChat.Release.migrate()'
   ```
   `BeamChat.Release.migrate/0` uses `Application.load/1` (not
   `ensure_all_started`) so the one-shot container never starts a second
   VM that would bind the endpoint / race the app's port. Retried up to
   10 times × 5 s for postgres convergence, then the job fails.
4. **Convergence guard** — after deploy, poll
   `docker service ps <stack>_app --filter current-state=running -q` for
   up to 60 s; if no task ever runs, `docker service update --force` the
   app service.

Deploy triggers: **staging** on `main`; **production** is a **manual** job
on tags. Placeholder URLs (`staging.beamchat.example.com`,
`beamchat.example.com`) in the `environment:` blocks must be replaced with
real URLs, and CI variables set:
`SSH_PRIVATE_KEY` / `SSH_PRIVATE_KEY_PROD`, `STAGING_HOST` / `PROD_HOST`
(ssh hostnames), `STAGING_HOSTNAME` / `PROD_HOSTNAME` (public FQDNs used
for `PHX_HOST`).

## Building the image

`.gitlab-ci.yml` `build` job: `docker build -t <image>:<sha> -t
<image>:latest ./beam_chat` with BuildKit inline cache, then pushes both
tags. Build context is the **app root** (`./beam_chat`), where the
`Dockerfile` lives.

Key `Dockerfile` facts:

- **Alpine lockstep**: the builder (`elixir:1.19.5-alpine`) and the runtime
  (`alpine:3.23`) **must stay on the same Alpine major version**. The BEAM's
  crypto NIF is compiled against the builder's OpenSSL; on a mismatched
  runtime OpenSSL the image dies at boot with
  `Error relocating ... EVP_PKEY_sign_message_init: symbol not found`.
  Bump both stages together, never one alone.
- `PHX_SERVER=true` is baked in (`ENV`), so the image starts the web server
  with `CMD ["start"]`; healthcheck is `wget -qO- http://localhost:4000/health`.
- Runs as non-root `app` user; secrets are **never** baked in.
- `mix release` evaluates `rel/env.sh.eex`, so `rel/` must be copied before
  the release step (it is, in the Dockerfile).

## Manual deploy (host-side, without CI)

```bash
# on the swarm host, from ~/beam_chat/:
docker login -u <user> --password-stdin registry.gitlab.com   # if not already logged in
docker stack deploy --env-file .env --compose-file docker-compose.swarm.yml \
  --with-registry-auth beam_chat_prod
```

Then verify: `docker service ps beam_chat_prod_app`, `docker stack ps
beam_chat_prod`, and `curl https://<PHX_HOST>/health` →
`{"status":"ok","node":"..."}`.

## Rollback

- App replicas use `update_config: order: start-first, failure_action:
  rollback` — a failing deploy automatically rolls back to the previous
  image.
- The CI migrate-before-deploy ordering (see above) prevents the
  stranded-schema footgun.
- To roll back manually: `docker service update --rollback
  <stack>_app` (deploys the previously deployed spec/image).
