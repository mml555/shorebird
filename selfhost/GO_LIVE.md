# Go-live spec — from "works on my machine" to "my users get patches from my infra"

This is the **decision + sequencing** spec for Path 1 (production deployment).
It sits above `packages/code_push_server/PRODUCTION.md`, which is the operational
runbook for *running the box* (secrets, first boot, TLS, backups, scaling,
security checklist). This doc covers what that runbook assumes you've already
decided: which shape to deploy, the pieces that live outside the compose stack,
the order to cut your real app over, and what you personally must supply.

Nothing here needs new server code — it's all configuration, infrastructure, and
credentials.

---

## 1. Pick a deployment shape

The server is stateless (all durable state is in Postgres + object storage), so
the only real decision is *where the stateful pieces live and what fronts
downloads*. Pick by fleet size.

| Shape | Fleet | What runs it | Effort |
|---|---|---|---|
| **A — Single box** | dev / internal / < ~5k devices | One Linux VPS, Postgres + MinIO in-compose, Caddy for TLS. `PRODUCTION.md` as written. | ~1 hour |
| **B — Managed services** (recommended prod) | ~5k–100k devices | Stateless `server` replicas + Caddy, but Postgres and object storage are **managed/external**, and a **CDN** fronts downloads. | ~1 day |
| **C — At scale** | 100k–millions | Shape B + a real load balancer, horizontal autoscaling of `server`, Postgres read-replicas, multi-region CDN/object store. | ongoing infra work |

Most real deployments want **B**. The jump from A→B is purely "stop running the
stateful containers yourself and point env vars at managed equivalents" — the
server doesn't change.

---

## 2. Beyond the box — what PRODUCTION.md does *not* provision

The compose stack gives you a working server. These pieces live around it and
you provision them yourself (Shape B/C):

- **Domain + DNS** — an A/AAAA record for e.g. `cps.yourco.com`. Required for
  real TLS (Caddy ACME) and it's the `base_url`/`PUBLIC_BASE_URL` your apps bake
  in. Choose it carefully: **changing it later strands every already-shipped
  app**, since `base_url` is compiled into the binary.
- **Managed Postgres** — RDS / Cloud SQL / Neon / Supabase / etc. Point
  `DATABASE_URL` at it and drop the in-compose `postgres` service. Turn on
  automated backups + PITR + a read replica if you're at Shape C.
- **Object storage** — S3 / Cloudflare R2 / GCS / managed MinIO. Point the
  `S3_*` env at it. This is where artifact bytes live and grow (releases ×
  archs × history); set a lifecycle/retention policy.
- **CDN for downloads** — put Cloudflare / Fastly / CloudFront in front of the
  download path so device fetches hit an edge, not your origin. The signed-URL
  design already supports pointing `download_url` at object storage/CDN rather
  than streaming through the app — this is the single biggest scale lever, and
  the main thing hosted Shorebird gives you that a single box doesn't.
- **Monitoring + alerting** — an uptime check on `/readyz` (it verifies DB + S3
  reachability), log aggregation for the `server`/Caddy containers, and an alert
  when `/readyz` fails or error rate climbs. Failure mode is safe (devices keep
  running last-good code) but you still want to know.
- **Secrets management** — for Shape B/C, source the `.env` secrets from a
  secret manager rather than a file on disk; keep a rotation plan. `config.dart`
  `validate()` already refuses dev-default secrets when `PRODUCTION=true`.

---

## 3. The app-cutover sequence (the actual go-live)

Do these in order. Steps 1–2 are one-time infra; 3–6 are the app cutover.

1. **Stand up the server** at `https://cps.yourco.com` — one command:
   `./setup.sh --domain cps.yourco.com --email you@yourco.com` (generates
   secrets, starts the stack behind Caddy TLS, `PRODUCTION=true`). For Shape B/C,
   point `DATABASE_URL`/`S3_*` at managed services in `.env` afterward. Details:
   `PRODUCTION.md`.
2. **Seed identity** — create the org + app; create a per-user API key (or wire
   the real IdP, §4). Confirm `GET /users/me` and `/apps` respond.
3. **Point your app at your server** — set `base_url: https://cps.yourco.com` in
   the app's `shorebird.yaml` (this one field redirects both the CLI and the
   on-device updater).
4. **Prove the loop on a device** — `shorebird release <platform>` → install →
   `shorebird patch <platform>` → relaunch and confirm the device fetched and
   applied the patch **from your server** (check server logs for its
   `/patches/check` → `/download` → `__patch_install__`). This is the same
   verification already passing for Android/iOS/macOS.
5. **Ship to the stores** with `base_url` baked in. From the moment users install
   that build, they check your server for patches.
6. **Operate** — every subsequent `shorebird patch` flows through your infra;
   use rollouts/withdraw/rollback as normal. No further Shorebird contact in the
   code-push path.

---

## 4. What you must supply (the externally-blocked prerequisites)

These are blocked only because they need credentials/hardware that must come
from you — the code is built and, where possible, stub-verified:

- **Real Google / Microsoft login** — an OAuth **client id + secret** from your
  IdP, plus registering `<PUBLIC_BASE_URL>/oauth/callback` as the redirect URI.
  Set `IDP_CLIENT_ID` / `IDP_CLIENT_SECRET` / `IDP_AUTHORIZE_URL` /
  `IDP_TOKEN_URL`. Full walkthrough: `selfhost/IDP_SETUP.md`. (Broker is built;
  verified against a stub IdP. Skip entirely if `sb_api_` keys are enough.)
- **iOS at production scale** — a **registered bundle id + provisioning profile
  under your Apple Developer team** (device patching was proven via a resign
  flow without an Xcode account, but a shipping app wants proper signing). See
  `selfhost/IOS_ONDEVICE.md`.
- **Windows / Linux release+patch** — a **build host of that OS** (you can't
  build those engines from macOS). The server is already platform-agnostic; this
  is a build-host gap, not a server gap. See `selfhost/DESKTOP_PLATFORMS.md`.

---

## 5. Go-live checklist

- [ ] Deployment shape chosen (§1); managed Postgres + object storage + CDN
      provisioned if Shape B/C (§2).
- [ ] Domain + DNS + TLS live; `PUBLIC_BASE_URL` / `SHOREBIRD_JWT_ISSUER` match
      the HTTPS URL (`PRODUCTION.md` §4).
- [ ] All secrets real (`PRODUCTION.md` §8 security checklist complete).
- [ ] Backups configured **and a restore tested** (`PRODUCTION.md` §5).
- [ ] Uptime alert on `/readyz`; logs aggregated (§2).
- [ ] Device loop proven on your prod server (§3 step 4) before store submission.
- [ ] `base_url` baked into the store build points at the **permanent** domain.
- [ ] IdP / Apple / desktop prerequisites supplied for the platforms you ship
      (§4).

---

## Where this leaves independence

Completing this makes you independent of Shorebird's **service** — no
`api.shorebird.dev` at runtime or build time (the CDN mirror in `selfhost/cdn`
covers build-time for pinned revisions). It does **not** make you independent of
their prebuilt engine *binary*; that's Path 2 (`selfhost/ENGINE_BUILD.md`), for
which the source is already captured (`vendor/flutter`, `vendor/updater`) as
insurance. For almost every deployment, Path 1 is the finish line and Path 2 is
insurance you only cash in if forced.
