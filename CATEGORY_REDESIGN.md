# CATEGORY_REDESIGN.md — Hierarchical, Multi-Tenant Room Redesign

> **Status:** Planning complete, implementation pending approval.
> **Goal:** Enable nested organizational units (Subcounty → Ward → Group) and
> top-level functional departments (Education, Finance, Construction) under a
> county-level tenant, with PostgreSQL Row Level Security preventing cross-tenant
> data leakage.

---

## 1. Feasibility

The current schema is **flat** and **single-tenant**:

- `RoomCategory` (`lib/beam_chat/rooms/room_category.ex`) — only `name` + `slug`, no nesting.
- `Room` (`lib/beam_chat/rooms/room.ex`) — `belongs_to` exactly one `RoomCategory`; no parent/child.
- `Message` → `Room`; `RoomMember` → `Room`; `GroupSubscription` → `Room`.
- No `parent_id`, no tree, no `tenant`/`organization`/`county` container anywhere.

**Conclusion:** The Kiambu use case is **not possible today**. It must be built.

---

## 2. Confirmed Design Decisions

| # | Decision | Resolution |
|---|----------|------------|
| D1 | **Model shape** | **One recursive tree.** A single self-referencing structure holds both functional departments and the administrative hierarchy as separate branches. |
| D2 | **Leaf / node semantics** | **Each level is itself a chat Room.** Subcounty, Ward, and Group are all `Room` rows. The recursion lives on `Room` via `parent_id`. Functional departments (Education, Finance, Construction) are top-level rooms with `parent_id = NULL`. |
| D3 | **Tenancy** | **Multi-tenant from day one**, enforced with **PostgreSQL Row Level Security (RLS)**. |
| D4 | **User ↔ county relationship** | **A user may belong to multiple counties.** Use a `tenant_members` join table. `users` does NOT get a `tenant_id` column. |
| D5 | **Access / visibility** | **Role-based.** Tenant admins see the entire tree. Everyone else sees only rooms they are explicitly granted (via a `room_members` row on that specific room). A Nairobi planner granted "Mihango" ward sees only Mihango — not sibling wards. No automatic down-tree cascade. |

### Resulting mental model
```
Tenant: Kiambu County
├── Education            (Room, parent_id = NULL)
├── Finance              (Room, parent_id = NULL)
├── Construction         (Room, parent_id = NULL)
└── [Administrative branch]
    ├── Subcounty A      (Room)
    │   ├── Ward X       (Room)
    │   │   └── Group 1  (Room)   ← people chat here
    │   └── Ward Y       (Room)
    └── Subcounty B      (Room)
        └── Ward Z       (Room)
            └── Mihango  (Room)   ← Nairobi planner granted here only
```

---

## 3. Schema / Migration Changes

### 3.1 New table: `tenants`
- `id` (binary uuid PK)
- `name` (text, not null)
- `slug` (text, not null, unique)
- `metadata` (jsonb, default `{}`)
- `timestamps`

### 3.2 New join table: `tenant_members`
- `id` (binary uuid PK)
- `tenant_id` → `tenants` (on_delete: :delete_all, not null)
- `user_id` → `users` (on_delete: :delete_all, not null)
- `role` (check: `admin|member`, default `member`)
- unique `(tenant_id, user_id)`
- partial index on `(tenant_id) where role = 'admin'` (hot admin check)

### 3.3 Alter `rooms`
- Add `tenant_id` → `tenants` (NOT NULL, on_delete: :delete_all)
- Add `parent_id` → `rooms` (self reference, `on_delete: :nilify_all`, nullable)
- Add index `(tenant_id, parent_id)` for subtree queries
- Application-side cycle guard in changeset; optional `CHECK (id <> parent_id)` to block direct self-parent

### 3.4 Add `tenant_id` to (non-partitioned) tables
- `room_categories` (fk → tenants)
- `room_members` (fk → tenants) — keeps membership RLS simple
- `group_subscriptions` (fk → tenants)

### 3.5 `messages` (partitioned — no structural change)
- Leave partitioning intact. RLS filters messages via
  `EXISTS (SELECT 1 FROM rooms r WHERE r.id = messages.room_id AND r.tenant_id = current_setting('app.current_tenant_id')::uuid)`.
- Rationale: adding `tenant_id` to a partitioned table forces re-partitioning; the `EXISTS` policy avoids that.

### 3.6 RLS + session GUCs
- `ENABLE ROW LEVEL SECURITY` on: `rooms`, `room_members`, `room_categories`, `group_subscriptions`, `messages`.
- GUCs set per connection/transaction: `app.current_tenant_id`, `app.current_user_id`.
- **Policy (SELECT) pattern** for `rooms`:
  ```
  tenant_id = current_setting('app.current_tenant_id')::uuid
  AND (
    is_tenant_admin(current_user_id, tenant_id)
    OR EXISTS (
      SELECT 1 FROM room_members rm
      WHERE rm.room_id = rooms.id
        AND rm.user_id = current_setting('app.current_user_id')::uuid
        AND rm.tenant_id = rooms.tenant_id
    )
  )
  ```
- Mirror for `room_members`, `room_categories`, `group_subscriptions`; `messages` uses the `EXISTS(rooms…)` variant.
- `is_tenant_admin(uid, tid)` is a SQL function reading `tenant_members`.

---

## 4. Code Changes

### 4.1 Schemas (`lib/beam_chat/...`)
- **New** `BeamChat.Tenants.Tenant` — fields per 3.1.
- **New** `BeamChat.Tenants.TenantMember` — fields per 3.2.
- **Edit** `BeamChat.Rooms.Room`
  - `belongs_to :tenant, BeamChat.Tenants.Tenant, foreign_key: :tenant_id`
  - `belongs_to :parent, __MODULE__, foreign_key: :parent_id`
  - `has_many :children, __MODULE__, foreign_key: :parent_id`
  - `changeset` adds `:tenant_id`, `:parent_id`; validates `parent_id` not self (cycle guard); `foreign_key_constraint`s.
- **Edit** `BeamChat.Rooms.RoomCategory` — add `tenant_id` + `belongs_to :tenant`.
- **Edit** `BeamChat.Rooms.RoomMember` / `BeamChat.Payments.GroupSubscription` — add `tenant_id`.

### 4.2 Tenant context (`lib/beam_chat/tenants.ex`) — NEW
- `create_tenant/1`, `get_tenant_by_slug/1`
- `add_member/3` (tenant, user, role), `remove_member/2`
- `admin?/2` (tenant, user) — backs RLS + UI gating
- `list_tenants_for_user/1`

### 4.3 Repo tenant helper (`lib/beam_chat/repo.ex`)
- `with_tenant(tenant_id, user_id, fun)` — opens a transaction and
  `SET LOCAL app.current_tenant_id = $1; SET LOCAL app.current_user_id = $2;`
  before running `fun`. Pool-safe and sandbox-safe for tests.

### 4.4 Room recursion helpers (`lib/beam_chat/rooms.ex`)
- `list_child_rooms(room_or_id)` — direct children
- `room_ancestors(room_or_id)` — path to root (recursive CTE via `fragment`)
- `room_descendants(room_or_id)` — full subtree (recursive CTE)
- `room_path(room_or_id)` — breadcrumb list
- `move_room(room, new_parent_id)` — re-parent with cycle validation
- `create_room/1` — requires `tenant_id`; enforces cycle/self-parent rules

### 4.5 Access policy (`lib/beam_chat/rooms/access_policy.ex`)
- Replace flat logic with role-based visibility:
  - admin → full tree for the tenant
  - member → only rooms with an explicit `room_members` grant
- Used by LiveView to decide what to render.

### 4.6 LiveView UI (`lib/beam_chat_web/...`)
- **Tenant switcher** — pick active county (sets GUCs for the session/request).
- **Nested room-tree browser** — recursive render using streams; admins see full tree, members see granted-only.
- **Room creation form** — `tenant_id` + `parent_id` picker (only valid parents within same tenant).
- **Admin vs member views** — gated by `Tenants.admin?/2`.

---

## 5. Seed / Setup for Kiambu

`priv/repo/seeds.exs` (or a dedicated `mix run` task) builds:
1. Tenant **"Kiambu County"**.
2. Top-level rooms: **Education, Finance, Construction**.
3. Administrative branch: sample **Subcounty → Ward → Group** chain(s),
   e.g. Subcounty → Ward "Mihango" → Group, each a `Room` with correct
   `tenant_id` + `parent_id`.

---

## 6. Tests

- **RLS isolation** — user in county A cannot read county B rows even via raw SQL in tests.
- **Recursion** — ancestors/descendants/path correctness on a known tree.
- **Cycle prevention** — `move_room` rejects a parent that would create a loop; self-parent rejected by changeset.
- **Role visibility** — admin sees full tree; non-admin sees only explicitly granted rooms (Mihango-only case).

---

## 7. Build Todo Checklist

- [ ] **T1 — Migrations: tenants + tenant_members**
  - [ ] `tenants` table migration
  - [ ] `tenant_members` join migration (role check, unique, partial admin index)
- [ ] **T2 — Migrations: rooms recursion + tenant scoping**
  - [ ] alter `rooms` add `tenant_id`, `parent_id` (+ indexes, self-parent check)
  - [ ] alter `room_categories`, `room_members`, `group_subscriptions` add `tenant_id`
- [ ] **T3 — RLS**
  - [ ] enable RLS on all scoped tables
  - [ ] create `is_tenant_admin` SQL function
  - [ ] create SELECT policies using `app.current_tenant_id` / `app.current_user_id`
  - [ ] `messages` EXISTS-based policy
- [ ] **T4 — Schemas**
  - [ ] `Tenant`, `TenantMember` schemas
  - [ ] edit `Room` (tenant, parent, children, cycle guard in changeset)
  - [ ] edit `RoomCategory`, `RoomMember`, `GroupSubscription` for `tenant_id`
- [ ] **T5 — Repo `with_tenant/3` helper** (SET LOCAL GUCs in a transaction)
- [ ] **T6 — Tenants context** (create/lookup/add member/admin?/list for user)
- [ ] **T7 — Rooms recursion helpers** (children/ancestors/descendants/path/move/create)
- [ ] **T8 — Access policy** role-based visibility
- [ ] **T9 — LiveView UI** (tenant switcher, nested tree browser, create form, admin/member gating)
- [ ] **T10 — Kiambu seed/setup task**
- [ ] **T11 — Tests** (RLS isolation, recursion, cycle, role visibility)
- [ ] **T12 — `mix precommit`** clean (fix all warnings/lint), verify on `develop` branch per AGENTS.md

---

## 8. Open Considerations (flag if relevant)
- **`RoomCategory` fate:** With recursion on `Room`, the flat `RoomCategory` becomes an
  optional classification tag. Plan keeps it (now tenant-scoped) but it is no longer the
  hierarchy mechanism. Drop it later if unused.
- **Tree depth limit:** No hard limit planned; cycle guard only. Add a max-depth `CHECK`
  if business rules require it.
- **Membership cascade:** Deliberately **not** cascading parent→child access (D5). If a
  future need arises, grant inheritance can be added without schema change.
- **Branch hygiene:** All work on `develop`, Conventional Commits, `--no-ff` merges,
  `mix precommit` before completion (per AGENTS.md).

---

## 9. Security Addendum — RLS is bypassed by the superuser app role (MUST FIX)

**Finding:** `config/dev.exs` and `config/test.exs` connect as `username: "postgres"`,
which is a PostgreSQL **superuser**. Superusers bypass Row Level Security regardless of
`FORCE ROW LEVEL SECURITY`. Therefore, until the application connects as a
**non-superuser** role, none of the policies in T3 provide any isolation — they only
protect against accidental cross-tenant queries at the code layer.

**Fix (required for the "secure" guarantee):** create a dedicated app role without
superuser privileges and point the app at it:
```sql
-- run as the postgres superuser (e.g. via `mix run priv/repo/setup_app_role.exs`)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'beamchat_app') THEN
    CREATE ROLE beamchat_app LOGIN PASSWORD 'beamchat_app' NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
END$$;
GRANT CONNECT ON DATABASE beam_chat_dev TO beamchat_app;
GRANT USAGE ON SCHEMA public TO beamchat_app;
-- App owns the schema/objects so it can run migrations and DDL:
ALTER SCHEMA public OWNER TO beamchat_app;
```
Then set the repo `username`/`password` (via env, e.g. `BEAMCHAT_DB_USERNAME`) to
`beamchat_app` in `dev.exs`, `test.exs`, and `prod.exs`.

**Note:** `FORCE ROW LEVEL SECURITY` (added in T3) additionally forces RLS for the table
*owner*; together with a non-superuser role this gives full default-deny protection.
Without the role change, RLS is effectively documentation-only. This is tracked as **T3.5**.

**Tests (T11) caveat:** RLS isolation tests only pass meaningfully when run as a
non-superuser role. Run the T11 suite against the `beamchat_app` role.
