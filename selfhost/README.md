<!-- cspell:words prebuilts -->

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
- [`IOS_ONDEVICE.md`](IOS_ONDEVICE.md) — iOS code signing (auto / manual-CI / resign) + one-command ship flow
- [`DESKTOP_PLATFORMS.md`](DESKTOP_PLATFORMS.md) — Windows / Linux notes

**Independence (advanced)**
- [`CDN_INDEPENDENCE.md`](CDN_INDEPENDENCE.md) + [`cdn/`](cdn) — build-time CDN mirror (default, recommended)
- [`ENGINE_BUILD.md`](ENGINE_BUILD.md) + [`engine/`](engine) — build the engine from captured source (⛔ blocked: private Dart VM fork — see below)
- [`HANDOFF.md`](HANDOFF.md) — current state of the three work tracks, next steps, and gotchas
- [`ENGINE_IMPROVEMENTS.md`](ENGINE_IMPROVEMENTS.md) — **start here for engine work**: what is proven, what stays pinned, and the constraints that cost real debugging
- [`EXPERIMENTAL_ENGINE.md`](EXPERIMENTAL_ENGINE.md) — engine/runtime improvement roadmap: what's reachable today, and Android → iOS carryover
- [`../vendor/flutter`](../vendor) + [`../vendor/updater`](../vendor) — captured source (insurance vs. upstream going closed)

## The short version of "how independent is it?"

| Layer | Status |
|---|---|
| Control plane (backend) | ✅ ours — this server |
| Runtime (device → our server) | ✅ proven, no `api.shorebird.dev` |
| Build-time (engine via CDN mirror) | ✅ proven for pinned revisions |
| Engine/updater **source** | ✅ captured in `vendor/` (insurance) |
| Engine **built from source** | ◐ **Android: proven** (device-verified, on our own vanilla-Dart VM). **iOS: blocked** — needs Shorebird's private fork |

For almost everyone, the one-click setup + the CDN mirror is the finish line.

### What is blocked, and what turned out not to be (read this before planning engine work)

`DEPS` pins the Dart VM source to `git@github.com:shorebirdtech/dart-sdk.git`,
which is **private** — 404 anonymously and to an authenticated account, and
Shorebird's own docs say it is "private currently". Their *engine* and *framework*
forks are public and captured in `vendor/flutter`; the Dart VM is not, and the
engine will not compile against vanilla Dart as-is (its hooks call two Dart APIs
vanilla does not define).

**That stopped being a blocker for Android.** Their fork exists to *interpret*
patched code, which is the iOS mechanism — Android patches carry real machine
code. So the dependency came to ~57 lines: vanilla Dart 3.12.2 plus two
snapshot-size accessors and one public getter, reproducible from the patch in
[`engine/dart-fork/`](engine/dart-fork). An engine built entirely from that ran
release → patch → boot → rollback on a physical Android arm64 device.

**iOS remains genuinely blocked**, and by a different artifact: `pkg/aot_tools`,
the host-side AOT linker, also lives in the private fork. iOS forbids JIT, so a
patch there is `.vmcode` produced by that linker and run by the interpreter —
there is no way around it short of fork access, and reimplementing it was
considered and rejected. See [`EXPERIMENTAL_ENGINE.md`](EXPERIMENTAL_ENGINE.md).

What that does and does not affect:

| | |
|---|---|
| Runtime code push, device → this server | ✅ unaffected |
| Building releases/patches on the current pin | ✅ unaffected (mirror is warm) |
| Adopting a newer Flutter version | ✅ needs their published *prebuilts*, not source |
| Building a **modified** engine, Android | ✅ proven — vanilla Dart + ~57 lines, device-verified |
| Building a **modified** engine, iOS | ⛔ blocked — needs `pkg/aot_tools` from the private fork |
| Surviving Shorebird disappearing | ⚠️ partial — we hold the engine C++ and updater, not the VM fork to compile them |

Full evidence, the measured size of their changes, and what it would cost to build
our own VM: [`ENGINE_BUILD.md`](ENGINE_BUILD.md). Which improvements are reachable
anyway, and how much Android work carries to iOS:
[`EXPERIMENTAL_ENGINE.md`](EXPERIMENTAL_ENGINE.md).
