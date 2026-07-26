# Self-hosted Shorebird — documentation index

A compatible control plane that the unmodified, pinned Shorebird CLI and native
updater talk to, so Flutter code-push runs entirely on your own infrastructure —
no `api.shorebird.dev` at runtime or build time, no per-app pricing.

## ▶ Start here

The server and its one-click setup live in
[`../packages/code_push_server`](../packages/code_push_server):

```bash
cd packages/code_push_server
./setup.sh              # local: generates secrets, starts everything, prints next steps
./setup.sh --domain cps.you.com --email you@you.com   # production (HTTPS via Caddy)
```

See [`../packages/code_push_server/README.md`](../packages/code_push_server/README.md)
for the quick start and feature list.

## Documents by purpose

**Understand the system**
- [`OVERVIEW.html`](OVERVIEW.html) — full system overview (rendered page)
- [`API_REFERENCE.md`](API_REFERENCE.md) — every HTTP endpoint (CLI, device, admin/team, analytics, auth, ops)
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — internals: data model, state machines, backends, request lifecycle, security
- [`compatibility.yaml`](compatibility.yaml) — the pinned CLI/engine/updater revisions this supports
- [`UPDATER_CONTRACT.md`](UPDATER_CONTRACT.md) — the device ↔ server wire contract
- [`BEHAVIORAL_FINDINGS.md`](BEHAVIORAL_FINDINGS.md) — device-verified behavior (events, rollback, ranges…)

**Deploy & operate**
- [`INTEGRATION.md`](INTEGRATION.md) — drop into your own stack: env-var contract, reverse proxy, your own Postgres/S3, backups
- [`../packages/code_push_server/PRODUCTION.md`](../packages/code_push_server/PRODUCTION.md) — scale-profile operational runbook (Postgres + S3 + Caddy)
- [`GO_LIVE.md`](GO_LIVE.md) — deployment-shape decisions & the app-cutover sequence
- [`IDP_SETUP.md`](IDP_SETUP.md) — real Google / Microsoft login for `shorebird login`

**Platform coverage**
- [`PLATFORM_MATRIX.md`](PLATFORM_MATRIX.md) — what's verified on which platform
- [`IOS_ONDEVICE.md`](IOS_ONDEVICE.md) — iOS on-device (signing / resign flow)
- [`DESKTOP_PLATFORMS.md`](DESKTOP_PLATFORMS.md) — Windows / Linux notes

**Independence (advanced)**
- [`CDN_INDEPENDENCE.md`](CDN_INDEPENDENCE.md) + [`cdn/`](cdn) — build-time CDN mirror (default, recommended)
- [`ENGINE_BUILD.md`](ENGINE_BUILD.md) + [`engine/`](engine) — build the engine from captured source
- [`../vendor/flutter`](../vendor) + [`../vendor/updater`](../vendor) — captured source (insurance vs. upstream going closed)

## The short version of "how independent is it?"

| Layer | Status |
|---|---|
| Control plane (backend) | ✅ ours — this server |
| Runtime (device → our server) | ✅ proven, no `api.shorebird.dev` |
| Build-time (engine via CDN mirror) | ✅ proven for pinned revisions |
| Engine/updater **source** | ✅ captured in `vendor/` (insurance) |
| Engine **built from source** | ⚙️ turn-key scripts (`engine/`), needs a build farm |

For almost everyone, the one-click setup + the CDN mirror is the finish line.
Building the engine yourself is insurance you only cash in if Shorebird goes
closed or you need a Flutter version they haven't shipped.
