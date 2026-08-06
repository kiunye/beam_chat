# 03 — Testing & Quality

How the project is tested and the quality gate that runs before any change
is considered done (`mix precommit`).

## Quality gate

`mix precommit` is defined in `mix.exs` and runs, in order:

1. `compile --warnings-as-errors`
2. `format` (fixes files, does not fail)
3. `credo --strict`
4. `sobelow --config`
5. `dialyzer --format dialyxir`
6. `deps.unlock --unused`
7. `test`

Run it after all changes and fix any warnings/errors before marking a task
complete.

> **Note:** `mix precommit` prefers the `:test` env (`preferred_envs` in
> `mix.exs`).

## Elixir tests

```bash
mix test                    # whole suite (creates + migrates the test DB)
mix test test/path/to/file.exs
mix test --failed           # re-run last failures
```

Conventions from the project guidelines:

- Always use `start_supervised!/1` to start processes in tests (guaranteed
  cleanup between tests).
- Avoid `Process.sleep/1` / `Process.alive?/1`; wait on
  `Process.monitor/1` DOWN messages instead, and synchronise with
  `_ = :sys.get_state/1` before the next call.
- Use `Phoenix.LiveViewTest` (and `LazyHTML`) for LiveView assertions;
  reference key DOM IDs (`has_element?(view, "#my-form")`) and never assert
  on raw HTML.
- When selectors fail, debug with `LazyHTML.from_fragment/1` + `LazyHTML.filter/2`.

### LiveKit video tests

```bash
mix test test/beam_chat/video test/beam_chat_web/live/video_live_test.exs
```

## JavaScript hook tests

The JS side (LiveKit hook and friends in `assets/js/`) is tested with
Node's built-in test runner + jsdom — no extra framework:

```bash
cd assets
npm test                   # node --test test/hooks/*.test.js
```

`npm ci --omit=dev` in the Docker build installs prod deps only;
`jsdom` is a devDependency.

## CI pipeline (GitLab)

`.gitlab-ci.yml` at the repo root runs:

- **test** — `elixir:1.19-alpine` + `postgres:16-alpine` service:
  `mix test` then `mix credo --strict`.
- **dialyzer** — `mix dialyzer --halt-exit-status`, `allow_failure: true`
  (does not block deploys until types are stable).
- **build** — Docker build + push of `registry.gitlab.com/$CI_PROJECT_PATH`
  tagged with the short SHA and `latest` (only on `main` / tags).
- **deploy_staging** — deploys on `main` pushes (see
  [04 — Deployment](./04-deployment-docker-swarm.md)).
- **deploy_production** — manual job on tags.

## Known baseline (as of the last full run)

- Elixir suite: **151/159 passing**; 8 pre-existing failures in the
  wallet / SSO / chat LiveView suites (unrelated to the deploy pipeline;
  a prior run had 9 — one SSO test was fixed).
- JS hook tests: **6/6 passing**.
- Credo: 3 pre-existing findings in
  `lib/beam_chat/{rooms,direct,wallet}.ex`.

Track these separately from new work — a green diff should not introduce
new failures beyond this baseline.
