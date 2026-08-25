# API reference

Every HTTP endpoint the server exposes. Grouped by consumer: the **CLI wire
contract** (what `shorebird` calls), the **device** endpoints (what the on-device
updater calls), **admin & team** management, **analytics**, **auth/OAuth**, and
**operational** endpoints.

Base path for the versioned API is `/api/v1`. All requests and responses are JSON
(`snake_case`) unless noted (artifact upload is `multipart/form-data`; downloads
are raw bytes).

## Conventions

**Auth.** Most endpoints require a bearer token:
```
Authorization: Bearer <token>
```
where `<token>` is either an **API key** (`sb_api_…`, bootstrap or per-user) or a
**session JWT** from `shorebird login`. Public endpoints (no auth): `/healthz`,
`/readyz`, `/console`, `/admin/ui`, `/download/*` (signed), `/login`, `/token`,
`/oauth/callback`, `/api/logout`, `/.well-known/jwks.json`, `/patches/check`,
`/patches/assets`, `/crashes`, `/patches/events`, `/metrics`, `GET /`, and
`/diagnostics/speedtest`.

> `/diagnostics/speedtest`, `/metrics` and `GET /` added to this list 2026-08-13.
> The speedtest is unauthenticated on **both** verbs — `GET` streams up to
> 16,000,000 zero bytes (`?size=` clamped) and any other verb drains and discards
> an upload, returning `204`. It is separately rate-limited (`speed:<ip>`, 6/min)
> precisely because it is public and moves 16 MB a call. Omitting a public
> bandwidth endpoint from the public list is the kind of gap an operator writing
> firewall or WAF rules from this document would inherit.

**Errors.** Non-2xx JSON responses are `{"code": "...", "message": "..."}` — exactly
two keys. Common statuses: `400` bad request, `403` **all auth failures**, `404` not
found, `409` state-machine violation (e.g. finalize before verified, promote a
non-ready patch).

> Corrected 2026-08-13. This block listed `401` for "missing/invalid auth" and an
> optional `details` key; the API emits neither. A missing bearer and an invalid
> credential both return **`403 {"code":"forbidden"}`** — the single
> `HttpStatus.unauthorized` in the server is the HTML login form re-render, not a
> JSON API response — and `_err` builds a two-key body with no `details`. A client
> written from the old text would branch on a 401 that never arrives and treat a
> genuine auth failure as an authorization bug.

**Auth context.** An API key resolves to a user; the bootstrap key maps to user 1
(owner of the default org). App-scoped requests require the user to own the app's
org or be a collaborator (else `403`).

---

## CLI wire contract (`/api/v1`)

These are exactly what the pinned Shorebird CLI calls for `init` / `release` /
`patch`.

### Organizations & user

| Method | Path | Body | Response |
|---|---|---|---|
| GET | `/organizations` | — | `{"organizations":[{"organization":{"id","name","organization_type"},"role"}]}` (corrected 2026-08-13 — this row said `org_type`; the server emits `organization_type`, `api.dart:1069`) |
| GET | `/users/me` | — | `PrivateUser` `{id,email,jwt_issuer,…}` (404 → treated as null by CLI) |
| POST | `/users` | `{"display_name"?}` | `PrivateUser` — **added 2026-08-13, was undocumented** in a table introduced as "every HTTP endpoint the server exposes". Authenticated; the CLI calls it to create/rename the account behind a session JWT. It upserts on the **authenticated caller's email**, never on anything in the body |

### Apps

| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/apps` | `{"organization_id":1,"display_name":"My App"}` | `{"id":"<uuid>","display_name":"My App"}` |
| GET | `/apps` | — | `{"apps":[{"app_id","display_name","latest_release_version","latest_patch_number","platforms":[…]}]}` |

### Releases

| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/apps/{appId}/releases` | `{"version":"1.0.0+1","flutter_revision":"…","flutter_version"?,"display_name"?,"notes"?}` | `{"release":{"id","app_id","version","flutter_revision","flutter_version","display_name","platform_statuses","created_at","updated_at","notes","metadata"}}` — corrected 2026-08-13: this row said `"status"`, and `_releaseJson` (`api.dart:2834-2849`) emits **no `status` key at all**. Per-platform state is `platform_statuses`, which the pinned CLI casts **unguarded** (`shorebird_code_push_protocol/.../release.dart`), so omitting it is a client crash, not a missing field. (`status` *is* a valid request field on `PATCH` below — different row) |
| GET | `/apps/{appId}/releases` | — | `{"releases":[Release]}` |
| PATCH | `/apps/{appId}/releases/{releaseId}` | `{"status"?:"active","platform"?:"android","metadata"?,"notes"?}` | 204 · **409** if set `active` before all artifacts verified (fail-closed finalize) |

### Release artifacts

| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/apps/{appId}/releases/{releaseId}/artifacts` | multipart: `arch,platform,hash,filename,size,can_sideload?,podfile_lock_hash?` | `{…,"url":"…/api/v1/uploads/<token>","upload_method":"multipart"}` |
| GET | `/apps/{appId}/releases/{releaseId}/artifacts?arch=&platform=` | — | `{"artifacts":[{arch,platform,hash,size,url,…}]}` |

Register returns an upload `url` + `upload_method`. The bytes are then uploaded
(see **Uploads**). The server verifies `sha256(bytes) == hash` and `size`; a
mismatch fails the artifact (`400` on upload) and the release cannot finalize.

### Patches

| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/apps/{appId}/patches` | `{"release_id":1,"metadata":{},"notes"?}` | `{"id","number","notes"}` |
| POST | `/apps/{appId}/patches/{patchId}/artifacts` | multipart: `arch,platform,hash,size,hash_signature?,podfile_lock_hash?` | `{…,"url","upload_method"}` |
| POST | `/apps/{appId}/patches/promote` | `{"patch_id":1,"channel_id":1,"rollout"?:0-100}` | 204 · **400** if `rollout` is outside 0-100 · **409** if the patch isn't `ready` |

> `rollout` (optional, default `100`) added to this row 2026-08-13 — it was undocumented, and it is the only non-admin way to promote straight into a partial rollout (`_promotePatch`). PARITY.md §6 already counts it as part of the built rollout surface.
| PATCH | `/apps/{appId}/patches/{patchId}` | `{"notes"?}` | `{"id","number","notes"}` |

### Release & patch notes

Freeform operator notes (max 4096 chars) on a release or a patch — "why did this
ship". `shorebird releases info` and `shorebird patches info` already print the
field, and the console's patch cards show and edit it.

Write semantics are shared by both endpoints, and match the `notes` contract the
CLI's own `UpdateReleaseRequest` documents:

| `notes` value | Effect |
|---|---|
| absent, or `null` | left unchanged — the CLI sends `notes: null` on every mid-release status update, so this must not clear |
| `""` | cleared (reads back as `null`) |
| non-empty string | stored |
| over 4096 chars | `400`, nothing written |

`PATCH /apps/{appId}/patches/{patchId}` has no upstream counterpart: upstream's
`Patch` DTO carries `notes` but exposes no way to set it.

### Patch payload: `channel` vs `deployments`

`GET /apps/{appId}/releases/{releaseId}/patches` returns both:

- **`channel`** — the single track the CLI displays (`patches list` prints it,
  `patches info` shows it as `Track:`). It is the newest deployment that is
  still `active` and not rolled back, or `null` once every promotion has been
  withdrawn or reverted.
- **`deployments`** — the full per-channel picture (`channel`, `status`,
  `rollout`, `rolled_back`), newest first. Authoritative; a patch can be live on
  several tracks at once, which `channel` cannot express.

Each entry in `artifacts` carries `id`, `patch_id`, `arch`, `platform`, `hash`,
`size`, and `created_at`. All seven are required by the CLI's
`PatchArtifact.fromJson`, which casts `created_at` unguarded — omitting it makes
every patch with artifacts unparseable.

### Build provenance (`metadata`)

The CLI attaches a `metadata` object to every release status update
(`UpdateReleaseMetadata`) and to patch creation (`CreatePatchMetadata`) —
Shorebird and Flutter versions, OS and Xcode versions, which flags were used,
and `BuildTraceSummary` timings. It is stored per release and per patch, and
returned on `GET /apps/{appId}/releases` and
`GET /apps/{appId}/releases/{releaseId}/patches` as a `metadata` object (null if
never sent). The console shows it under **Build provenance** on release rows and
patch cards.

- The pinned CLI ignores the extra response key — its DTOs parse field by field.
- **Recorded even when the request fails.** Unlike `notes`, metadata is written
  before the release status gate, so provenance survives a `409` from activating
  before all artifacts verified — the case where knowing what built the release
  matters most.
- **Never fatal.** The shape is upstream's to change, so a `metadata` that isn't
  a JSON object is ignored rather than rejected, and a blob over 64 KiB is
  dropped with a warning. A release is never failed over its diagnostics.

Two related upstream requests need CLI-side changes before they're fully
covered, because the fields aren't in the blob yet: recording the git commit a
release was built from (#3443) and the `--dart-define` values set at release
time so a patch can warn when they changed (#3700). This is the storage and
display half.

**Partly overtaken on the fork side, and worth knowing before anyone implements
#3700 here.** A Route B release already records its effective define set — but in
the SHIPPED SUPPLEMENT (`route_b.json`'s `buildConfig`), not in this blob, so the
server still cannot answer "what defines built this release" and the statement
above remains true of the API. What exists CLI-side:

* `effectiveDefines` — the user's `--dart-define` and `--dart-define-from-file`
  values, canonicalized. **This is what compatibility is decided on**, and a patch
  is refused before compiling when it disagrees.
* `injectedDefines` — the six Flutter injects into every build
  (`FLUTTER_VERSION` and siblings). **Deliberately outside the fingerprint** and
  used only to compile a patch's replacement in the same `-D` environment. See
  `PARITY.md` §4 `G4.1c`.

So #3700's "warn when they changed" is already a *refusal* on this fork, and
anyone adding the server-side field should mirror that split rather than
flattening both maps into one — they answer different questions. The same gap
`R8` recorded for the engine/cell field applies: the authoritative record lives
in the on-device artifact rather than on the server.

A patch's `hash` is the **inflated-output** hash (the reconstructed `libapp.so`),
while the uploaded bytes are a binary diff — so the server verifies only the
patch's `size`; the device verifies the hash after inflating.

### Channels

| Method | Path | Body | Response |
|---|---|---|---|
| GET | `/apps/{appId}/channels` | — | `[{"id","app_id","name"}]` (bare array) |
| POST | `/apps/{appId}/channels` | `{"channel":"stable"}` | `{"id","app_id","name"}` |

### Metrics (per-patch, event-derived)

| Method | Path | Response |
|---|---|---|
| GET | `/apps/{appId}/metrics` | `{"patches":[{"patch_number","downloads","installs","install_failures","update_failures","unique_clients"}]}` — plus **top-level** `total_events`, `unique_clients` and an `events_by_type` map, which the handler spreads alongside `patches` (`return _json({...app, 'patches': patches})`). Noted 2026-08-13; `unique_clients` appears at both levels with different meanings — per-app at the top, per-patch inside. |

### Crashes (read, with symbolication)

`GET /api/v1/apps/{appId}/crashes`
Optional: `release_version`, `patch_number`, `limit` (default 100),
`symbolicate=true`.

Returns `{ "crashes": [ { id, client_id, release_version, patch_number, platform,
arch, kind, message, stack, ts, received_at } ] }`.

With `symbolicate=true`, each entry gains **`stack_symbolicated`** — the trace
resolved against the debug symbols retained for that patch (`arch: symbols`,
uploaded when the patch was built with `--split-debug-info`). `null` is a normal
outcome: a crash on an unpatched release has no retained symbols, and symbols may
be uploaded after a crash arrives. The raw `stack` is always present alongside.

Notable choices:

- **Opt-in**, because resolving costs a fetch, unzip and DWARF parse per distinct
  patch in the page. Off by default the response is unchanged for existing callers.
- **Read-time, never ingest-time.** Ingest must stay unfailable, and symbols
  routinely arrive *after* a crash, so resolving at ingest would permanently miss.
- **Pure Dart** (`package:native_stack_traces`, the same one `flutter symbolize`
  uses), which reads both the ELF form (Android) and the Mach-O form (Apple). One
  implementation covers every platform with no native toolchain in the image —
  `llvm-symbolizer` and `atos` would only matter for native C/Objective-C frames,
  which a Dart crash handler does not produce.

### Uploads

| Method | Path | Body | Notes |
|---|---|---|---|
| POST | `/uploads/{token}` | multipart, file field `file` | multipart upload (default) |
| PUT | `/uploads/{token}` | chunk bytes + `Content-Range` | GCS-style resumable (`308` + `Range` while incomplete, `2xx` on completion). Enable with `UPLOAD_METHOD=resumable`. |

### Diagnostics (CLI `doctor`)

| Method | Path | Response |
|---|---|---|
| GET | `/diagnostics/gcp_upload` | `{"upload_url": "…/diagnostics/speedtest"}` |
| GET | `/diagnostics/gcp_download` | `{"download_url": "…/diagnostics/speedtest?size=…"}` |

---

## Device endpoints (on-device updater)

The updater reads `base_url` from the bundled `shorebird.yaml` and calls these —
**no auth** (the app id + signed download URLs are the trust boundary).

### Patch check

`POST /api/v1/patches/check`
```json
{ "app_id":"<uuid>", "release_version":"1.0.0+1", "platform":"android",
  "arch":"aarch64", "channel":"stable", "client_id":"<uuid>",
  "current_patch_number": 1,
  "supported_patch_kinds": ["code","assets"] }
```

> `current_patch_number` is what the pinned updater actually sends, and it is
> **omitted entirely on a fresh install** rather than sent as `0` (corrected
> 2026-08-13 — this block documented only `patch_number: 0`). `patch_number` is
> the LEGACY spelling and is still accepted: the server reads
> `current_patch_number ?? patch_number ?? 0`. Documenting only the legacy name
> left `API_REFERENCE.md` and `UPDATER_CONTRACT.md` §2 describing two different
> request shapes for the same endpoint.

Response:
```json
{ "patch_available": true,
  "patch": { "number": 1, "download_url": "…/download/<token>?exp=&sig=",
             "hash": "<sha256>", "hash_signature": "<base64>|null",
             "kind": "code" },
  "rolled_back_patch_numbers": [] }
```
A patch is offered only if its artifact is verified, the patch is `ready` (not
invalidated), an **active** channel-patch makes this `client_id` eligible under
the current rollout, and its number exceeds the client's. A rolled-back patch's
number appears in `rolled_back_patch_numbers` (installed devices revert).

**`kind`** (always present) is `code` for the usual patch, or `assets` for a
patch whose payload is assets and nothing else — the shape that lets the
engine's asset overlay ship where code cannot, because there is nothing to link
or interpret.

**`supported_patch_kinds`** (optional, defaults to code-only) is a *capability
gate, not a hint*. An assets-only patch is offered **only** to a client that
lists `assets`. A stock updater handed one would try to inflate an asset archive
as a binary diff against the release snapshot, fail, and tombstone the patch as
permanently bad for that release — so silence must mean "code only". A
wrong-typed value is read as no support, failing closed like every other field
on this endpoint.

Where a patch carries both a code artifact and an asset bundle, `kind` is
`code`: the bundle rides alongside and is fetched separately via
`/patches/assets`.

### Events

`POST /api/v1/patches/events`
```json
{ "event": { "app_id":"…","client_id":"…","type":"__patch_install__",
  "patch_number":1,"platform":"android","arch":"aarch64",
  "release_version":"1.0.0+1","timestamp":1785000000,"message":null } }
```
Returns `204`. Idempotent (deduped by `client_id|app_id|release_version|
patch_number|type|timestamp`). Known types: `__patch_download__`,
`__patch_install__`, plus `__patch_install_failure__` / `__patch_update_failure__`.

**Updated 2026-08-20/23 — a fifth type and a seventh dedupe field.**

* `__patch_boot_lifecycle__` — NON-TERMINAL boot-lifecycle telemetry. Carries five
  optional fields the server columnises: `outcome` (`ambiguous_boot_retry` |
  `recovered_after_ambiguity` | `retired_after_ambiguity`),
  `ambiguous_attempt_count`, `boot_failure_threshold`, `boot_started_at`,
  `updater_revision`. All are absent from every other type, and a deployment that
  never receives one is unaffected.
* **The dedupe key appends `outcome` when it is present**, making it seven fields for
  lifecycle events and leaving all four older types byte-identical. Required for
  correctness, not tidiness: a retry and the recovery from that same launch can land
  in the same timestamp-second, and the six-field key discarded the recovery as a
  duplicate.
* These rows feed `Repository.bootLifecycleMetrics()`, which has **no HTTP endpoint
  today** — it is queried directly. Eligibility is keyed to `updater_revision`
  (`NULL` is ineligible), and the behaviour is frozen while data is collected:
  `selfhost/MEASUREMENT_MODE.md`.

### Patch asset bundle

`POST /api/v1/patches/assets`
```json
{ "app_id":"<uuid>", "release_version":"1.0.0+1", "platform":"android",
  "patch_number": 1 }
```
Response:
```json
{ "assets_available": true,
  "assets": { "url": "…/download/<token>?exp=&sig=", "hash": "<sha256>",
              "size": 114524 } }
```
Serves the `flutter_assets` overlay attached to a patch, so a patch can change
assets and not only Dart code. The bundle is an ordinary patch artifact tagged
`arch: assets` (see [`PLATFORM_MATRIX.md`](PLATFORM_MATRIX.md)); no schema or
protocol change was needed because `arch` is free-form end to end.

The **native updater never sees this** — it downloads exactly one artifact and
applies it as a binary diff. App-side Dart fetches the bundle instead
([`code_push_runtime`](../packages/code_push_runtime)), which is what keeps the
feature off the engine-build critical path and therefore working on iOS.

Malformed or unknown input answers `{"assets_available": false, "assets": null}`
rather than erroring: this is polled on launch by app code, and a hard failure
would be a needless crash path for a purely additive feature. A **rolled-back**
patch stops serving its assets, or an app that had reverted would keep using the
newer bundle against older code.

### Crash reports

`POST /api/v1/crashes`
```json
{ "app_id":"<uuid>", "client_id":"<uuid>", "release_version":"1.0.0+1",
  "patch_number": 1, "platform":"android", "arch":"arm64",
  "kind":"StateError", "message":"Bad state: …",
  "stack":"*** *** ***\npid: …\n    #00 abs 0000… virt 0000…",
  "timestamp": 1785000000 }
```
Always answers `200 {"stored": <bool>}`. **It never fails**, and swallows
malformed input on purpose: the client is an app that just died, and making it
fight 4xx/5xx is a second failure on top of the first. A test named
`garbage never fails the reporter` guards this.

`arch` matters — it selects which retained symbol file the trace is resolved
against, and the wrong one resolves every frame to a wrong address. Read back via
`GET /api/v1/apps/{appId}/crashes` below.

### Download

`GET /download/{token}?exp=<unix>&sig=<hmac>` — streams the artifact bytes.
Honors HTTP `Range` (`206` + `Content-Range`). The `exp`/`sig` are validated
(short-lived HMAC); tampered or expired links are rejected. This is the URL the
`patch.download_url` points at.

---

## Admin & team (`/admin`)

Bearer required. Org mutations require an **owner/admin** role; app mutations
require app access. Also drives the console's Team UI.

### Users & API keys

| Method | Path | Auth | Response |
|---|---|---|---|
| POST | `/admin/users?email=&name=` | root-org owner/admin | `{"user_id","email","api_key"}` — creates/updates a user and issues an API key (shown once) |

This route returns the **existing** account on an email conflict, so it can
hand out a fresh key for an address that already exists. It is therefore
restricted to an owner/admin of the root organization — the identity the
bootstrap `API_KEY` maps to. Any other caller gets **403**; app-level admin on
some app is not enough. To add someone to *your* org instead, use an invitation.

### Organization members

| Method | Path | Auth | Response |
|---|---|---|---|
| GET | `/admin/orgs/{orgId}/members` | org member | `{"members":[{user_id,email,display_name,role}]}` |
| PATCH | `/admin/orgs/{orgId}/members/{userId}?role=` | org admin | `{org_id,user_id,role}` |
| DELETE | `/admin/orgs/{orgId}/members/{userId}` | org admin | `{"removed":true}` · **409** removing the last owner/admin |

### Invitations

| Method | Path | Auth | Response |
|---|---|---|---|
| POST | `/admin/orgs/{orgId}/invitations?email=&role=` | org admin | `{"token","email","role","accept_url"}` |
| GET | `/admin/orgs/{orgId}/invitations` | org admin | `{"invitations":[{token,email,role,created_at,expires_at}]}` (pending only) |
| DELETE | `/admin/orgs/{orgId}/invitations/{token}` | org admin | `{"revoked":true}` |
| POST | `/api/v1/invitations/{token}/accept` | the invited user (bearer) | `{"joined_org","role"}` — email must match the invite; not expired/accepted |

### Allowed email domains (org restriction)

| Method | Path | Auth | Response |
|---|---|---|---|
| GET | `/admin/orgs/{orgId}/domains` | org admin | `{"domains":["company.com"]}` — empty means unrestricted |
| PUT | `/admin/orgs/{orgId}/domains?domains=a.com,b.com` | org admin | `{org_id,domains}` · `?domains=` clears · **409** if it would exclude every owner/admin · **400** if nothing in the list parses as a domain |

Restricts an org to one or more email domains, so a personal account can't be
added to a company org or onto one of its apps. With a policy set, both
`POST /admin/orgs/{orgId}/invitations` and
`POST /admin/apps/{appId}/collaborators` reject an out-of-domain address with
`403`, naming the policy.

- **Unrestricted is the default**, so an existing deployment is unaffected.
- **Existing members are never evicted.** The policy governs who can be *added*
  from then on; it does not re-check people who are already in.
- **Matching is exact on the domain.** `company.com` does not admit
  `mail.company.com`, so the org can't be widened by a subdomain someone else
  controls. Input is normalized: case-insensitive, and a leading `@` or `*.` is
  accepted and stripped.

### App collaborators

| Method | Path | Auth | Response |
|---|---|---|---|
| GET | `/admin/apps/{appId}/collaborators` | app access | `{"collaborators":[{user_id,email,display_name,role}]}` |
| POST | `/admin/apps/{appId}/collaborators?email=&role=` | app access | `{app_id,user_id,role}` — the user must already exist · **403** if the owning org restricts email domains |
| DELETE | `/admin/apps/{appId}/collaborators/{userId}` | app access | `{"removed":true}` |

### Rollout & rollback

| Method | Path | Response |
|---|---|---|
| POST | `/admin/apps/{appId}/patches/{patchId}/rollout?channel=&percent=` | `{patch_id,rollout}` — set a partial rollout (0–100) |
| POST | `/admin/apps/{appId}/patches/{patchId}/withdraw?channel=&rollback=true\|false` | `{withdrawn:true,rolled_back}` — stop serving (`rollback=true` also reverts installed devices) |

**Roles:** `owner`, `admin`, `appManager`, `developer`, `viewer`.

---

## Analytics (`/api/v1/apps/{appId}/analytics/*`)

All GET, bearer + app access. Event-derived; work on both SQLite and Postgres.

| Path | Key query params | Shape |
|---|---|---|
| `/analytics/patch-adoption` | `release_version,granularity,start,end` | `GetPatchAdoptionResponse` (cumulative adoption per patch) |
| `/analytics/unique-users` | `window_days,granularity,group_by` | `GetUniqueUsersResponse` (current + previous window) |
| `/analytics/version-distribution` | `active_window_days` | `GetVersionDistributionResponse` |
| `/analytics/activity-heatmap` | `lookback_days` | 168-cell UTC weekday×hour grid |
| `/analytics/active-hours` | `lookback_days` | 24-hour UTC profile + recommended low-activity window |
| `/analytics/new-devices` | `window_days` | first-seen devices, current + previous |
| `/analytics/patch-installs` · `/analytics/patch-downloads` | `window_days,granularity,group_by,release_version,patch_number` | `GetPatchMetricResponse` |

`granularity` ∈ `hour|day|week`. Distinct-device counts are exact (not HLL), so
time-bucketed series need not sum to the window total.

---

## Auth / OAuth

| Method | Path | Purpose |
|---|---|---|
| GET | `/login?continue=<loopback>` | start `shorebird login`. Self-consent mode returns an API-key form; broker mode redirects to the external IdP. `continue` must be a loopback URL |
| POST | `/login` | self-consent credential check (form: `continue`, `api_key`); a valid key 302s to `continue` with an auth code, otherwise 401 |
| GET | `/oauth/callback` | IdP redirect target; exchanges the IdP code and issues our own auth code |
| POST | `/token` | exchange auth code / refresh token → `{access_token, refresh_token, …}` (RS256 JWT; codes + refresh tokens are single-use, persisted, rotated) |
| POST | `/api/logout` | bearer is the refresh token; revokes it |
| GET | `/.well-known/jwks.json` | public JWKS for verifying issued JWTs |

Register the IdP redirect URI as `<PUBLIC_BASE_URL>/oauth/callback`. See
`IDP_SETUP.md`.

---

## Operational

| Method | Path | Auth | Response |
|---|---|---|---|
| GET | `/healthz` | public | `ok` (liveness) |
| GET | `/readyz` | public | `{"db":true,"object_store":true}` (readiness — checks both backends) |
| GET | `/metrics` | public | Prometheus text exposition — request counts by method/status class, a request-duration histogram, in-flight gauge, and uptime. Low-cardinality (no path/app-id labels). Firewall it to your monitoring network if you don't want it internet-reachable. |
| GET | `/console` | public page | the web dashboard (connect with an API key) |
| GET | `/admin/ui` | public page | thin admin page |

Request/error logs are plain text by default, or one structured JSON object per
line (`level`, `msg`, `method`, `path`, `status`, `duration_ms`) when
`LOG_FORMAT=json` — see `.env.example`.

---

## Headers the CLI sends

Every CLI request also carries `x-version:<pkg>` and `x-cli-version:<pkg>`
alongside `Authorization`. The server does not gate on these; they're advisory.
