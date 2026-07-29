# Changelog

All notable changes to `code_push_server` are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
package follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

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
