<!-- cspell:words prebuilts jank -->
<!-- cspell:words SBRBPTCH -->

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
- [`ROUTE_B.md`](ROUTE_B.md) — **start here to work on iOS Dart code push.** Plan of record: the one call-shape change it reduces to, the five pieces to build, the deliberately tiny first success criterion, file:line pointers, the pre-Step-1 items, and the traps
- [`engine/route_b/`](engine/route_b) — the dedicated Route B build tree: why it cannot share a checkout, and the two scripts that create and build it
- [`UPSTREAM_INDEPENDENCE.md`](UPSTREAM_INDEPENDENCE.md) — every dependency on upstream Shorebird, whether *mirrored* or *built*, and what removing it takes. Items 1–6 and 8–10 are closed; 7 is Route B
- [`CDN_INDEPENDENCE.md`](CDN_INDEPENDENCE.md) + [`cdn/`](cdn) — build-time CDN mirror (default, recommended)
- [`ENGINE_BUILD.md`](ENGINE_BUILD.md) + [`engine/`](engine) — build the engine from captured source (their private Dart VM fork is **no longer a blocker**: we build on vanilla Dart + a 57-line shim, see [`engine/dart-fork/`](engine/dart-fork))
- [`IOS_CODE_PUSH.md`](IOS_CODE_PUSH.md) — iOS code push without their fork: the interpreter and dispatch are already upstream; what we owe is a binder
- [`HANDOFF.md`](HANDOFF.md) — the dated working log: evidence chains and debugging traps. Long, and **not** required reading before starting Route B
- [`MEDIA_PRESERVATION.md`](MEDIA_PRESERVATION.md) — the build-SSD preservation runbook: what is proven about the media and what is not, the order of operations and why decode does not gate the copy, and the standing rules after two mid-write detaches
- [`fixtures/airgap_app/README.md`](fixtures/airgap_app/README.md) + [`fixtures/CONTROL_PLANE_DATA.md`](fixtures/CONTROL_PLANE_DATA.md) — the acceptance fixture, and where rig data / config / secrets live
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
| Engine **built from source** | ◐ **Android: proven** (device-verified, on our own vanilla-Dart VM). **iOS: proven for releases + assets patches** (device-verified 2026-08-05, own engine + own frontend); **iOS *Dart code* patches: NOT SHIPPABLE** — the compiler and retention layers work on a macOS host harness, nothing has run on iOS (see below) |

## Capability statement (read this before claiming anything)

> **Android Dart code push and iOS asset push are complete and independent. The
> entire iOS Dart code-push RUNTIME is proven on physical hardware — control
> plane -> updater download -> inflate -> hash check -> install -> lifecycle
> promotion -> native pre-main activation -> patched Dart running -> relaunch
> still patched -> rollback to pristine AOT, with no Dart-side cooperation, at
> +4.5 % size and +0.3 % median frame time with zero added jank. What is NOT
> built is the PRODUCER: `shorebird patch` cannot emit an iOS code patch, so the
> container that proved all of the above was packed by hand.**

*The runtime is proven; the producer is not.* Both are true at once and they are
different claims. Do not let "iOS code push works on the device" become "iOS
code push works".

What has run on a physical iPhone, end to end (2026-08-10, release 9.0.0+1):
fresh release reads OLD, the control plane serves a patch, the real updater
downloads and inflates and hash-checks and installs it, the lifecycle promotes
it, the engine activates it natively before `main`, the first Dart read returns
NEW, a relaunch is still NEW from persisted state, and a rollback returns the
app to pristine AOT. The app contains no attach path of its own — the fixture
cannot patch itself.

What is missing is the producer: `shorebird patch` cannot emit an iOS code
patch, because `ios_patcher.dart:198` gates code patches on Shorebird's private
AOT linker. The container that proved everything above was **packed by hand**.
Everything downstream of those bytes is proven; nothing upstream of them is.

Also true on iOS today, artifact-independent: a release built with our own
engine and compiler, the app reaching first frame on a physical device, and an
assets-only patch published, downloaded, applied and rolled back.

**Status split, so different claims stay separate** (updated 2026-08-10):

| claim | status |
|---|---|
| iOS artifact independence | **PASS** |
| iOS release → first frame on device | **PASS** |
| iOS device → control-plane reach | **PASS** — 2026-08-09, once Local Network was granted |
| iOS assets-patch application on device | **NOT VERIFIED** on the current fixture |
| iOS **Dart code patch** delivered + activated + rolled back on device | **PASS** — 2026-08-10, container packed by hand |
| iOS Dart code patch **produced by `shorebird patch`** | **NOT BUILT** |
| Android full device lifecycle (release → Dart code patch → rollback) | **PASS** |

Android must not be read as covering the iOS device claim. The assets-only
round trip *was* device-verified on 2026-08-05 against an app that no longer
exists, and the durable fixture that replaced it still has not been shown to
APPLY a patch on device — that row stays NOT VERIFIED.

**The device→control-plane gap closed on 2026-08-09.** Granting Local Network
to *Airgap Probe* was the whole fix. The fixture, launched over LAN at
`http://10.0.0.7:18080`, produced `POST /api/v1/patches/check -> 200` and
`POST /patches/check -> 200` from the native updater. Note the Dart beacon's
`GET /selfhost-beacon/state` returns **403** — it reaches the server, so it is
not a connectivity problem, but that diagnostic endpoint is not usable as-is.
See [`UPSTREAM_INDEPENDENCE.md`](UPSTREAM_INDEPENDENCE.md).

What remains before iOS Dart **code** patches work. The plan of record, with
file:line pointers and the rig, is [`ROUTE_B.md`](ROUTE_B.md); in outline:

1. ~~Patchable call-emission mode on arm64.~~ **Works on the host harness,
   2026-08-09** — `--patchable_static_calls`. Covers static calls, static
   methods, monomorphic instance calls, getters and dynamic instance calls;
   **dispatch-table calls are not reachable** and are a much larger change.
2. ~~Retain and bind app + SDK symbols.~~ **Works, 2026-08-09** — generated
   dynamic interface, whole-library for the app and named members for the SDK.
   The asymmetry is not stylistic: whole-library `dart:core` costs **+310 %**
   snapshot against **+0.9 %** for the app.
3. **Stable target identity** — which function in the installed release a given
   bytecode belongs to. Not started.
4. Package the payload with an explicit **versioned type/header** — NOT the
   provisional `*.vmcode` filename trick, which is bring-up scaffolding and
   must not become the contract. Not started.
5. Make `shorebird patch` produce it, and integrate with the updater/runtime
   lifecycle. Not started.
6. Pass the physical-device gate: release, Dart behavior actually changes after
   the patch, sane patch coverage, rollback. **Nothing has run on iOS.**
7. Measure the two vetoes: release size and frame-time impact on a real app,
   and whether hot-path patches must stay native. Either can still kill this.

Steps 1 and 2 are measured on a toy program on a macOS host. The combined
snapshot cost there is **+4.64 %**, which is a dial-reading and not the veto.

**Infrastructure and artifact independence are closed** as of 2026-08-07 —
artifact ownership audited per cell, the acceptance fixture and its pub seed
durable and committed, control-plane data/config/secrets moved out of session
scratchpads, and endpoint configuration derived at run time rather than pinned.

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
on that evidence. Since 2026-08-09 the compiler and retention layers are built
and working on a macOS host harness (`selfhost/engine/route_b/`); target
identity, packaging, the CLI and the iOS port are all still ahead, and both
vetoes are unmeasured. `pkg/aot_tools` itself remains private-fork-only and can
only ever be rewritten, never fetched.

What that does and does not affect:

| | |
|---|---|
| Runtime code push, device → this server | ✅ unaffected |
| Building releases/patches on the current pin | ✅ unaffected (mirror is warm) |
| Adopting a newer Flutter version | ✅ needs their published *prebuilts*, not source |
| Building a **modified** engine, Android | ✅ proven — vanilla Dart + ~57 lines, device-verified |
| Building a **modified** engine, iOS | ◐ proven for releases + assets patches; **Dart code** patches NOT SHIPPABLE — Route B steps 1–2 work on a host harness, steps 3–5 and the iOS port are not started |
| Surviving Shorebird disappearing | ⚠️ partial — we hold the engine C++ and updater, not the VM fork to compile them |

Whether to ask for access or rebuild that capability ourselves is scoped in
[`FORK_REBUILD.md`](FORK_REBUILD.md). Full evidence, the measured size of their
changes, and what it would cost to build our own VM:
[`ENGINE_BUILD.md`](ENGINE_BUILD.md). Which improvements are reachable
anyway, and how much Android work carries to iOS:
[`EXPERIMENTAL_ENGINE.md`](EXPERIMENTAL_ENGINE.md).
