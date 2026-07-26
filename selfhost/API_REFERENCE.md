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
| POST | `/apps/{appId}/releases` | `{"version":"1.0.0+1","flutter_revision":"…","flutter_version"?,"display_name"?}` | `{"release":{"id","version","flutter_revision","status",…}}` |
| GET | `/apps/{appId}/releases` | — | `{"releases":[Release]}` |
| PATCH | `/apps/{appId}/releases/{releaseId}` | `{"status"?:"active","platform"?:"android","metadata"?}` | 204 · **409** if set `active` before all artifacts verified (fail-closed finalize) |

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
| POST | `/apps/{appId}/patches` | `{"release_id":1,"metadata":{}}` | `{"id","number"}` |
| POST | `/apps/{appId}/patches/{patchId}/artifacts` | multipart: `arch,platform,hash,size,hash_signature?,podfile_lock_hash?` | `{…,"url","upload_method"}` |
| POST | `/apps/{appId}/patches/promote` | `{"patch_id":1,"channel_id":1}` | 204 · **409** if the patch isn't `ready` |

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

| Method | Path | Response |
|---|---|---|
| POST | `/admin/users?email=&name=` | `{"user_id","email","api_key"}` — creates/updates a user and issues an API key (shown once) |

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

### App collaborators

| Method | Path | Auth | Response |
|---|---|---|---|
| GET | `/admin/apps/{appId}/collaborators` | app access | `{"collaborators":[{user_id,email,display_name,role}]}` |
| POST | `/admin/apps/{appId}/collaborators?email=&role=` | app access | `{app_id,user_id,role}` — the user must already exist |
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
| GET | `/login?...` | start `shorebird login` — self-consents `LOGIN_EMAIL`, or redirects to the external IdP when `IDP_*` is configured |
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
| GET | `/console` | public page | the web dashboard (connect with an API key) |
| GET | `/admin/ui` | public page | thin admin page |

---

## Headers the CLI sends

Every CLI request also carries `x-version:<pkg>` and `x-cli-version:<pkg>`
alongside `Authorization`. The server does not gate on these; they're advisory.
