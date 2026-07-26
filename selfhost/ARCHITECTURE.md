# Architecture & internals

How `code_push_server` is built inside. For the wire API see `API_REFERENCE.md`;
for deployment see the package `README.md` / `INTEGRATION.md`.

## Components

```
bin/server.dart          entrypoint: load config → open Db + ArtifactStore →
                         run migrations → serve (shelf) → graceful shutdown
lib/src/
  config.dart            env → Config; backend selection; production validation
  db.dart                Db abstraction + SQLite and Postgres adapters
  repository.dart        all persistence (schema, CRUD, migrations) over Db
  artifact_store.dart    ArtifactStore + filesystem and S3/MinIO adapters
  domain.dart            lifecycle enums + transition guards (state machines)
  api.dart               shelf handler: routing, middleware, wire contract, admin
  oauth.dart             RS256 JWT mint/verify; IdP token decoding
  analytics.dart         event-derived analytics (backend-agnostic date SQL)
  rollout.dart           deterministic rollout bucketing (pure)
  signing.dart           HMAC signed-URL sign/validate (pure)
  content_range.dart     Content-Range / Range parsing (pure)
console/index.html       self-contained web dashboard (apps, analytics, team)
```

The server is **stateless**: all durable state lives in the database and the
artifact store. Nothing is kept in process memory that can't be rebuilt, so the
scale profile runs multiple replicas behind a load balancer.

## Two swappable backends

Both are chosen by `config.dart` from the environment (see `INTEGRATION.md`), and
everything above them is written once against an interface.

**Database — `Db`** (`db.dart`)
- `SqliteDb` (default): embedded `sqlite3` via FFI, one file under `DATA_DIR`.
  Incoming SQL is written in the Postgres flavor; a small translator rewrites the
  handful of differing constructs (`SERIAL`→`AUTOINCREMENT`, `TIMESTAMPTZ`→`TEXT`,
  `now()`→`strftime`, `@name`→positional `?` — skipping string literals) so
  `repository.dart` stays a single implementation.
- `PgDb` (scale): `package:postgres` connection pool. SQL passes through
  unchanged.
- Analytics date bucketing goes through three dialect methods on `Db`
  (`truncPeriod`, `extractDow`, `extractHour`) so the same analytics SQL runs on
  either backend.

**Artifact bytes — `ArtifactStore`** (`artifact_store.dart`)
- `FilesystemArtifactStore` (default): bytes on local disk under
  `DATA_DIR/artifacts/<storage_key>`; range reads via `RandomAccessFile`.
- `S3ArtifactStore` (scale): MinIO/S3 via `package:minio`.
- Both share the local-disk **resumable-upload staging** (`.partial` files
  committed on completion).

## Data model

Postgres/SQLite tables (created idempotently by migration 1, `repository.dart`):

| Table | Holds |
|---|---|
| `users`, `api_keys` | identities and their bearer keys |
| `organizations`, `org_members` | tenants and membership+role |
| `apps`, `app_collaborators` | apps (own an org) and per-app extra access |
| `releases`, `release_platform_status` | a version + its per-platform finalize state |
| `patches` | one logical patch per `(release, number)` |
| `channels`, `channel_patches` | deployment: which patch is active on a channel, its rollout %, rolled-back flag |
| `artifacts` | byte metadata for release/patch artifacts (`owner_kind`+`owner_id`), status, `storage_key`, hash/size/signature |
| `events` | append-only device events (dedupe key); source of all metrics/analytics |
| `settings` | server singletons (e.g. the persisted OAuth signing key) |
| `auth_codes`, `refresh_tokens` | single-use OAuth codes + rotating refresh tokens |
| `rate_limits` | shared fixed-window counters (scale) |
| `audit_log` | who did what (admin/mutations) |
| `schema_migrations` | applied migration versions |

Eligibility is always scoped by `app + release version + platform + arch +
channel + patch number` — never a global patch number.

## Lifecycle state machines (`domain.dart`)

Transitions are enforced in domain guards, not route handlers; illegal
transitions raise a `409`.

- **Artifact:** `pending → uploading → verified` (immutable after verified) with
  `→ failed` on a bad upload (retryable).
- **Release:** `draft → uploading → ready → archived`. `ready` requires every
  non-failed artifact `verified` — finalize is **fail-closed**.
- **Patch:** `draft → uploading → ready → invalidated`, plus `ready → uploading`
  (re-open for multi-arch registration). Promote requires `ready`.
- **ChannelPatch (deployment):** `active → withdrawn`. Promoting supersedes any
  other active patch on the channel in one transaction (exactly one active).

## Request lifecycle (`api.dart`)

A shelf `Pipeline` wraps the router:
1. **logging** — one line per request (`METHOD /path -> status`).
2. **rate limit** — fixed window (`memory`, or `postgres` shared across
   replicas), keyed by bearer for authenticated requests and by client IP
   (`X-Forwarded-For` behind a proxy) for unauthenticated device requests, so
   one device can't exhaust the fleet's window. Over-limit → `429`.
3. **auth** — resolves the bearer to a `userId` in `req.context`. Public routes
   (health, console, download, OAuth, device) bypass it. API key → its user (the
   bootstrap key → user 1); JWT → its `sub`/email.
4. **route** — manual segment matching → the wire contract, admin, analytics,
   OAuth, device, or operational handlers.

## Security model

- **Tenancy:** app-scoped requests call `_authorizeApp`, which allows access only
  if the user owns the app's org or is a collaborator — otherwise `403`. Org
  mutations require an owner/admin role.
- **Download URLs:** short-lived HMAC-signed (`?exp=&sig=`, `signing.dart`),
  validated before streaming — so artifact bytes aren't world-readable by key.
- **JWT:** RS256, signed with a key **persisted in `settings`** (survives
  restarts and is shared across replicas); public JWKS at
  `/.well-known/jwks.json`. Issuer must match `SHOREBIRD_JWT_ISSUER`.
- **Upload cap:** artifact uploads are capped at `MAX_UPLOAD_BYTES` (512 MiB
  default), enforced mid-stream so a dishonestly-sized body can't exhaust
  memory; over-limit → `413`. Idle connections close after 60s.
- **Production guard:** with `PRODUCTION=true`, `config.validate()` refuses to
  boot on any dev-default secret or non-HTTPS `PUBLIC_BASE_URL`.
- **Last-owner guard:** an org can't have its last owner/admin removed.

## Rollout bucketing (`rollout.dart`)

Deterministic and stable per device:
```
hash(app_id : channel : patch_id : client_id) % 10000  <  rollout_percent * 100
```
so a given `client_id` is consistently in-or-out as the percentage grows. A
missing/malformed `client_id` is only eligible for 100% rollouts (fail-closed on
ambiguous identity).

## Hashing semantics

- **Release artifact:** `hash = sha256(uploaded bytes)` → the server verifies
  bytes directly on upload.
- **Patch artifact:** `hash = sha256(inflated output)` while the uploaded bytes
  are a binary diff → the server can only verify `size`; the **device** verifies
  the hash after inflating the diff against the base it already has. (Signing,
  when enabled, is a pass-through of `hash_signature`, verified on-device.)

## Migrations

`repository.dart` runs ordered, transactional migrations recorded in
`schema_migrations`. Migration 1 is the idempotent baseline (safe against an
existing database); later migrations run once each. Add a new `(version, [sql…])`
entry to evolve the schema; it applies on next boot on both backends.

## Testing

`test/` (run `dart test` from the package):
- Pure units: `rollout`, `signing`, `content_range`, `oauth`, `domain`, `idp`,
  `config` (production guard).
- Backend integration on real SQLite: `db_test` (CRUD + rollback + idempotent
  events + persistence), `analytics_test` (every analytics endpoint + weekly
  bucketing).
- `tool/smoke_test.sh` drives the full wire contract with curl (works against any
  running server, HTTP or TLS via `CURL_OPTS=-k`).
