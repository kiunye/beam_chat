# BeamChat v2 — Product Requirements Document

*This is a rewrite spec, not a reverse-engineered document. It intentionally narrows scope to what was asked for. A few items from the earlier build are carried over as load-bearing defaults rather than left undefined, and each one is flagged where it appears so it's easy to cut if you don't want it.*

---

## 1. PRD

### 1.1 Scope and what's carried over

The requested scope is: rooms (including paid rooms), a category/subcategory tree, admin and moderator roles, in-platform messaging, Daraja and Paystack payments with room left for Stripe, RBAC with no multi-tenancy, and an admin settings page covering users, payments, and room/category management.

Two things aren't on that list but are load-bearing enough that leaving them undefined would break the rest of the spec, so they're included as carried-over defaults, not new features:

- **Authentication.** RBAC needs an authenticated identity to hang a role off. This spec keeps the four auth paths from the earlier build (password, magic link, OAuth, and a signed-token SSO exchange for an embedding host), since they're working infrastructure, not speculative additions. If you don't need SSO exchange or OAuth for this version, say so and they come out cleanly; nothing else in this document depends on which of the four you keep, as long as at least one survives.
- **The bootstrap admin problem.** RBAC "from the get go" has a chicken-and-egg issue: the first admin has to come from somewhere before anyone can use Settings to promote anyone. §2.1 covers how that's resolved.

Video/audio calling, LiveKit, and multi-tenancy are explicitly out of scope for this rewrite. They existed in the prior build; nothing here assumes they'll come back.

### 1.2 What it is

BeamChat v2 is a real-time chat platform for a single organization or community (no tenant boundary, one deployment, one set of admins). It organizes conversation into rooms, which are grouped into an admin-defined category and subcategory tree, supports free and paid rooms funded by a wallet, and gives admins a single settings surface to run the platform: user roles, payment provider configuration, and the room/category structure itself.

### 1.3 Why it's shaped this way

The category/subcategory tree is a direct reuse of the self-referencing hierarchy from the original Kiambu County redesign, but decoupled from the thing it was built to solve. In the original design, every level of the org chart *was* a room, because the use case needed county → subcounty → ward → group to each be its own chat space. That's one valid shape, not the general one. Here, **Category is the tree, Room is a separate thing that hangs off a node in that tree.** A category can have zero, one, or many rooms in it, and a subcategory can nest as deep as an admin wants. This is the more general version of the same idea: a gaming community can have Category "Shooters" → Subcategory "Valorant" with three rooms underneath it ("General," "LFG," "Trade"), and nothing about the tree structure needs to know or care that it isn't a government org chart.

Dropping multi-tenancy removes the two-layer defense the original design leaned on (application-level checks plus database-level Row Level Security backing them up). Without tenant boundaries to leak across, RLS has nothing to enforce, so this version relies on RBAC checks at the application layer alone. That's a real tradeoff, not a free simplification, and §4.5 names what it costs and what's done to keep the single remaining layer honest.

The payment side keeps a wallet as the thing rooms actually charge against, rather than having rooms charge a payment provider directly. That indirection is what makes "leave room for Stripe" achievable without speculative Stripe code today: Daraja and Paystack are two implementations behind one small provider interface (initiate a top-up, confirm it, handle its webhook), and the wallet, the subscription logic, and every room-access check are written against the wallet, not against either provider. Adding Stripe later means writing a third implementation of that same interface; it doesn't touch rooms, subscriptions, or access logic at all.

### 1.4 What it does, in one pass

- **Authenticates** users and assigns each one a platform-wide role: member, moderator, or admin.
- **Organizes rooms** into an admin-managed category and subcategory tree of arbitrary depth.
- **Runs rooms** as public, private, secret, or paid, each with its own membership roles (owner, moderator, member) layered under the platform-wide role.
- **Delivers real-time messaging** in rooms and in 1:1 conversations between users.
- **Moderates content** with a configurable rule set (word filters, link filters, pattern matching) and a logged trail of what got blocked, flagged, or actioned and by whom.
- **Runs a wallet.** Users top up via Paystack or M-Pesa (Daraja STK push); a paid room is unlocked by spending wallet balance on a time-boxed subscription to it.
- **Gives admins one settings surface** to manage user roles and bans, configure which payment providers are live, and create or restructure categories, subcategories, and rooms.

---

## 2. User Flow

### 2.1 Roles and the bootstrap problem

Two role layers exist, and they compose rather than compete:

- **Platform role**, on the user record: `member` (default on signup), `moderator`, `admin`. This is global; there's no per-category or per-subcategory override of it; giving someone a per-node override is exactly the kind of premature flexibility this spec avoids since nothing in the requested scope calls for it.
- **Room role**, on a room membership record: `member`, `moderator`, `owner`. Room-scoped, independent of platform role. A member with no platform privileges at all can still own and moderate rooms they created.

A platform `admin` can do anything anywhere: full settings access, and full access to every room regardless of its membership list or type. A platform `moderator` can act on any room's content (view flagged messages, mute or remove members, apply moderation actions) but cannot reach Settings; user management, payment configuration, and category/room structure are admin-only. A room `owner` or room `moderator` has those same content-moderation powers, but scoped to that one room only.

**Bootstrap:** the very first admin can't be created through Settings, because Settings requires an admin to already exist. This is solved one of two ways, and either is acceptable, so pick one before launch:

- A deploy-time environment variable names an email address; on first login (any auth method) with that exact email, the account is promoted to `admin` automatically, once.
- A one-off CLI task, run by whoever has server access, promotes an existing user to `admin` directly against the database.

Either way, once one admin exists, every subsequent admin or moderator is granted through Settings by an existing admin. Nobody self-promotes.

### 2.2 Getting in

Standard auth, gated the same way regardless of which of the four carried-over methods is used: password (bcrypt-hashed, 8 to 72 characters), magic link (identical response whether or not the email exists, so the flow never confirms which addresses are registered), OAuth, or the signed SSO token exchange. Username is unique, 2 to 64 characters, restricted to lowercase letters, digits, and underscores, and checked against a reserved-name list regardless of which auth path created the account, so an OAuth signup can't claim `admin` or `support` any more than a password signup can.

A banned user is blocked from every write action (sending a message, joining a room, spending from the wallet) by a fresh, per-request database check, not by trusting whatever role or ban status was loaded into the session at login. This is a direct, deliberate carryover from a real incident class in the prior build: a session that outlives a ban is a session with privileges nobody meant it to keep.

### 2.3 Browsing categories and rooms

Categories and subcategories are visible to every authenticated user by default; they're a navigation structure, not an access boundary. A category can be marked hidden by an admin (useful for a category that's mid-setup and not ready to announce), in which case only admins and moderators see it in the browse view.

Room visibility is governed by the room itself, independent of which category it sits in:

- **Public:** anyone finds and enters it, including a category that's otherwise hidden.
- **Private:** listed, but joining requires an explicit room-membership grant from the room's owner or a platform admin/moderator.
- **Secret:** not listed at all; reachable only by direct link plus an explicit membership grant.
- **Paid:** listed like public or private depending on a separate visibility flag, but entering the chat stream requires an active subscription, checked the same way described in §2.5.

### 2.4 Creating and structuring things

- **Categories and subcategories:** admin-only, managed from Settings. A category can be reparented, renamed, reordered, or hidden. A cycle guard blocks a category from becoming its own ancestor, the same rule the original tree design used for rooms, applied here to categories instead.
- **Rooms:** by default, any authenticated member can create a room and becomes its owner, choosing its type (public, private, secret, paid) and which category it files under. This default is itself a Settings toggle: an admin can restrict room creation to moderators and admins only, for a platform that wants tighter control over how many rooms exist.
- A room's category can be changed later by its owner or an admin; this is a metadata move, not a membership change, so nobody's access to the room is affected by which category it's filed under.

### 2.5 Sending a message, in a room or a DM

Sending a message, whether into a room or into a 1:1 conversation, follows one path, not two separate ones: a fresh ban check on the sender, content validation (non-empty, length-capped), the moderation rule set run against the content, and on success a synchronous write followed by a broadcast to everyone currently viewing that room or conversation. A blocked message is rejected with the sender shown the reason; a flagged message is stored but marked for review and, unlike the prior build, **every block or flag writes a moderation log entry as part of the same operation, not as a separate step that can be skipped.** That requirement exists because the earlier build had exactly this gap: a log table that nothing wrote to.

A 1:1 conversation is identified by the ordered pair of its two participants, so the same two users always land in the same conversation regardless of who started it, and a user can't open a conversation with themselves.

### 2.6 Paying to join a paid room

Joining a paid room is: confirm the room is actually paid and priced, confirm the user doesn't already hold an active subscription to it, confirm sufficient wallet balance (if not, route to the wallet top-up screen with the shortfall shown), debit the wallet, and grant a time-boxed subscription, all inside one transaction so a wallet debit can never happen without the subscription being granted, or vice versa. Concurrent spends against the same wallet are serialized (a user double-clicking "subscribe," or subscribing to two rooms in quick succession, can't overdraw the wallet by racing two debits against the same balance check).

### 2.7 Funding the wallet

Two provider paths at launch, both built against the same provider interface described in §4.3 so a third slots in later without touching this flow:

- **Paystack (card):** a pending wallet transaction is recorded, keyed by a provider reference, before the user is sent to Paystack's hosted checkout. The webhook or return-URL callback that later confirms it is matched against that same reference, so a callback that arrives twice, arrives out of order, or reports a mismatched amount can't double-credit the wallet or credit the wrong amount.
- **M-Pesa (Daraja STK push):** same pending-then-confirm shape. A scheduled job expires any top-up still pending several minutes after it was initiated, so a failed or abandoned STK prompt doesn't leave a wallet transaction stuck in limbo forever.

The platform has one configured base currency, set in Settings. Room prices and wallet balances are all in that currency. Because Daraja only moves Kenyan shillings, if the platform's base currency isn't KES, the M-Pesa top-up option is unavailable and Settings should say so plainly rather than let an admin enable a provider that can't work.

### 2.8 The admin settings page

One surface, admin-only, three areas:

- **Users:** search and list users, view and change platform role, ban or unban with a reason recorded, and view a user's wallet and transaction history for support purposes (read-only from Settings; wallet balances aren't editable here except through the same manual-credit path described below).
- **Payments:** which providers (Paystack, Daraja, and later Stripe) are enabled, their credentials (write-only in the UI; once saved, a secret is never redisplayed, only replaced), the platform base currency, and a manual wallet-credit tool for support cases, which requires a note explaining the reason and is itself logged.
- **Structure:** create, rename, reparent, reorder, or hide categories and subcategories; create, archive, or reassign the category of any room; toggle whether room creation is open to all members or restricted to moderators and admins; manage the active moderation rule set (word filters, link filters, patterns).

---

## 3. Data Model

No multi-tenancy, so no `tenant_id` on anything and no Row Level Security layer; every access check here happens in the application. All primary keys are UUIDs.

**`users`** — username, email, phone, password hash, avatar URL, name fields, platform role (`member` | `moderator` | `admin`), SSO provider and UID if that path is kept, ban flag and reason, last-seen timestamp (written on connect, not left as a defined-but-unused column). Unique on username, email, phone, and `(sso_provider, sso_uid)`.

**`categories`** — name, slug (unique), description, `parent_id` (self-referential, nullable, with a changeset guard against a category parenting itself or creating a cycle further up the tree), position (for manual ordering among siblings), hidden flag. This is the tree; rooms don't self-reference.

**`rooms`** — name, slug (unique), description, type (`public` | `private` | `secret` | `paid`), optional password hash for private rooms, `is_paid`, price, max members, archive flag. Belongs to a `category` (required; a top-level category is a valid parent) and an `owner` (a user).

**`room_members`** — join of `rooms` and `users`, role `member` | `moderator` | `owner`, `joined_at`, optional `expires_at` for time-boxed grants. Unique on `(room_id, user_id)`.

**`messages`** (partitioned by insertion time, same as the prior build; this pattern held up and there's no reason to un-adopt it) — content, content type, room, sender, soft-delete flag, moderation flag.

**`conversations`** — exactly two participants stored as an ordered pair so a given pair of users always resolves to one row; self-conversation rejected; unique on the pair.

**`direct_messages`** — same shape as `messages` plus a per-message read flag, keyed to a conversation and a sender.

**`moderation_rules`** — name, type (`word_filter` | `link_filter` | `pattern`; `rate_limit` isn't included this time since the prior build shipped it as a schema entry with no working implementation behind it, and shipping a config option that does nothing is worse than not offering it), a type-specific config, active flag.

**`moderation_logs`** — target type, target ID, action, reason, originating rule (nullable, since an admin can also log a manual action), actor, timestamp. Every block or flag from §2.5 writes here in the same operation as the block or flag itself.

**`wallets`** — one per user, non-negative balance.

**`wallet_transactions`** — type (`credit` | `debit`), amount, resulting balance, provider (`mpesa` | `paystack` | `stripe` | `internal`, the last for admin manual credits), status (`pending` | `completed` | `failed` | `reversed`), and a provider reference, unique when present, which is the idempotency key described in §2.7.

**`room_subscriptions`** — user, room, the wallet transaction that paid for it, `started_at`, `expires_at`, status (`active` | `expired` | `cancelled`). An expiry job flips status on a schedule as bookkeeping; the actual access check always compares `expires_at` to the current time directly, so a stale `active` row past its expiry is never trusted.

**`payment_provider_configs`** — provider (`paystack` | `mpesa` | `stripe`), enabled flag, credential fields (encrypted at rest, write-only through Settings). One row per provider; a disabled row's credentials, if present from a prior configuration, are simply not used.

---

## 4. Technical Design

### 4.1 Stack

Carried forward from the prior build because it was already validated against this exact problem shape, not chosen fresh: Elixir on the BEAM/OTP, Phoenix with LiveView, PostgreSQL via Ecto (with native table partitioning on `messages`), Oban for scheduled and background work (expiry jobs, moderation cache refresh) persisted in Postgres rather than a separate broker, `req` as the sole HTTP client, `bcrypt_elixir` for passwords, and Tailwind with daisyUI for the frontend.

### 4.2 Architecture

Single Elixir release, single node, synchronous message handling: validate, moderate, persist, broadcast, all as one function call in the process that received the send, not a batched or staged pipeline. The prior build tried a distributed, Horde-plus-Broadway version of this system, found it was solving for multi-node operation it never actually used, and removed it in favor of exactly this shape. Nothing about dropping multi-tenancy changes that reasoning either way, since clustering and tenancy are orthogonal concerns; this spec keeps the single-node shape because it was already the right call, not because multi-tenancy going away makes it more or less right.

The moderation rule set lives in an ETS table owned by one supervised process for the life of the application, refreshed on a schedule by Oban rather than rebuilt from scratch by the refresh job itself, so the table's owner is stable and the refresh is just a data update.

### 4.3 The payment provider interface

One behaviour, three responsibilities each provider implements: initiate a top-up (given a user and an amount, return whatever the provider needs to redirect or prompt the user, plus a pending wallet transaction), confirm a top-up (given a provider callback payload, verify it against the pending transaction it claims to complete and credit the wallet exactly once), and identify itself (a provider key used on `wallet_transactions.provider` and in Settings). Paystack and Daraja implement this now. Adding Stripe later is writing a third implementation of the same three responsibilities; nothing in the wallet, subscription, or room-access code needs to change, and nothing about Settings needs to change beyond adding Stripe to the list of providers an admin can enable.

### 4.4 Endpoints

**Browser / LiveView**, session-authenticated except where noted: authentication routes (login, register, magic link, OAuth callback, SSO exchange if kept); room browsing and room chat; direct-message inbox and thread; wallet balance and top-up; the admin settings surface (blocked outright, not just hidden, from any non-admin session).

**JSON API:** a health check; the SSO token exchange, if kept, verified the same way as before, a signed token checked against a rotation-aware list of accepted secrets rather than one static value, so a secret can be rotated without a coordinated cutover.

**Webhooks**, unauthenticated by session, verified instead by provider-specific means: Paystack's signature header, and Daraja's callback carrying a shared secret that the route rejects outright if it doesn't match, fail-closed. Both are the direct, validated fix for the exact failure mode ("webhook has no auth") the prior build's own security review caught.

### 4.5 What dropping RLS costs, and what's done about it

Removing multi-tenancy removes the tenant boundary RLS existed to enforce, so this version has no database-level backstop the way the prior one did; every access decision (can this user see this room, can this user reach Settings, can this user spend this wallet) lives entirely in application code. That's a smaller attack surface than a multi-tenant system's (there's no "other tenant's data" to leak into), but it does mean a single missed authorization check in the application layer isn't caught by anything underneath it.

Two things carry over from the prior build specifically to keep that single layer honest, both already named above and worth restating together here because they're the actual mitigation for having only one layer: every sensitive check (ban status, room membership, wallet ownership) is re-verified fresh against the database at the point of action rather than trusted from whatever was loaded at login or mount, and the admin-only surfaces (Settings, cross-room moderation) are checked by platform role at the point of entry, not inferred from what a LiveView happens to render.
