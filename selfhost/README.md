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

## ▶ Picking up work

[**`plans/`**](plans) — **one file per piece of work**, each written so a fresh agent can
execute it alone: preconditions with commands, steps with real file:line anchors,
precommitted outcomes, exit criteria, evidence paths, and the commit to make.
[`plans/README.md`](plans/README.md) is the index — it says what taking each piece gets
you, what it holds, and which pieces need no hardware at all.

The split, because it matters: [`PARITY.md`](PARITY.md) is *what* parity means and
*where we stand* — the authority on any status. [`plans/`](plans) is *how to do the next
specific thing*. Read the plan for your piece; open `PARITY.md` when you need the why.

## ▶ What to work on next

[**`ROADMAP.md`**](ROADMAP.md) — **the authority on sequence** (set 2026-08-25):
P0 App Store compliance closure → P1 private-library scope → P2 replacement ABI →
P3 the 50+50 corpus → P4 refusal gates → P5 Android config identity → P6 inherited
workflows, plus what is explicitly parked. `PARITY.md` remains the authority on any
*status*; `ROADMAP.md` says which open thing comes first.

## ▶ What is frozen right now (2026-08-23)

**Patch boot-lifecycle behaviour is in MEASUREMENT MODE and must not be changed** —
no counters, threshold, guard, emission or retry edits until 100 distinct eligible
clients report a first ambiguity. [`MEASUREMENT_MODE.md`](MEASUREMENT_MODE.md) is that
line; read it before touching lifecycle code, on either side of the wire.

## Documents by purpose

**Compliance**
- [`APPSTORE_COMPLIANCE.md`](APPSTORE_COMPLIANCE.md) — **the frozen technical-compliance
  invariant for Route B**: the audited artifact set bound on shipped bytes, the
  execution path anchored end to end, the signed-bundle audit, the whole runtime
  delta this fork adds, the two arms still open, and what forces a re-audit

**Patch lifecycle & safety** *(added to this index 2026-08-23 — these five documents
existed and were reachable only from `PARITY.md` and each other)*
- [`LIFECYCLE_POLICY.md`](LIFECYCLE_POLICY.md) — **the product contract.** Four rows
  (C1-C4) and nothing else. An explicit failure report and a process that merely
  disappeared are not equally strong evidence and must never produce the same action
- [`MEASUREMENT_MODE.md`](MEASUREMENT_MODE.md) — the shipped combination (client
  updater, engine cell, server image, migrations), the five verification steps, and
  **what is not allowed while collecting**
- [`THRESHOLD_ANALYSIS_PRECOMMIT.md`](THRESHOLD_ANALYSIS_PRECOMMIT.md) — the
  ratification criteria, fixed **before** any fleet data exists, so a threshold cannot
  be chosen to fit the numbers
- [`SESSION_SUMMARY_lifecycle.md`](SESSION_SUMMARY_lifecycle.md) — the lane end to
  end: what shipped, the four silent-loss defects and what each biased, the device
  evidence, the harness that replaced human-timed kills, and the mistakes worth keeping
- [`STATE_OF_THE_SYSTEM.md`](STATE_OF_THE_SYSTEM.md) — what has actually been
  achieved, what would mean anything to upstream, and the next steps in execution order

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
- [`backup_restore/`](backup_restore) — **backup and restore, certified on both
  persistence profiles.** What the guarantee is (control-plane data, not machine
  disaster recovery), what is *not* in a backup, and why a backup is a credential
  store. [`SECRETS_BOUNDARY.md`](backup_restore/SECRETS_BOUNDARY.md) is the file to
  read before trusting one
- [`upgrade_rollback/`](upgrade_rollback) — **upgrade and rollback, certified on
  both database backends.** Why "put the old image back" is not recovery from a
  failed upgrade, and why an old server refuses a schema a newer one migrated
- [`release_provenance/`](release_provenance) — **release identity and
  retention.** Why `:1.3.0` does not name the 1.3.0 release, what enforces that
  it cannot happen again, and the `:source-<commit>` reference that keeps a
  backup's recorded image pullable after the aliases move

**Platform coverage**
- [`PARITY.md`](PARITY.md) — **the goal document.** What full Android/iOS parity with upstream means, where we're holding against it, and the queue. Open this to decide what to work on next — then open [`plans/`](plans) for the executable work order for the piece you picked
- [`PLATFORM_MATRIX.md`](PLATFORM_MATRIX.md) — what's verified on which platform
- [`IOS_ONDEVICE.md`](IOS_ONDEVICE.md) — iOS code signing (auto / manual-CI / resign) + one-command ship flow
- [`DESKTOP_PLATFORMS.md`](DESKTOP_PLATFORMS.md) — Windows / Linux notes

**Independence (advanced)**
- [`ROUTE_B.md`](ROUTE_B.md) — **start here to work on iOS Dart code push.** Plan of record: the one call-shape change it reduces to, the five pieces to build, the deliberately tiny first success criterion, file:line pointers, the pre-Step-1 items, and the traps
- [`engine/route_b/`](engine/route_b) — the dedicated Route B build tree: why it cannot share a checkout, and the two scripts that create and build it
- [`UPSTREAM_INDEPENDENCE.md`](UPSTREAM_INDEPENDENCE.md) — every dependency on upstream Shorebird, whether *mirrored* or *built*, and what removing it takes. **All ten are now closed** — item 7, their AOT linker, is *obviated* rather than owned: Route B needs no linker, so nothing on the iOS path calls it (corrected 2026-08-13; this line read "Items 1–6 and 8–10 are closed; 7 is Route B")
- [`CDN_INDEPENDENCE.md`](CDN_INDEPENDENCE.md) + [`cdn/`](cdn) — build-time CDN mirror (default, recommended)
- [`ENGINE_BUILD.md`](ENGINE_BUILD.md) + [`engine/`](engine) — build the engine from captured source (their private Dart VM fork is **no longer a blocker**: we build on vanilla Dart + a 57-line shim, see [`engine/dart-fork/`](engine/dart-fork))
- [`IOS_CODE_PUSH.md`](IOS_CODE_PUSH.md) — iOS code push without their fork: the interpreter and dispatch are already upstream; what we owe is a binder
- [`HANDOFF.md`](HANDOFF.md) — the dated working log: evidence chains and debugging traps. Long, and **not** required reading before starting Route B
- [`BASELINE.md`](BASELINE.md) + [`UPSTREAM_INTEGRATION.md`](UPSTREAM_INTEGRATION.md) — what this fork actually is, and the **measured** cost of catching up to upstream Flutter (5 conflicts across 39 files, `updater_rev` unchanged so the wire contract is safe)
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
| Engine **built from source** | ◐ **Android: proven** (device-verified, on our own vanilla-Dart VM). **iOS: proven** for releases, assets patches **and Dart code patches** — the whole chain is device-verified on our own engine and frontend, without upstream's private AOT linker. What limits iOS code push is now the *language surface* a patch may use, not the mechanism: see [`PARITY.md`](PARITY.md) §3 |

## Capability statement (read this before claiming anything)

> **Android Dart code push, iOS asset push and iOS Dart code push are all
> complete and independent, end to end on physical hardware — `shorebird release
> ios` -> edit a function -> `shorebird patch ios` -> control plane -> updater
> download -> inflate -> hash check -> install -> lifecycle promotion -> native
> pre-main activation -> patched Dart running -> relaunch still patched ->
> rollback to pristine AOT, with no Dart-side cooperation, nothing packed by
> hand, and no upstream private AOT linker. +4.4 % size, +0.3 % median frame
> time, zero added jank. What is NOT complete is the LANGUAGE SURFACE a patch may
> use: about 7 % of real instance methods are addressable, bounded by
> library-scoped privacy and a one-parameter ABI.**

*The mechanism is proven; the reach is narrow.* Both are true at once and they are
different claims. Do not let "iOS code push works" become "any iOS patch works" —
that substitution is the one this document exists to prevent, and it replaces an
earlier version of the same warning about the producer, which is now built.

What has run on a physical iPhone, end to end (2026-08-10, release 9.0.0+1):
fresh release reads OLD, the control plane serves a patch, the real updater
downloads and inflates and hash-checks and installs it, the lifecycle promotes
it, the engine activates it natively before `main`, the first Dart read returns
NEW, a relaunch is still NEW from persisted state, and a rollback returns the
app to pristine AOT. The app contains no attach path of its own — the fixture
cannot patch itself.

The producer now exists and is device-proven (2026-08-11): `shorebird release
ios` -> edit -> `shorebird patch ios` -> OLD -> NEW -> relaunch NEW -> rollback
-> pristine OLD, nothing manual in between.

> Current proven producer surface: a single-function replacement whose **every
> reference resolves inside the release's declared retention** — literals, its own
> receiver's public members, a **read** of a release-private instance field
> granted through G3.6b/P2, `dart:core`, and another public top-level app
> function.

[`ROUTE_B.md`](ROUTE_B.md) and [`PARITY.md`](PARITY.md) §3 are authoritative for
that boundary; this is a summary, not a third definition of it. What the closure
rule excludes and what the producer refuses by design are listed there.

Device-proven spellings, each through the ordinary `shorebird patch ios` path:
`label`, `this.label`, `helper()`, `this.<method>(args)`, `tagged('ARG')`,
`slot = 'NEW'`, and `_secret` (release `31.0.0+1` patch 2, 2026-08-13, lowered to
`self._secret`). A private **read** is proven; a private **write** is not.

**Read the size of that limit before planning around it.** Measured from kernel
over `package:flutter/src`: about **7 %** of concrete instance methods are
addressable today, and the two things bounding it are library-scoped privacy and
the one-positional-parameter ABI — roughly equal in weight, neither reachable by
widening spellings. **That 7 % predates the 2026-08-13 private-read result and has
not been re-measured**: the privacy half of the bound has partly moved, and
`PARITY.md`'s bookkeeping rule forbids restating the figure across the analyzer
v6→v7 boundary, so no new number is claimed here — a fresh run would have to be
reported as its own. [`PARITY.md`](PARITY.md) §3 has the numbers, the reproducible
measurement, and what each fix would buy; [`ROUTE_B.md`](ROUTE_B.md) has the
mechanism.

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
| iOS **Dart code patch** delivered + activated + rolled back on device | **PASS** — first on 2026-08-10 with a hand-packed container; superseded by the producer-generated passes below |
| iOS Dart code patch **produced by `shorebird patch`** | **PASS** — 2026-08-11, releases 19–22, six device gates. See [`PARITY.md`](PARITY.md) §3 for which source spellings are covered |
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

~~What remains before iOS Dart **code** patches work.~~ **ALL SEVEN STEPS ARE
CLOSED — corrected 2026-08-13.** This outline stayed frozen at its 2026-08-09
state while the capability statement above it moved, so a reader who scrolled
this far was told the opposite of what the front of this file says. It is kept
rather than deleted because that is the failure mode worth seeing. The plan of
record, which was maintained, is [`ROUTE_B.md`](ROUTE_B.md).

1. ~~Patchable call-emission mode on arm64.~~ **Works on the host harness,
   2026-08-09** — `--patchable_static_calls`. Covers static calls, static
   methods, monomorphic instance calls, getters and dynamic instance calls;
   **dispatch-table calls are not reachable** and are a much larger change.
2. ~~Retain and bind app + SDK symbols.~~ **Works, 2026-08-09** — generated
   dynamic interface, whole-library for the app and named members for the SDK.
   The asymmetry is not stylistic: whole-library `dart:core` costs **+310 %**
   snapshot against **+0.9 %** for the app.
3. ~~Stable target identity — which function in the installed release a given
   bytecode belongs to. Not started.~~ **DONE 2026-08-09** —
   [`ROUTE_B.md`](ROUTE_B.md) *"3. ~~Stable target identities — the binder~~"*.
   Targets are named by **selector**, never by index.
4. ~~Package the payload with an explicit versioned type/header — NOT the
   provisional `*.vmcode` filename trick. Not started.~~ **DONE 2026-08-09.**
   The `*.vmcode` trick never became the contract: the shipped container is
   `SBRBPTCH` + a `uint32` format version + a JSON header
   (`../packages/shorebird_cli/lib/src/route_b_container.dart`).
5. ~~Make `shorebird patch` produce it, and integrate with the updater/runtime
   lifecycle. Not started.~~ **DONE 2026-08-09 (host), wired into the real
   command 2026-08-10** — `route_b_producer.dart`, called from
   `commands/patch/ios_patcher.dart`.
6. ~~Pass the physical-device gate… **Nothing has run on iOS.**~~ **PASSED
   2026-08-10** on release `9.0.0+1`, and producer-generated since `19.0.0+1`.
   See [`PARITY.md`](PARITY.md) §2, which carries twelve PROVEN rows including
   rollback to pristine AOT. This sentence was false from 2026-08-10 onward and
   is the single most misleading line this file has carried.
7. ~~Measure the two vetoes… Either can still kill this.~~ **BOTH CLOSED
   2026-08-10** — **+4.5 %** size and **+0.3 %** median frame time with zero
   added jank, measured on the real fixture on device. Neither killed it.

~~Steps 1 and 2 are measured on a toy program on a macOS host. The combined
snapshot cost there is **+4.64 %**, which is a dial-reading and not the veto.~~
Superseded: the toy-program dial-reading was replaced by the on-device
measurement in step 7.

**What actually remains on iOS is the language surface**, not any step above —
see the capability statement at the top of this file and
[`PARITY.md`](PARITY.md) §3.

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
| Building a **modified** engine, iOS | ✅ proven for releases, assets patches **and Dart code patches** — device-verified, no private AOT linker. Route B's remaining work is the patchable language surface, not the engine |
| Surviving Shorebird disappearing | ⚠️ partial — we hold the engine C++ and updater, not the VM fork to compile them |

Whether to ask for access or rebuild that capability ourselves is scoped in
[`FORK_REBUILD.md`](FORK_REBUILD.md). Full evidence, the measured size of their
changes, and what it would cost to build our own VM:
[`ENGINE_BUILD.md`](ENGINE_BUILD.md). Which improvements are reachable
anyway, and how much Android work carries to iOS:
[`EXPERIMENTAL_ENGINE.md`](EXPERIMENTAL_ENGINE.md).
