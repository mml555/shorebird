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
- [`UPSTREAM_INDEPENDENCE.md`](UPSTREAM_INDEPENDENCE.md) — **start here**: every remaining dependency on upstream Shorebird, whether it is *mirrored* or *built*, and what removing it takes
- [`CDN_INDEPENDENCE.md`](CDN_INDEPENDENCE.md) + [`cdn/`](cdn) — build-time CDN mirror (default, recommended)
- [`ENGINE_BUILD.md`](ENGINE_BUILD.md) + [`engine/`](engine) — build the engine from captured source (their private Dart VM fork is **no longer a blocker**: we build on vanilla Dart + a 57-line shim, see [`engine/dart-fork/`](engine/dart-fork))
- [`IOS_CODE_PUSH.md`](IOS_CODE_PUSH.md) — iOS code push without their fork: the interpreter and dispatch are already upstream; what we owe is a binder
- [`HANDOFF.md`](HANDOFF.md) — current state of the three work tracks, next steps, and gotchas
- [`ENGINE_IMPROVEMENTS.md`](ENGINE_IMPROVEMENTS.md) — **start here for engine work**: what is proven, what stays pinned, and the constraints that cost real debugging
- [`EXPERIMENTAL_ENGINE.md`](EXPERIMENTAL_ENGINE.md) — engine/runtime improvement roadmap: what's reachable today, and Android → iOS carryover
- [`../vendor/flutter`](../vendor) + [`../vendor/updater`](../vendor) — captured source (insurance vs. upstream going closed)
- [`../packages/code_push_runtime`](../packages/code_push_runtime) — app-side runtime: patched assets + patch-scoped crash reporting
- [`FORK_REBUILD.md`](FORK_REBUILD.md) — rebuilding the fork's iOS capability vs. asking for access
- [`cdn/tls/`](cdn/tls) — HTTPS for the mirror, required by Gradle 8+

## The short version of "how independent is it?"

| Layer | Status |
|---|---|
| Control plane (backend) | ✅ ours — this server |
| Runtime (device → our server) | ✅ proven, no `api.shorebird.dev` |
| Build-time (engine via CDN mirror) | ✅ proven for pinned revisions |
| Engine/updater **source** | ✅ captured in `vendor/` (insurance) |
| Engine **built from source** | ◐ **Android: proven** (device-verified, on our own vanilla-Dart VM). **iOS: proven for releases + assets patches** (device-verified 2026-08-05, own engine + own frontend); **iOS *Dart code* patches: NOT BUILT** — architecture selected and de-risked, production integration not started (see below) |

## Capability statement (read this before claiming anything)

> **Android Dart code push and iOS asset push are complete and independent.
> iOS Dart code push has a selected, de-risked architecture, but the
> production compiler/runtime integration has not been built yet.**

What works on iOS today, end to end and artifact-independent: a release built
with our own engine and compiler, the app reaching first frame, and an
assets-only patch published, downloaded, applied and rolled back on a
physical device.

What remains before iOS Dart **code** patches work — none of it started:

1. Implement Route B's patchable call-emission mode on arm64.
2. Retain and bind app + SDK symbols via the dynamic-interface mechanism
   Spike B proved.
3. Package the bytecode payload with an explicit **versioned type/header** —
   NOT the provisional `*.vmcode` filename trick, which is bring-up scaffolding
   and must not become the contract.
4. Integrate with the updater/runtime lifecycle.
5. Pass the physical-device gate: release, Dart behavior actually changes
   after the patch, sane patch-coverage (link-percentage equivalent), rollback.
6. Measure the two vetoes: release size and frame-time impact, and whether
   hot-path patches must stay native.

The spikes proved the *mechanism* in a harness. They did not produce a
shippable path.

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

**iOS is no longer blocked the way this section used to claim.** Superseded
findings (2026-08-04/05): our own iOS engine builds against vanilla Dart plus
the `engine/000x` patches, runs releases to first frame, and applies
assets-only patches on a physical iPhone — device-verified, see
[`HANDOFF.md`](HANDOFF.md) and [`TFA_ROOT_CAUSE.md`](TFA_ROOT_CAUSE.md). What
remains gated is iOS **code** patches, and "reimplementing was considered and
rejected" is stale: two routes were spiked 2026-08-05 — Track E's binding crux
**passed** ([`engine/killgate/README.md`](engine/killgate/README.md)) and the
AOT-linker route's object-pool crux is measuring strongly positive
([`engine/spike/README.md`](engine/spike/README.md)). **Route B was selected**
on that evidence — but selected is not built: the compiler, runtime,
packaging and updater work listed in the capability statement above is all
still ahead. `pkg/aot_tools` itself remains private-fork-only and can only
ever be rewritten, never fetched.

What that does and does not affect:

| | |
|---|---|
| Runtime code push, device → this server | ✅ unaffected |
| Building releases/patches on the current pin | ✅ unaffected (mirror is warm) |
| Adopting a newer Flutter version | ✅ needs their published *prebuilts*, not source |
| Building a **modified** engine, Android | ✅ proven — vanilla Dart + ~57 lines, device-verified |
| Building a **modified** engine, iOS | ◐ proven for releases + assets patches; **Dart code** patches NOT BUILT (Route B selected, integration not started) |
| Surviving Shorebird disappearing | ⚠️ partial — we hold the engine C++ and updater, not the VM fork to compile them |

Whether to ask for access or rebuild that capability ourselves is scoped in
[`FORK_REBUILD.md`](FORK_REBUILD.md). Full evidence, the measured size of their
changes, and what it would cost to build our own VM:
[`ENGINE_BUILD.md`](ENGINE_BUILD.md). Which improvements are reachable
anyway, and how much Android work carries to iOS:
[`EXPERIMENTAL_ENGINE.md`](EXPERIMENTAL_ENGINE.md).
