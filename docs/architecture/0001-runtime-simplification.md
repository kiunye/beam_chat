# ADR 0001 — Runtime simplification: remove Horde, Broadway, and the RoomServer layer

- Status: accepted
- Date: 2026-08-04
- Branch: `fix/p3-hardening`

## Context

A Mode B architecture review of the messaging runtime concluded that the
distributed-messaging machinery was adding complexity without a corresponding
operational need:

- **Horde + libcluster** cluster registries and dynamic supervisors were used
  solely to host per-room `RoomServer` GenServers that owned *disposable*
  ephemeral state (a bounded members cache and typing indicators). The app has
  no multi-node deployment today; Phoenix.Presence already replicates
  membership over `BeamChat.PubSub`, and typing is a fire-and-forget broadcast.
- **Broadway** staged validate → moderate → batch-persist → broadcast, but the
  only producers are LiveView/context callers on the same node, and the batch
  window (50 messages / 5 s) adds latency and an asynchronous failure surface
  (errors were logged and dropped, never surfaced to the sender).
- The `:moderation_rules` ETS cache had **no supervised owner**: it was created
  lazily from the hot path and recreated every 5 minutes by the Oban cron
  refresh job, so the table and its owner process were transient.

## Decisions

1. **Supervise the moderation-rule cache.** `RuleEngine` becomes a GenServer
   that owns the named `:moderation_rules` ETS table for the lifetime of the
   application. The Oban cron job only refreshes the cache; the hot path never
   creates the table.

2. **Remove Horde and the RoomServer layer.** `RoomServer` and its Horde
   registry/dynamic supervisor are deleted. Room membership is Phoenix.Presence
   (`BeamChatWeb.RoomPresence`) alone. Typing indicators are PubSub broadcasts
   on the room topic, rate-limited client-side (the LiveView re-broadcasts at
   most every 2.2 s while typing, matching the previous server-side throttle).
   `libcluster` and `horde` are removed from the dependency tree; `dns_cluster`
   stays (it drives Phoenix PubSub auto-clustering).

3. **Remove Broadway.** `Rooms.send_message/3` and `Direct.send_message/3`
   perform validate → moderate → persist → broadcast synchronously in the
   caller's process and return `{:ok, row}` or `{:error, reason}` — including
   `{:error, {:blocked, reason}}` — so LiveViews can surface moderation and
   persistence failures to the sender. The batch `insert_all` write path is
   preserved as a helper but is now exercised with single-message lists.

4. **Make the M-Pesa pending-expiry watchdog durable.** The fire-and-forget
   `spawn` timer is replaced by an Oban-scheduled job (`MpesaPendingExpiry`)
   that runs once after the 5-minute window and flips still-pending
   transactions to `failed`. A scheduled job survives node restarts; the
   spawned process did not.

5. **Extract shared pagination.** The duplicated page/limit normalization and
   page-count helpers in `BeamChat.Rooms` and `BeamChat.Direct` move to a
   single `BeamChat.Pagination` module. Return shapes are unchanged.

## Consequences

- Fewer supervision-tree children: the Horde registry/supervisor, Broadway
  pipeline, and per-room processes are gone.
- Message send becomes synchronous (a single-row insert + PubSub broadcast in
  the LiveView process). Senders get immediate, specific errors instead of
  silent drops.
- Typing is no longer throttled server-side by a per-room process; the
  client-side 2.2 s re-broadcast cadence preserves the old wire behaviour.
- The ETS rule cache can no longer vanish between cron refreshes.
- M-Pesa pending transactions are guaranteed to expire even across restarts.

## Deferred (not part of this ADR)

- Un-partitioning the `messages` table (destructive migration).
- Removing the `rate_limit` rule-type no-op and unused content-type variants.
- Committing the security-review and spec documents referenced by code comments.
