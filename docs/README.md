# BEAM Chat — Documentation

Guides for developing, testing, and deploying the BEAM Chat Phoenix
application. The application code lives in the `beam_chat/` directory of
the repository root; all paths below are relative to `beam_chat/` unless
stated otherwise.

## Guides

| Guide | Covers |
|---|---|
| [01 — Setup & Local Development](./01-setup-local-development.md) | Prerequisites, Docker services, database, running the dev server, LiveKit locally |
| [02 — Environment Variables](./02-environment-variables.md) | Every runtime env var: dev defaults, prod requirements, secrets |
| [03 — Testing & Quality](./03-testing-and-quality.md) | Elixir tests, JS hook tests, `mix precommit` gate, known baseline |
| [04 — Deployment (Docker Swarm)](./04-deployment-docker-swarm.md) | Production image, TLS via Traefik, swarm stack, migrations, GitLab CI |
| [05 — Troubleshooting](./05-troubleshooting.md) | Common boot, image, network, and LiveKit failures |

## Architecture

- [ADR 0001 — Runtime simplification](./architecture/0001-runtime-simplification.md):
  removes Horde, Broadway, and the RoomServer layer; supervised rule cache,
  synchronous message sends, durable M-Pesa expiry.

## Quick reference

```bash
# From the app root (beam_chat/):
docker compose up -d     # postgres + livekit (dev)
mix setup                # deps, db, assets
mix phx.server           # http://localhost:4000
mix precommit            # full quality gate (see 03)
```

Production deploys happen through GitLab CI (`.gitlab-ci.yml` at the repo
root); the swarm stack contract is `docker-compose.swarm.yml`. See
[04 — Deployment](./04-deployment-docker-swarm.md).
