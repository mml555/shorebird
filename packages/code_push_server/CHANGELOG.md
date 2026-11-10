<!-- cspell:words ungated rsassa -->

# Changelog

All notable changes to `code_push_server` are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
package follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Security

- **IdP id_tokens are now validated.** Broker login checks `aud` (must contain
  `IDP_CLIENT_ID`, plus `azp` if several), `exp`, `iss` (against the new
  `IDP_ISSUER`) and `email_verified`, and logs the reason for each rejection.
  A top-level `email` in the token response is no longer accepted.
  - **Action required if your IdP omits `email_verified`** (Microsoft Entra
    does): logins fail with `invalid_id_token` until you set
    `IDP_ALLOW_UNVERIFIED_EMAIL=true`.
  - **Action required in production with an IdP:** `IDP_ISSUER` is now
    mandatory and the server refuses to boot without it.

### Added

- **`CRASH_RETENTION_DAYS`** (default `0` = keep forever, like
  `EVENT_RETENTION_DAYS`) sweeps `crash_reports` hourly. In production the
  server warns at startup while event or crash retention is unlimited.

## 1.4.0 — 2026-11-08

### Changed

- **The object store is no longer MinIO.** MinIO's Community Edition is archived
  and its images are gone from Docker Hub, so `docker-compose.prod.yaml` now runs
  SeaweedFS 4.52 (Apache-2.0, pinned by digest) as service `s3`, and the server's
  own S3 client replaces the unmaintained `package:minio` (SigV4 over `dart:io`,
  no new dependencies). The store is generic S3: AWS S3, Cloudflare R2, Garage
  and RustFS work by `S3_ENDPOINT`, and the new `S3_REGION` and `S3_PATH_STYLE`
  (default `true`). See PRODUCTION.md, "Migrating from MinIO".
  - **Your `.env` needs no edits.** `S3_ENDPOINT=http://minio:9000` still
    reaches the new store, and `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` are
    deprecated aliases of `S3_ACCESS_KEY` / `S3_SECRET_KEY` (the new names win
    when both are set). The server logs one `WARNING` per alias at startup.
  - **Action required: copy your artifacts once.** The old bucket is in the
    `cps_minio` volume in MinIO's format. Before `docker compose up -d` on the
    new compose file, run `./ops/migrate-minio-to-s3.sh`: it copies the bucket
    with rclone and verifies every object, and deletes nothing. Without it the
    new store starts empty and downloads 404.
  - The MinIO console (port 19001) is gone; SeaweedFS has none.
  - `ops/backup.sh` and `ops/restore.sh` use a pinned rclone instead of `mc`
    (`minio/mc` is no longer published). New backups write `objects/<STAMP>/`;
    `minio/<STAMP>/` backups from before still restore. Both now verify the
    copy with `rclone check`.
  - Tested on real instances: SeaweedFS 4.52 and RustFS 1.0.4 each pass the
    store operations (bucket create, put, HEAD, ranged GET, delete, staging),
    the full wire-flow smoke test, and a migration from MinIO
    `RELEASE.2025-10-15T17-29-55Z`. SeaweedFS is the default; RustFS 1.0 is only
    weeks old and has open data-integrity issues, so it is documented as an
    alternative.

- `POST /api/v1/patches/events` answers `422` when an event cannot be stored
  even verbatim (for example a NUL character in the body on Postgres), instead
  of `500`. The updater retries a `500` forever, which blocked its queue.
- Rollback wording for deleting a release names the 7-day grace period
  (`releaseDeleteGrace`): rolling a patch back does not allow an immediate
  delete without `force`.
- **`PATCH_SIGNING_KEY_SECRET` is now required for managed signing, and no
  longer falls back to `URL_SIGNING_SECRET`.** Rotating a secret operators
  rotate for other reasons must never strand the stored signing keys. It is
  required (boot refuses) when `PRODUCTION` is set; otherwise unset, `GET
  /apps/{app}/signing-key` and managed patch signing answer 503 naming the
  variable. At boot a stored key is trial-decrypted and the server refuses to
  start, naming the variable, if it does not decrypt. New keys carry a `kid`
  (`v1`) in the JWE header so a later rotation can add a second version.
  **Breaking, deliberately clean:** the fallback never shipped in a
  release, so there is no migration. A database whose keys were
  wrapped under the `URL_SIGNING_SECRET` fallback will not boot until you set
  `PATCH_SIGNING_KEY_SECRET=<that URL_SIGNING_SECRET value>`; delete the
  `signing_keys` rows instead only if no release was built with a managed key.
  Back the secret up with the database.
- `/login` now requires `code_challenge` (PKCE S256) with `redirect_uri`. The
  legacy `continue` form still works without one.
- Patch artifacts with arch `symbols` need no `hash_signature` and are never
  server-signed. Arch `assets` is signed like code: server-signed on managed
  releases, and on customer-signed releases it needs a `hash_signature` (400
  without), because devices verify the installed assets bundle in Strict mode.

- `DELETE /apps/{app}/releases/{release}` answers 409 while any patch of the
  release is live on a channel. Rolling the patch back unblocks deletion. Pass
  `?force=true` through the console or API to delete anyway; the CLI sends no
  force, and the message says to roll the live patches back first.
  Deleting is also refused (409) for 7 days (`releaseDeleteGrace`) after any
  patch of the release was rolled back or withdrawn, because deleting removes
  the `channel_patches` rows a device that has not checked in since needs to
  learn to drop the patch. The message says when the release becomes deletable
  and that `?force=true` overrides it.

### Added

- `GET /cli/login-result`: the page the 1.6.138 CLI sends the browser to after
  a loopback login.

- **Upstream 1.6.138 CLI support.** The 1.6.138 CLI could not talk to this
  server: it casts `platforms` on every release as non-null, calls
  `GET /apps/{app}` and `GET /apps/{app}/signing-key`, and logs in with a
  standard PKCE authorization-code request. Older CLIs keep working: every
  change is additive.
  - **`platforms` on releases**: `{platform: {status, signing_mode?}}`, beside
    the unchanged `platform_statuses`. Patches also carry `created_at`, and app
    entries `organization_id`.
  - **`GET /api/v1/apps/{app}`**: one `AppMetadata`. 404 (never 403) for an app
    the caller cannot see.
  - **Managed patch signing** (migration 14). `GET /apps/{app}/signing-key`
    creates the organization's RSA-2048 key on first fetch and returns the
    public half. Release artifacts accept and return `signing`. For a release
    built in `managed` mode the server signs each patch's hash on registration
    (RSASSA-PKCS1-v1_5 / SHA-256 over the hex hash string, the scheme the
    updater verifies); a client `hash_signature` is refused. A `customer`
    release requires one. Releases made before this change are never
    server-signed. Private keys are stored as JWE under the new
    `PATCH_SIGNING_KEY_SECRET` (min. 32 characters; see Changed, above: it
    no longer falls back to `URL_SIGNING_SECRET`) and are never returned or
    logged.
  - **`DELETE /apps/{app}/releases/{release}`** and
    **`DELETE …/releases/{release}/artifacts?platform=`** (app admin; audited
    as `release.delete` / `release.artifact.delete`). The artifact store gains
    `delete`.
  - **Login**: `/login` accepts upstream's `redirect_uri` + `state` as well as
    `continue`, and verifies PKCE S256 at `/token` (migration 15). A `continue`
    login with no `code_challenge`, as an older CLI sends, redeems without a
    verifier; `redirect_uri` requires one (see Changed, above).
    `POST /revoke` (RFC 7009) backs `shorebird logout`.

- **Upstream 1.6.123 `apps rename`, `apps transfer` and `channels delete`.**
  `PATCH /api/v1/apps/{app}`, `POST /api/v1/organizations/{org}/apps` and
  `DELETE /api/v1/apps/{app}/channels/{channel}`, all under one rule: admin at
  every scope the mutation changes. Rename and channel delete need an app
  admin. Transfer needs an owner/admin of both orgs; a collaborator grant never
  counts at org scope. A transfer is refused while the app has collaborators
  outside the destination org's email-domain allowlist. Channel delete is a
  soft delete (migration 13): the channel stops serving patches but its devices
  still receive rollbacks, recreating the name restores it empty, and
  `stable`/`beta`/`staging` cannot be deleted. Audited as `app.update`,
  `app.transfer` and `channel.delete`.

- **Upstream 1.6.123 `shorebird patches rollback` works against this server.**
  `POST /api/v1/apps/{app}/releases/{release}/patches/{patch}/rollback` rolls
  the patch back on every channel where it is active (the same withdrawal as
  `/admin/.../withdraw?rollback=true`), answers 304 when it is already rolled
  back, and is audited as `patch.withdraw`. `.../rollforward` is intentionally
  unsupported and answers `501 unsupported`: a rolled-back patch stays
  withdrawn permanently.

- **Control-plane mutations are auditable.** Every mutating patch-lifecycle
  request — `app.create`, `release.create`/`update`, release and patch artifact
  registration, `artifact.upload`, `patch.create`/`update`/`promote`/
  `withdraw`/`rollout`, `channel.create` — now writes exactly one structured
  `audit_log` row, plus a JSON line to the operational log sink. Each row
  answers when, who (account *and* a non-reversible fingerprint of the
  credential presented), what operation, which app/release/patch/track, what
  outcome, what HTTP status, and which request caused it.

  Read it at `GET /admin/audit` (root-org owner/admin), filtered by
  `app_id`/`release_id`/`patch_id`/`request_id`/`operation`/`result`/`after`/
  `since`. The response always carries `ceiling` — the current maximum audit id
  — so "this published nothing" can be stated as *no `patch.create` row above
  id N*, which is falsifiable, rather than as "I looked and saw nothing", which
  is not. Migration 11; `AUDIT_RETENTION_DAYS` still governs retention.

  Three properties are structural rather than conventional. The outcome is
  derived from the response the server actually sent, so no handler can assert
  `success` for work that conflicted, was forbidden, or threw. The auditing
  middleware sits *outside* authentication and rate limiting, so an attempt
  refused by a bad credential is recorded rather than indistinguishable from
  nobody having tried. And a route that is not a recognized mutation has no
  code path that writes a request-outcome row, so a read cannot masquerade as
  one.

  Nothing sensitive is recorded: the event is an allowlist of computed fields,
  never a copy of a header or body, so API keys, JWTs, authorization headers and
  upload tokens are structurally absent — with credential-shape scrubbing as a
  backstop on free text.

- **Identity and tenancy mutations are typed audit outcomes too.** The state
  that decides *who may mutate releases and patches* used to be recorded only as
  free-text notes. `user.create`, `user.register`, `org.invite`,
  `org.invite.accept`, `org.invite.revoke`, `org.member.role`,
  `org.member.remove`, `org.domains`, `app.collaborator.add` and
  `app.collaborator.remove` now each write one typed request row with a result
  and an HTTP status, alongside two new columns (migration 12): `org_id`, and
  `target_kind` — which finally makes the pre-existing `target` column typeable
  (`user` → a user id or email, `org` → an org id, `invitation` / `api_key` → a
  fingerprint).

  Access-control changes bank **both sides**: `role_before` / `role_after` on
  memberships and collaborator grants, `domains_before` / `domains_after` on the
  org email policy. `addCollaborator` upserts, so that route silently *changes*
  an existing grant as well as creating one — recording only the new role could
  not tell a fresh `developer` from a quiet `developer -> owner`.

  Values a caller supplied in the query string are banked **before**
  authorization decides, so a refused attempt keeps its subject: an outsider
  trying to grant themselves `owner` on someone else's app appears as exactly
  that rather than as a bare 403. (Request *bodies* are still never read before
  authentication — see the previous entry.)

  `POST /login` and `GET /oauth/callback` stay unclassified: they are public
  routes, and classifying them would let an unauthenticated caller write a row
  per request. `admin.denied` also stays a detail row, because it is the only
  trace of a denied *read* of the operator surface — `GET /admin/audit`
  included, which by design writes no mutation event.

- **`POST /admin/users` records which credential it issued**, as
  `api_key_issued`: 12 hex characters of SHA-256 of the returned key, never the
  key. Enough to match a key found in a CI config back to the request that
  created it. It also records `account_existed`, because that route returns the
  existing account on an email conflict — so a key issued against an account
  that already existed is a distinct, more interesting event.

- **`X-Request-Id` on every response**, echoed on the request log line and
  stored on the request's audit event. Adopted from an inbound header only when
  the socket peer is a configured trusted proxy.

- **`code_push_audit_events_total`** and **`code_push_audit_write_failures_total`**
  at `/metrics`. The second above zero means the durable trail has holes — an
  audit write failure is logged loudly and the event still reaches the log sink,
  because the mutation has already happened by then and a silently missing row
  is what makes "nothing was logged" mean nothing.

- **Assets-only patches.** `patches/check` can now serve a patch whose payload
  is an asset bundle and nothing else, which is what lets the engine's asset
  overlay ship on platforms where shipping *code* needs the AOT linker — there
  is nothing to link or interpret. The response always carries a `kind`
  (`code` | `assets`).

  Gated behind a `supported_patch_kinds` capability in the request rather than
  simply announced, because the failure mode is sticky: a stock updater handed
  an assets-only patch would try to inflate the archive as a binary diff, fail,
  and tombstone the patch as permanently bad for that release. Silence means
  code-only, and a wrong-typed capability is read as no support.

  A patch carrying both a code artifact and a bundle still reports `code`; the
  bundle continues to be fetched separately via `patches/assets`.

### Fixed

- **An interrupted release is recoverable.** Registering a release artifact used
  to conflict unconditionally on a second attempt, which made a killed
  `shorebird release` terminal: the CLI rebuilds and re-uploads a platform's
  artifacts in a fixed order, so the retry died re-sending the one that already
  landed and never reached the ones still missing — and this API has no `DELETE`
  to clear the way.

  Found the hard way on 2026-07-30. Cutting `2.0.0+1785465879` was killed
  mid-upload with iOS `xcarchive` registered and `runner` + `ios_supplement`
  missing. The release sat at `{android: active, ios: draft}` and no invocation
  could finish it.

  A byte-identical re-upload now returns the existing registration. A *differing*
  hash while the release is still `draft`/`uploading` supersedes the stale row
  (marked `failed`, which the duplicate lookup skips) and is audited as
  `artifact.superseded` — matching on hash alone would have missed the real case,
  since a rebuild never reproduces the previous bytes. From `ready` onward a
  differing hash stays a hard conflict: those artifacts are what installed apps
  run and what patches are linked against, so swapping one would silently
  invalidate every patch built from it.

- **A platform can no longer be activated with an incomplete artifact set.** The
  gate asserted that every artifact *present* was verified, not that the expected
  set was complete, so a lone verified `xcarchive` would activate an iOS release
  that no patch could ever be linked against — surfacing at patch time, far from
  the cause. Now compared against a per-platform required set.

  Platforms absent from that set are deliberately ungated. Blocking a target
  whose artifact list this server has never learned would stop it shipping
  outright, which is worse than closing the hole late.

- **A client that cannot install the active patch is now offered the newest one
  it can**, instead of nothing.

  Found by promoting a real assets-only patch: promotion withdrew the release's
  code patch, and because a stock updater cannot be offered an assets patch,
  `patches/check` returned `patch_available: false` for it. A device already
  running the code patch kept it, but a fresh install would have run unpatched
  code that the previous patch had fixed — silently, with nothing in the rollout
  to show it.

  The fallback walks superseded patches newest-first and applies every gate the
  active path applies: same release, `ready`, newer than the client's, and
  eligible under that patch's own rollout — a fallback that skipped those would
  be a way to receive a patch a rollout excluded. Rolled-back patches are never
  candidates: superseded means *replaced*, rolled back means *pulled for cause*,
  and conflating them would resurrect a patch someone deliberately withdrew.

  Consequence worth understanding: client classes can now legitimately sit on
  different patch numbers, each running the newest patch it supports. That is
  intended. It follows from a device being able to boot only one patch, which
  makes an assets-only patch and a code patch alternatives rather than additive.

## 1.3.0 — 2026-07-29

### Added

- **Patch asset bundles are stored and served**, so a patch can change assets —
  images, fonts, JSON — and not only Dart code. The bundle rides along as an
  ordinary patch artifact tagged `arch: assets`, which needed no schema change
  and no new upload path, because `arch` is free-form end to end.
  - `POST /patches/assets` — device-facing and unauthenticated, like the rest of
    the device surface: an app in the wild knows only its `app_id`. Takes
    `{app_id, release_version, platform, patch_number}` and answers
    `{assets_available, assets: {url, hash, size}}` with a signed download URL.
  - Malformed or unknown input answers "nothing here" rather than erroring. This
    is polled on launch by app code, and a hard failure would be a needless
    crash path for a purely additive feature.
  - A **rolled-back patch stops serving its assets**, or an app that had reverted
    would keep using the newer bundle against older code.

  The native updater is never involved, which is what keeps this off the
  engine-build critical path — and therefore working on iOS as well as Android.

- **Crash reports are ingested, retained, and symbolicated** (schema migration
  **v8**), so a self-hosted deployment gets crash visibility without a
  third-party SDK. Boot-crash rollback already existed; the stack trace
  explaining *why* never left the device.
  - `POST /crashes` — device-facing and unauthenticated. It always answers
    `200 {stored: bool}` and swallows malformed input **on purpose**: the client
    is an app that just died, and making it fight 4xx/5xx is a second failure on
    top of the first. A test named `garbage never fails the reporter` guards it.
  - `GET /api/v1/apps/{appId}/crashes` — authed, filterable by
    `release_version` / `patch_number`.
  - `?symbolicate=true` adds `stack_symbolicated` beside the raw `stack`,
    resolving the trace against the debug symbols the CLI retains for that patch
    (`arch: symbols`).

  Symbolication is pure Dart: what the CLI retains is Dart's own
  `--split-debug-info` output, which is what `flutter symbolize` reads through
  `package:native_stack_traces`, and that package handles both the ELF form
  (Android) and the Mach-O form (Apple). So one implementation covers every
  platform inside this Linux container — no `llvm-symbolizer`, no `atos`, no Mac
  worker. Those would only matter for native Objective-C/C++ frames out of a
  dSYM, which a Dart crash handler does not produce.

  Notable choices:
  - **Read-time, never ingest-time.** Ingest must stay unfailable, and symbols
    are routinely uploaded *after* a crash has already arrived, so resolving at
    ingest would permanently miss.
  - **Opt-in.** Resolving costs a fetch, unzip and DWARF parse per distinct patch
    in the page, so the default response is unchanged for existing callers.
  - **Never guesses the symbol file.** Arch matching is on the
    `-<token>.symbols` suffix rather than a substring: `arm` is a prefix of
    `arm64`, so a substring match would hand arm64 symbols to an arm32 crash and
    resolve every frame to a wrong address — a failure that looks like success.
    Given several candidates and no arch match it resolves nothing.

  Verified end to end against a physical Android device: a crash thrown from
  patched code resolved to exact function names and line numbers.

## 1.2.0 — 2026-07-29

### Fixed

- **`shorebird patches info` / `patches list` / `patches set-track` failed for
  any patch that had artifacts.** The patch-artifact payload omitted
  `created_at`, and the CLI's `PatchArtifact.fromJson` does an unguarded
  `DateTime.parse(json['created_at'] as String)` — so every real patch came back
  as `FormatException: type 'Null' is not a subtype of type 'String'`. Only
  artifact-less patches, which no real patch is, appeared to work, which is why
  the unit suite never caught it. The column already existed on `artifacts`; it
  was simply never surfaced.

- **A patch's track was always reported as absent.** `channel` was hardcoded
  `null` in the patch payload, so `shorebird patches list` printed
  `[no track]` and `patches info` never showed a `Track:` line, even for a patch
  promoted seconds earlier. It also made `set-track`'s "already in that track"
  check dead code, so it silently re-promoted every time. The field now reports
  the newest deployment that is still active and not rolled back (and `null`
  once every promotion has been withdrawn or reverted). The richer
  `deployments` array is unchanged and remains authoritative.

  Both bugs predate this branch and were found by driving the real pinned CLI
  against a containerized server on Postgres — not by the unit suite.

### Added

- **Release and patch notes are stored and served.** The CLI wire contract has
  always carried a `notes` field on both the `Patch` and `Release` DTOs, and
  `shorebird releases info` / `shorebird patches info` already print it — but
  the server hardcoded `null` on every response, so the field could never be
  used. Notes are now persisted (schema migration **v5**) and surfaced:
  - `POST /api/v1/apps/{appId}/releases` and `POST /api/v1/apps/{appId}/patches`
    accept an optional `notes`.
  - `PATCH /api/v1/apps/{appId}/releases/{releaseId}` accepts `notes`, matching
    the semantics upstream's own `UpdateReleaseRequest` documents: absent or
    `null` leaves notes unchanged (the CLI sends `notes: null` on every
    mid-release status update, so this must not clear them), `""` clears, and a
    non-empty string is stored. Capped at 4096 characters; over-length is a
    `400` with nothing written.
  - `PATCH /api/v1/apps/{appId}/patches/{patchId}` is new, with the same
    semantics — upstream carries `notes` on its `Patch` DTO but exposes no way
    to set it.
  - The console's patch cards show notes and edit them inline.
  - Both writes land in the audit log (`release.notes`, `patch.notes`).

  Addresses upstream shorebirdtech/shorebird#1288 and #3767. No CLI change is
  needed — the pinned CLI already parses and prints the field.

- **An organization can be restricted to one or more email domains**, so a
  personal account can't be added to a company org or onto one of its apps
  (schema migration **v6**). Managed from the console's **Team** tab, or:
  - `GET /admin/orgs/{orgId}/domains` — read the allowlist.
  - `PUT /admin/orgs/{orgId}/domains?domains=company.com,company.co.uk` — set
    it; `?domains=` clears it.

  With a policy set, both org invitations and app-collaborator grants reject an
  out-of-domain address with `403`, naming the policy. Notable choices:
  - Unrestricted is the default, so existing deployments are unaffected.
  - Existing members are never evicted — the policy governs who can be *added*
    from then on. Evicting silently on the next request is a far worse failure
    than refusing an add.
  - A policy that would exclude every owner/admin is refused with `409`: it is
    only ever a typo, and it would leave nobody able to invite.
  - Matching is exact on the domain, so `company.com` does not admit
    `mail.company.com` and the org can't be widened by a subdomain someone else
    controls. A non-empty list that parses to no valid domain is a `400`, not a
    silent clear.

  Addresses upstream shorebirdtech/shorebird#3056.

- **Build provenance is captured instead of discarded** (schema migration
  **v7**). The CLI already attaches a `metadata` blob to every release status
  update and patch creation — Shorebird/Flutter versions, OS and Xcode versions,
  which flags were used, `BuildTraceSummary` timings — and the server threw all
  of it away. It is now stored per release and per patch, returned on the
  release and patch list endpoints, and shown under **Build provenance** in the
  console. The pinned CLI ignores the extra response key, since its DTOs parse
  field by field.

  Two deliberate choices:
  - **Recorded even when the request fails.** Metadata is written *before* the
    release status gate, so it survives the fail-closed `409` from activating
    before all artifacts verified. That is precisely when knowing what built the
    release is most useful, so discarding it there would be backwards. This is
    the opposite of the `notes` rule above, because metadata is diagnostic data
    rather than state anyone reads.
  - **Never fatal.** The blob's shape is upstream's to change, so a `metadata`
    that isn't a JSON object is ignored rather than rejected, and anything over
    64 KiB is dropped with a warning. A release is never failed over its own
    diagnostics.

  This is the storage and display half of shorebirdtech/shorebird#3443 (know
  which git commit a release was built from) and #3700 (record `--dart-define`
  at release time, warn on patch if it changed). Both need `shorebird_cli`
  changes to put those fields into the blob before they're fully covered.

## 1.1.0 — 2026-07-28

Shipped in the `selfhost-v1.0.0` distribution baseline.

Security and hardening pass over the HTTP surface. Several entries are
**breaking for an in-place upgrade** — read "Changed" before deploying.

### Security

- **The published placeholder secrets are refused at boot, in every mode.**
  `API_KEY=sb_api_selfhost_dev` and `URL_SIGNING_SECRET=dev-url-signing-secret`
  are committed to this repository, and `validate()` only rejected them under
  `PRODUCTION=true`. Nothing on the zero-config path set `PRODUCTION`: the
  default `docker-compose.yaml` supplied both as defaults, published port 8080
  on **all** host interfaces, and advertised `docker compose up -d` as a
  supported start. Anyone who could reach the port sent
  `Authorization: Bearer sb_api_selfhost_dev` and was an owner of the root org —
  server admin, so `POST /admin/users` mints a durable key for any address and
  any patch can be promoted to every device — while the known signing secret
  forged `/download` URLs for any artifact. The check now runs in every mode,
  the compose file requires both secrets (`:?`) instead of defaulting them, and
  the published port binds to `127.0.0.1` unless `HOST_BIND` says otherwise.
  **Breaking:** a deployment running on the placeholders will not restart —
  run `./setup.sh` or set both to `openssl rand -hex 32` values.
- **Invitation expiry is actually enforced on the default backend.** The
  7-day window was checked in Dart with `expires_at is DateTime`, but
  `TIMESTAMPTZ` becomes `TEXT` under the SQLite translation — so on the
  single-container default the value was a `String`, the guard never fired,
  and invitations never expired. A leaked accept link kept working
  indefinitely and granted whatever role it carried, up to `owner` of an
  organization. (Accepting still requires authenticating as the invited email
  and is single-use, so this needed a leaked token plus control of that
  identity.) The comparison now happens in SQL, where both backends agree —
  the same reason `consumeAuthCode` and `consumeIdpState` already filter
  there. Regression test: `test/api_test.dart`, "an expired invitation is
  refused on the SQLite backend".
- **`LOGIN_EMAIL` no longer grants root-org ownership when an IdP is
  configured.** `ensureRootOwner` ran on every boot regardless of mode, but
  `LOGIN_EMAIL` is documented as ignored once the `IDP_*` broker is enabled,
  and `setup.sh`'s local branch leaves the placeholder `you@example.com`
  behind. On upgrade that address was created and made an owner of the root
  org — i.e. whoever could present it to the IdP got `POST /admin/users`. It
  is now applied only in self-consent mode.

- **`POST /admin/users` now requires an operator.** It issues an API key and
  returns the *existing* account on an email conflict, so any authenticated
  tenant could name the seeded owner and be handed an owner key. It now
  requires an owner/admin of the root organization (the identity `API_KEY`
  maps to); everyone else gets 403.
- **Rate limits can no longer be rotated around.** Buckets were keyed on the
  raw `Authorization` header — client-supplied, and not validated until after
  the limiter runs — so a fresh random bearer bought a fresh window on every
  request. Every request is now also charged against an un-rotatable per-source
  -IP bucket, and the bearer is hashed rather than used verbatim (it was
  unbounded, and with `RATE_LIMIT_BACKEND=postgres` it was written to an
  indexed column).
- **`X-Forwarded-For` is only believed from a configured proxy** — see
  `TRUSTED_PROXIES` below — and the hop taken is the rightmost one the client
  could not have written, which is correct for proxies that append as well as
  those that replace.
- **`POST /diagnostics/speedtest` no longer buffers.** The upload path held the
  whole body (up to `MAX_UPLOAD_BYTES`, 512 MiB) in memory before enforcing its
  own cap, on a public endpoint. It now streams, capped at the CLI's probe size.
- **Every body read is capped.** `/patches/check`, `/patches/events`, `/login`
  and `/token` are public and read the body with an uncapped `readAsString`.
- **A `continue` URL with CR/LF is refused.** It was echoed into a `Location:`
  header, which dart:io then refuses to write mid-response — leaving the
  request hanging and its socket pinned, unauthenticated.
- **`DB_SSL_MODE` fails closed.** An unrecognized value (`verify_full`,
  `required`) silently fell back to `disable`, sending database credentials in
  the clear. The server now refuses to boot, and warns when a non-local
  Postgres is reached with SSL off.
- **Roles are validated everywhere.** Org invitations and member-role changes
  wrote the query string straight through; authorization matches exact values,
  so `Admin` read as no privileges and could strand an org with no admin. The
  last owner/admin can no longer be demoted either — until now only removal
  was guarded — and an update with no `role` parameter is an error rather than
  a silent demotion to `developer`.

### Fixed

- **A patch for one platform no longer evicts the other.** The Shorebird CLI
  publishes one patch *per platform* — `--platforms=android,ios` creates two —
  but `promote()` withdrew every other active patch on the channel regardless
  of platform. Whichever platform was promoted last won, and devices on the
  other silently fell back to `patch_available: false`, with nothing in the
  logs to say why. Supersession is now scoped per platform, and
  `/patches/check` selects the newest active patch that actually carries an
  artifact for the requesting platform, so an Android device is never offered
  an iOS-only patch. A channel holds at most one active patch **per platform**.
  Regression test: `test/db_test.dart`, "an ios patch does not evict an active
  android patch".
- **…and a single-platform patch no longer evicts a multi-platform one.**
  Scoping supersession to *any* platform overlap re-created the same bug in the
  other direction: nothing stops a patch carrying artifacts for several
  platforms, so promoting an android-only patch over an active android+ios one
  withdrew the whole `channel_patches` row and unserved the iOS devices. A
  patch is now superseded only when the incoming one covers **every** platform
  it carries; a partially-covered patch stays active, and `activeChannelPatch`
  resolves per platform. Regression test: `test/db_test.dart`, "a
  single-platform patch does not evict a multi-platform one".
- **A duplicate artifact registration no longer strands the patch.** The
  `existingArtifact` conflict check ran *after* the patch moved to `uploading`,
  and `ready -> uploading` is a permitted transition. A CLI retry of a
  registration that had already succeeded (response lost) flipped the patch out
  of `ready` and only then returned 409 — leaving it somewhere neither
  `patches/check` nor promote will accept, permanently. The check now precedes
  the transition. Regression test: `test/api_test.dart`, "a duplicate
  registration leaves a ready patch ready".
- **The scale profile keeps per-device rate limiting on upgrade.**
  `docker-compose.prod.yaml` had no `TRUSTED_PROXIES` default, and `setup.sh`
  writes one only when it *generates* a `.env`. An in-place upgrade therefore
  fell back to `{127.0.0.1, ::1}`, which does not match Caddy's bridge address,
  so `X-Forwarded-For` was ignored and the entire fleet shared one bucket. The
  prod compose file now defaults it the way the other two do.

### Changed

- **`TRUSTED_PROXIES`** (new, default `127.0.0.1,::1`) — literal IPs, IPv4
  CIDR, or `*`. **If you run behind a reverse proxy you must set this**, or
  every request in the deployment lands in one rate-limit bucket. `setup.sh`
  writes `172.16.0.0/12` for both proxied modes; existing `.env` files are
  never rewritten, so **add it by hand when upgrading**.
- **`RATE_LIMIT_IP_PER_MINUTE`** (new, default 10 × `RATE_LIMIT_PER_MINUTE`) —
  the per-source-IP ceiling.
- **`EVENT_RETENTION_DAYS` / `AUDIT_RETENTION_DAYS`** (new, default `0` = keep
  forever) — hourly sweeps for the two tables that otherwise grow without
  bound.
- **Housekeeping runs at startup**, not only on the hourly timer; a server that
  restarted more often than that never swept at all.
- **`Range` handling follows RFC 7233.** Ranges are clamped to the artifact
  (`bytes=100-50` used to be a 500, `bytes=0-99999999999` a hung client).
  A range that is syntactically valid but outside the resource gets 416;
  unparseable, multi-range, and inverted (`bytes=100-50`, invalid per §2.1)
  headers are ignored in favour of a full 200 rather than failing.
- **Malformed request bodies are 400, not 500.** Body-supplied ids and names
  were raw casts, so `{"release_id": "1"}` produced a 500 and a logged stack
  trace on demand. Same for a missing multipart field on artifact registration
  (`fields['arch']!`), which additionally left the patch parked in `uploading`
  where `patches/check` will not serve it. The device path (`/patches/check`)
  stays tolerant.
- **Multipart bodies are bounded in aggregate**, not just per part, and capped
  at 32 parts.
- **Collaborator/member roles are limited to `owner`, `admin`, `developer`.**
  The console previously offered `appManager` and `viewer`, which no
  authorization check understood.
- **`LOGIN_EMAIL` is made an owner of the root organization at boot**, so the
  operator can still issue API keys after `shorebird login` (the seeded root
  user is `owner@self-host.local`, but `setup.sh` writes its own `LOGIN_EMAIL`).

## 1.0.0 — 2026-07-27

First production release of the self-hosted Shorebird control plane. Runs
Flutter code-push (over-the-air) updates on your own infrastructure — the
unmodified, pinned Shorebird CLI and on-device updater talk to this server, so
no runtime request depends on `api.shorebird.dev` and there is no
per-app/per-user pricing. Device-verified end-to-end on Android, iOS, and macOS
(release → patch → boot → rollback).

### Added

- **Releases & patches** — full CLI wire contract with lifecycle state-machine
  guards and sha256 verification.
- **Channels** — promote, withdraw, and rollback (installed devices revert).
- **Partial rollouts** — deterministic 5 / 25 / 100 % by client, fail-closed.
- **Signed patches** — `hash_signature` pass-through, verified on-device.
- **Multi-tenancy** — users + per-user API keys, orgs + roles, collaborators,
  and invitations, managed in the console **Team** tab.
- **Login** — `shorebird login` via self-consent or a real IdP
  (Google/Microsoft), RS256 JWT mint/verify.
- **Analytics** — adoption / version / install metrics with a web console at
  `/console`.
- **Ops** — signed download URLs, migrations, audit log, rate limiting, health
  checks, and backup/restore tooling.
- **iOS code-signing tooling** (`tool/ios_*.sh`) — auto / manual / resign paths
  with automatic mode selection, a one-command `ios_ship.sh` release+patch flow,
  export-options-plist generation, and a headless CI keychain recipe. See
  `../../selfhost/IOS_ONDEVICE.md`.
- **Observability** — structured JSON logs (all lifecycle logs routed through
  the structured logger) and a Prometheus `/metrics` endpoint.
- **One-command setup** — `./setup.sh` generates secrets, starts everything in
  Docker, waits for health, and prints the server URL, API key, and ship
  commands. `./setup.sh --domain <host>` adds Caddy TLS.

### Deployment profiles

- **Single container (default)** — embedded SQLite + local-disk artifacts under
  one `/data` volume. No Postgres, MinIO, or Redis required.
- **Scale** — stateless replicas backed by Postgres + S3/MinIO behind Caddy TLS,
  selected automatically when `DATABASE_URL` / `S3_ENDPOINT` are set. Same
  features, same wire contract, same code — only the storage backends differ.

### Security & hardening

- Production hardening pass: rate-limit keying, upload size cap, and request
  timeouts.
- Refuses to boot with dev-default secrets when `PRODUCTION=true`.

### Notes

- Billing is intentionally omitted — a self-host does not bill itself.
- Not published to pub.dev (`publish_to: none`); the deliverable is the Docker
  image and this repository at a known-good commit.
