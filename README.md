# BeamChat

Real-time chat platform (Phoenix / LiveView).

* Run `mix setup` to install and setup dependencies
* Run `docker composer up -d` to start the db server
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix

---

## LiveKit (audio/video) — local development

The chat room page shows a **Video room** panel in the sidebar. Clicking
**Join video** opens a LiveKit audio/video session for the room; **Leave
video** hangs up.

### Prerequisites

The dev stack expects a local LiveKit server. The included
`docker-compose.yml` starts one for you alongside Postgres:

```bash
docker compose up -d        # postgres + livekit
cd beam_chat && mix setup
mix phx.server
```

The `livekit` service runs with its built-in `--dev` defaults:
`LIVEKIT_API_KEY=devkey`, `LIVEKIT_API_SECRET=secret`,
`LIVEKIT_URL=ws://localhost:7880`. These match the values in
[`.env.example`](.env.example) so the Phoenix server can mint tokens.

### Configuring the browser-side URL

In dev the browser connects to `ws://localhost:7880`. In production this
should be the public WebSocket URL behind TLS (e.g. `wss://livekit.example.com`).
The value comes from `LIVEKIT_URL` (the env var read at startup) and is
delivered to the client as part of the token payload — no per-user config
required.

### How tokens are issued

`BeamChat.Video.TokenService` ([`lib/beam_chat/video/token_service.ex`](lib/beam_chat/video/token_service.ex))
wraps the third-party `Livekit.AccessToken` module and:

- scopes each token to one room (`Grants.join_room(room_id)`)
- grants `roomJoin: true`, `canPublish: true`, `canSubscribe: true`
- uses identity `"user-" <> user_id` (no PII in the token)
- expires the token in 1 hour (re-mint on rejoin)
- is **never** logged; we only return the JWT via `push_event/3`

Banned users and viewers without room access get a `{:error, :no_access}`
or no token at all — see `BeamChat.Rooms.AccessPolicy.can_video?/2`.

### How the client connects

`assets/js/hooks/live_kit_room.js` is registered as the `LiveKitRoom` hook
on the `#video-panel` element. When the LiveView pushes
`livekit_connect` with the token payload, the hook calls
`Room.connect(url, token)` and surfaces state back to the LiveView via
`video_connected` / `video_disconnected` / `video_error` events. The
hook disconnects cleanly on `destroyed()` (page navigation, log-out).

### Verifying locally

1. `docker compose up -d` (Postgres + LiveKit)
2. `mix deps.get && mix setup`
3. `mix phx.server`
4. Open two browser windows, log in as two different users, both join
   the same room. Click **Join video** in both windows. Grant
   camera/mic when prompted. You should see both participants' video
   tiles.

### Production notes (PRD §11.2)

- **UDP networking** — LiveKit media flows over UDP. On Docker Swarm the
  `livekit` service must use `host` publishing for ports 7881/7882 (or
  be pinned to a node and use `--network host`).
- **Traefik sticky sessions** — already required for LiveView WebSockets;
  the same Traefik rules cover the LiveKit signaling connection.
- **Secret rotation** — `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET` should
  come from your secrets store (Vault, GitLab CI masked variables,
  Docker Swarm secrets). The `.env.example` file is a template only;
  never commit real secrets.
- **Token lifetime** — keep TTL short (1h default) so a leaked token
  expires quickly. Users re-mint transparently on disconnect/rejoin.

### Tests

- Elixir unit + LiveView tests: `mix test test/beam_chat/video test/beam_chat_web/live/video_live_test.exs`
- JS hook tests: `cd assets && npm test` (uses Node's built-in test
  runner + jsdom; no extra framework)
