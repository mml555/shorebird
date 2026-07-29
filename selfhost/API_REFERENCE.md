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
`/patches/events`.

**Errors.** Non-2xx responses are `{"code": "...", "message": "...", "details"?: …}`.
Common statuses: `400` bad request, `401` missing/invalid auth, `403` cross-tenant
/ insufficient role, `404` not found, `409` state-machine violation (e.g. finalize
before verified, promote a non-ready patch).

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
| GET | `/organizations` | — | `{"organizations":[{"organization":{"id","name","org_type"},"role"}]}` |
| GET | `/users/me` | — | `PrivateUser` `{id,email,jwt_issuer,…}` (404 → treated as null by CLI) |

### Apps

| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/apps` | `{"organization_id":1,"display_name":"My App"}` | `{"id":"<uuid>","display_name":"My App"}` |
| GET | `/apps` | — | `{"apps":[{"app_id","display_name","latest_release_version","latest_patch_number","platforms":[…]}]}` |

### Releases

| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/apps/{appId}/releases` | `{"version":"1.0.0+1","flutter_revision":"…","flutter_version"?,"display_name"?,"notes"?}` | `{"release":{"id","version","flutter_revision","status","notes",…}}` |
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
| POST | `/apps/{appId}/patches/promote` | `{"patch_id":1,"channel_id":1}` | 204 · **409** if the patch isn't `ready` |
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
| GET | `/apps/{appId}/metrics` | `{"patches":[{"patch_number","downloads","installs","install_failures","update_failures","unique_clients"}]}` |

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
  "patch_number": 0 }
```
Response:
```json
{ "patch_available": true,
  "patch": { "number": 1, "download_url": "…/download/<token>?exp=&sig=",
             "hash": "<sha256>", "hash_signature": "<base64>|null" },
  "rolled_back_patch_numbers": [] }
```
A patch is offered only if its artifact is verified, the patch is `ready` (not
invalidated), an **active** channel-patch makes this `client_id` eligible under
the current rollout, and its number exceeds the client's. A rolled-back patch's
number appears in `rolled_back_patch_numbers` (installed devices revert).

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
