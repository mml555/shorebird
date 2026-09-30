# Self-hosted Shorebird control plane

Run Flutter code-push (over-the-air) updates on **your own infrastructure**. The
unmodified, pinned Shorebird CLI and on-device updater talk to this server, so no
runtime code-push request depends on `api.shorebird.dev` — and there's no
per-app/per-user pricing.

Device-verified end-to-end on **Android and iOS** (release → patch → boot →
rollback). Corrected 2026-08-13: this line also claimed **macOS** and **signed
patches**, and the status authority holds neither — `selfhost/PARITY.md:2570`
lists macOS `DEFERRED` in every column, and `:2236-2237` list signed
Android/iOS release+patch as `NOT VALIDATED`. The server does pass
`hash_signature` through end to end (see the feature table below); what is
unvalidated is the signed *workflow* on device, which is a different claim.

---

## Quick start (one command)

```bash
cd packages/code_push_server
./setup.sh
```

That's it. `setup.sh` generates all secrets, starts **one container** in
Docker — embedded SQLite + local-disk artifacts — waits until it's healthy, and
prints your server URL, API key, and the exact commands to ship an app.
(Corrected 2026-08-13: this said "server + Postgres + MinIO". That is the
`--scale` stack, and the claim contradicted *Two ways to run* below, which
correctly calls one container the default.) No Dart SDK, no manual
config, no editing secrets by hand.

Then, from your Flutter app:

```bash
export SHOREBIRD_HOSTED_URL=<the URL setup.sh printed>
export SHOREBIRD_TOKEN=<the API key setup.sh printed>
shorebird init          # add `base_url: <that URL>` to shorebird.yaml
shorebird release android
shorebird patch android
```

Stop it with `./setup.sh --down`.

### Going to production (HTTPS on a real domain)

Still a single container — just add Caddy TLS in front:

```bash
./setup.sh --domain cps.yourcompany.com --email you@yourcompany.com
```

Needs DNS pointing at the host and ports 80/443 open; you get an automatic Let's
Encrypt certificate and `PRODUCTION=true` (adds the DB/S3-credential and HTTPS
checks; the published placeholder `API_KEY` / `URL_SIGNING_SECRET` are refused
in every mode). Only when you need horizontal scale do you add Postgres + S3/MinIO with
`./setup.sh --scale --domain …`.

Backups: `./setup.sh --backup` snapshots the data volume, `--restore <file>`
restores it. Behind your own reverse proxy or using your own Postgres/S3? See
[`../../selfhost/INTEGRATION.md`](../../selfhost/INTEGRATION.md). Full ops runbook in
[`PRODUCTION.md`](PRODUCTION.md) and [`../../selfhost/GO_LIVE.md`](../../selfhost/GO_LIVE.md).

---

## What you get

| | |
|---|---|
| **Releases & patches** | full CLI wire contract; lifecycle state machines; sha256 verification |
| **Channels** | promote, withdraw, and rollback (installed devices revert) |
| **Partial rollouts** | deterministic 5 / 25 / 100 % by client, fail-closed |
| **Signed patches** | `hash_signature` pass-through, verified on-device |
| **Release & patch notes** | freeform "why this shipped" notes, shown by `shorebird releases info` / `patches info` and editable in the console |
| **Build provenance** | Shorebird/Flutter/OS/Xcode versions, flags, and build timings recorded per release and patch |
| **Multi-tenancy** | users + per-user API keys, orgs + roles, collaborators, invitations — managed in the console **Team** tab |
| **Org domain restriction** | optionally limit an org to your own email domains, so a personal account can't be added |
| **Login** | `shorebird login` via self-consent or a real IdP (Google/Microsoft) |
| **Analytics** | adoption / version / install metrics + a web console at `/console` |
| **Ops** | signed download URLs, migrations, audit log, rate limiting, health checks, backups |

Everything except billing (intentionally omitted — a self-host doesn't bill itself).

---

## Self-test (no CLI or device needed)

```bash
BASE=http://localhost:8080 KEY=<your API key> tool/smoke_test.sh
```

Exercises the whole wire contract: fail-closed finalize/promote, sha256 verify +
mismatch rejection, patch promote, signed-URL range download, withdraw+rollback.

---

## Shipping to iOS (code signing)

iOS builds must be code-signed, and Shorebird records the exact version it ships
— so signing has to happen the way the CLI expects or patches silently fail to
apply. The `tool/ios_*.sh` scripts handle all three paths and pick one for you:

| Mode | When | Command |
|---|---|---|
| **auto** | Xcode already signs (Apple ID in Xcode or `DEVELOPMENT_TEAM` set) | plain `shorebird release ios` |
| **manual** | Headless / CI — you have a `.p12` cert + provisioning profile | `--export-options-plist` (generated for you) |
| **resign** | No Apple ID in Xcode — resign an unsigned build with an existing cert + profile | `--no-codesign` + `tool/ios_resign.sh` |

One wrapper drives all three (mode inferred from the env you set):

```bash
APP_DIR=$PWD DEVICE=<udid> tool/ios_ship.sh both   # release + patch
```

Full walkthrough — mode selection, the CI keychain recipe, and every tool — is
in [`../../selfhost/IOS_ONDEVICE.md`](../../selfhost/IOS_ONDEVICE.md).

---

## Two ways to run

- **Single container (default) — plug and play.** One container, embedded
  **SQLite** + **local-disk artifacts** under one `/data` volume. No Postgres, no
  MinIO, no Redis. This is what `./setup.sh` starts, and the right choice for
  dropping code-push into an existing app or small/medium fleet. Back up = copy
  one volume.
- **Scale — Postgres + S3/MinIO.** For horizontal scale (multiple stateless
  replicas) or an existing managed database. Selected automatically the moment
  `DATABASE_URL` / `S3_ENDPOINT` are set — which is what `./setup.sh --scale
  --domain <host>` and `docker-compose.prod.yaml` do (**corrected 2026-08-13**:
  this said `./setup.sh --domain`, which starts the single-container stack with
  a TLS overlay and sets neither variable; the Quick-start section above already
  had it right, so this file disagreed with itself). Same features, same wire contract, same code —
  only the storage backends differ. Advanced analytics charts require this mode.

## How it fits together

```
                                              default:  SQLite + files  (/data volume)
Flutter app / CLI ──/api/v1──▶  code_push_server
on-device updater ──/patches──▶  (stateless, Dart)   scale:  Postgres + S3/MinIO
```

The server is **stateless** — all durable state is in the database + artifact
store — so the scale profile runs multiple replicas. Source layout:

```
lib/src/config.dart          env config + backend selection + secret validation
lib/src/db.dart              Db abstraction: SQLite (default) + Postgres adapters
lib/src/domain.dart          lifecycle state-machine guards
lib/src/repository.dart      schema + CRUD + migrations (backend-agnostic)
lib/src/artifact_store.dart  filesystem (default) + S3/MinIO artifact backends
lib/src/oauth.dart           RS256 JWT mint/verify + IdP broker
lib/src/{rollout,signing,content_range}.dart   pure, unit-tested logic
lib/src/api.dart             HTTP surface (wire contract, auth, admin, analytics)
bin/server.dart              entrypoint (validate → migrate → serve → drain)
setup.sh                     one-click setup
docker-compose.yaml          single container (SQLite + files) — the default
docker-compose.prod.yaml + Caddyfile   scale stack (Postgres + S3 + Caddy TLS)
ops/backup.sh, ops/restore.sh          scale-mode backup / restore
tool/smoke_test.sh           end-to-end self-test
```

---

## Configuration reference

`setup.sh` handles this for you; edit `.env` only to customize. All values have
safe local defaults (see `.env.example` for the annotated list). The ones you're
most likely to touch:

- `PUBLIC_BASE_URL` — the URL embedded in download links; **must be reachable
  from your device** (setup.sh uses your LAN IP).
- `API_KEY` — bootstrap key; per-user keys via `POST /admin/users?email=&name=`.
- `IDP_*` — point `shorebird login` at Google/Microsoft ([`../../selfhost/IDP_SETUP.md`](../../selfhost/IDP_SETUP.md)).
- `UPLOAD_METHOD=resumable`, `RATE_LIMIT_BACKEND=postgres` — see `.env.example`.

---

## Deeper documentation

- [`../../selfhost/README.md`](../../selfhost/README.md) — index of all self-host docs
- [`../../selfhost/API_REFERENCE.md`](../../selfhost/API_REFERENCE.md) — every HTTP endpoint (CLI, device, admin/team, analytics, auth, ops)
- [`../../selfhost/ARCHITECTURE.md`](../../selfhost/ARCHITECTURE.md) — internals: data model, state machines, backends, security
- [`../../selfhost/INTEGRATION.md`](../../selfhost/INTEGRATION.md) — dropping this into your own stack (env vars, proxy, own DB/S3)
- [`../../selfhost/IOS_ONDEVICE.md`](../../selfhost/IOS_ONDEVICE.md) — iOS code signing (auto / manual / resign) + the one-command ship flow
- [`PRODUCTION.md`](PRODUCTION.md) — production operational runbook (scale profile)
- [`../../selfhost/GO_LIVE.md`](../../selfhost/GO_LIVE.md) — go-live decisions & sequencing
- [`../../selfhost/OVERVIEW.html`](../../selfhost/OVERVIEW.html) — full system overview
- [`../../selfhost/BEHAVIORAL_FINDINGS.md`](../../selfhost/BEHAVIORAL_FINDINGS.md) — device-verified behavior
- [`../../selfhost/ENGINE_BUILD.md`](../../selfhost/ENGINE_BUILD.md) + [`../../selfhost/engine/`](../../selfhost/engine/) — building the engine from source (advanced)
