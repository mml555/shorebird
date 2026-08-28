# First-activation disappearance — observation harness

**Phase 1 + 2 deliverable. This is an instrument, not a fix.** It answers one
question — *what terminates the process after the first activation of a newly
installed patch?* — and is explicitly forbidden from answering *how do we fix
it?* while Epoch B is collecting.

## Why a fix is out of scope, in code rather than in prose

`af6e842ccf87` moved *when a boot becomes attributable*, which is why the policy
sample restarted as Epoch B (`../MEASUREMENT_MODE.md`). A "fix" that moved that
boundary again would close Epoch B and open Epoch C. So the surfaces below are
frozen, and `verify_frozen_surfaces.sh` enforces it by **bytes**:

    boot-start timing · launch-success timing · the ambiguity definition
    boot_attempt_count · the retry threshold · retirement behaviour
    UpdaterState lifecycle transitions · engine patch selection
    the Epoch B policy surface · the certified cell

13 files across the shipping updater (the engine tree's `third_party/updater`,
**not** `vendor/updater` — different trees, see `../UPDATER_CONTRACT.md`), the
engine C++ boot path, the vendored mirror, and the policy surface.

### The runtime is verified by BYTES, not by its stamp

The first version of this guard ended by reading `bin/internal/engine.version`
and declaring *"active cell is the certified one"*. That proved only what the
stamp **says** — reintroducing, inside the evidence harness, the exact failure
this project had already measured and fixed elsewhere:

    engine.version / engine.stamp / engine-dart-sdk.stamp   4792f0ec
    cached ios-release engine                               ca7d2c0d's, a week old
    verdict                                                 COHERENT

It now reuses `../scripts/verify_toolchain_coherence.sh`, whose check 3b extracts
each iOS mode's engine from that cell's own published `artifacts.zip` and compares
byte for byte — one implementation rather than a second, weaker one. With one
deliberate difference: that script is a diagnostic and may report a not-yet-cached
engine as fine, whereas an evidence gate must **refuse**, because at capture time
an absent engine means identity was never established.

| mutation | result |
|---|---|
| stamps say `4792f0ec`, cached engines are `ca7d2c0d`'s bytes | **REFUSE** — all three modes named with digests |
| only `ios-profile` stale | **REFUSE** — names that mode alone |
| published reference absent | **UNKNOWN → REFUSE** |
| cached engine absent | **UNKNOWN → REFUSE** (not "not cached yet") |
| `4792f0ec` stamps + `4792f0ec` bytes | **VERIFIED** |

Every run's `frozen_surfaces.txt` records the per-mode digests, so a run's
evidence carries the identity rather than a bare "it passed". The base release's
own identity is banked once in `BASE_RELEASE_IDENTITY.md`.

Mutation-tested three ways, because a guard that cannot fail is worse than none:

| mutation | result |
|---|---|
| a bare comment appended to the shipping `lifecycle.rs` | **MOVED** |
| a frozen file hidden | **UNKNOWN** — absent is never a pass |
| the active cell reverted to `ca7d2c0d` | **MOVED** |

## `first_activation_run.sh` — one run, one immutable folder

    arm      <run-id>   verify frozen surfaces, snapshot PRE state + crash
                        reports, start capture
    collect  <run-id>   screenshot while alive, grade syslog, pull everything
    delayed  <run-id>   the second crash-report pull, later

`arm` refuses if anything frozen moved. It kills only **its own** capture, matched
by output path — a blanket `pkill` is how the previous capture died.

### Syslog is a source, not the truth

Both failure modes have already been paid for here: a Route B line was **dropped**
under load and nearly read as a failed activation, and the capture reader was
**accidentally killed** and stalled silently, so a launch that definitely happened
left no syslog record. A stalled capture is indistinguishable from "nothing
happened", so health is measured and graded:

    USABLE     reader alive, lines growing, app lines present
    PARTIAL    app lines present but the reader died
    UNUSABLE   no app lines -- this run's syslog proves NOTHING

Demonstrated live: re-running `collect` after the reader was gone reported
`PARTIAL` rather than passing.

### Crash reports are reported as NEW-SINCE-ARM

The device retains old reports. A raw listing showed three unrelated `Runner`
reports — from an instrumentation bug of ours — under a run they had nothing to do
with. Now `pre` and `immediate` are diffed and only the delta is called out.

## The fixture: `../fixtures/first_activation_probe`

A **separate app** (`235a9d93-…`), deliberately not the Epoch B specimen, so
collection cannot be contaminated. Release 1.3.0+1 on the certified cell.

Durable append-and-flush timeline at `Documents/first_activation_timeline.log`,
two halves in one file:

* **Dart** — `PROCESS_BEGIN`, `DART_MAIN_ENTERED`, `INIT_STATE`, `FIRST_FRAME`,
  `APP_LIFECYCLE`, `MEMORY_PRESSURE`, `FLUTTER_ERROR`, `ZONE_ERROR`, and
  post-frame heartbeats at 0/100/250/500 ms, 1/2/5 s;
* **native** — `UIAPP_DID_FINISH_LAUNCHING`, `DID_BECOME_ACTIVE`,
  `WILL_RESIGN_ACTIVE`, `DID_ENTER_BACKGROUND`, `WILL_ENTER_FOREGROUND`,
  **`WILL_TERMINATE`**, `MEMORY_WARNING`, `FLUTTER_ENGINE_INITIALIZED`.

`WILL_TERMINATE` is the discriminator, and it is validated: a force-quit produces
`detached` **then** `UIAPP_WILL_TERMINATE`. Its **absence** before a
disappearance therefore separates a kill from an orderly stop — bucket F/G versus
H — from the durable file alone, without depending on syslog.

Success is **observed, not relocated**. The updater already writes
`success_diag.log` with the pid; the harness correlates by pid rather than this
fixture duplicating or moving the success boundary.

## run_001 — established-patch control, CLEAN

    syslog health   USABLE (reader alive, 1888 lines, 808 app lines)
    pid 50220       DART_MAIN_ENTERED ACT-V2 -> FIRST_FRAME +37ms
                    heartbeats +0 +100 +250 +500 +1000 +2000 +5000ms  ALL present
                    APP_LIFECYCLE resumed; no MEMORY_PRESSURE, no detached,
                    no WILL_TERMINATE -- still alive at collect
    success_diag    pid=50220 patch=1
    rbtrace         2 records, latest rc=0
    crash reports   NEW since arm: 0
    frozen surfaces INTACT

## One incidental population-A observation

Reaching an established patch requires a first activation, so one was observed —
**pid 50172**, `ACT-V2` from `DART_MAIN_ENTERED` onward, all seven heartbeats,
`success_diag patch=1`, no disappearance. Against the historical 3-for-3 that is
**0 for 1**: not evidence the phenomenon is gone, but evidence it is not
deterministic. It was captured before the harness was armed, so it is recorded as
an observation rather than as run_000.

## Three instrumentation bugs found BEFORE any reproduction run

Each would have contaminated results in the same direction — making a healthy
runtime look broken.

1. **`UInt64` underflow → `SIGTRAP`.** Swift evaluates `DispatchTime.now()`
   before initialising a lazy `static let`, so the base was the *later* instant
   and the subtraction underflowed. Crashed the app on first launch inside
   `didFinishLaunchingWithOptions`. An instrument that can trap manufactures the
   failure class under investigation.
2. **The Dart half silently wrote nothing.** The path came from
   `Platform.environment['HOME']`, which a Flutter iOS app does not populate, and
   a `catch (_) {}` hid it. The timeline read as *"Dart never ran"* when Dart had
   run perfectly. Now derived from `Directory.systemTemp.parent`, cross-checked
   against the native half's independent resolution, with failures loud in three
   places: a field, a `TIMELINE_FAULT` print to syslog, and a red on-screen
   banner.
3. **The wrong binary got installed.** `patch ios` rebuilds into the same archive
   path, so a failed patch left `ACT-V2` where the release was `ACT-V1`.
   Verifying the marker *before* installing is now part of the procedure.

## Also learned, and it sharpens the original finding

**Crash reports demonstrably work for this bundle on this device.** Bug 1 produced
three `Runner-*.ips` files, retrieved immediately and correctly attributed. So the
disappearance's absence of reports across four pulls cannot reasonably be
dismissed as "crash reporting doesn't work on this rig."

**Stated no more strongly than that.** It shifts evidence AWAY from **E** (an
ordinary, report-producing native crash). It does **not** yet favour F or G over
H: there is no positive jetsam, watchdog or system-termination evidence from any
reproduced disappearance. The historical occurrence remains:

    H -- post-success disappearance, OS reason unclassified

`WILL_TERMINATE` will separate an orderly application termination from a kill, but
its absence alone does not say whether the kernel, SpringBoard, a watchdog, jetsam
or something else did the killing. Turning H into F or G needs a captured
occurrence.

## Hard stop

Any occurrence showing wrong patch attribution, `currently_booting_patch` left
set, `Bad{BootCrash}`, a consumed retry, a deleted last-known-good, or failure
before Route B completes or before launch success — **stop**. That is materially
different from the three historical disappearances and may indicate a real
certified-runtime defect.
