# State of the system — practical, 2026-08-18; lifecycle lane folded in 2026-08-23

What we have actually achieved, how it compares to upstream Shorebird, and which
parts would mean anything to them. Uses `PARITY.md`'s status vocabulary.

> **What changed since the 2026-08-18 body below was written.** The lifecycle lane
> closed. §5's *"Next steps"* item 1 — *"finish tombstone/retry scoring, one
> precommitted manual action outstanding"* — is **DONE**, so the next actionable item
> is item 2, the unreachable-target refusal. Read this addition, then the body; the
> body is otherwise unchanged and was not re-verified in this pass.
>
> ### The lifecycle lane — mechanism CLOSED, behaviour FROZEN (2026-08-19/20)
>
> A patch that merely **failed to finish booting** used to be permanently destroyed
> on that device, and the telemetry that would have revealed it was broken in three
> independent ways. Both halves are fixed, device-proven and measured:
>
> * an explicit Dart-phase failure retires the patch on the first bad launch and the
>   event reaches the control plane; an **ambiguous** pre-success death is retried;
> * non-terminal `__patch_boot_lifecycle__` telemetry (`ambiguous_boot_retry`,
>   `recovered_after_ambiguity`, `retired_after_ambiguity`), outcome-aware dedupe
>   (migration 9) and `updater_revision` (migration 10);
> * exact event acknowledgement plus failure rotation in the client, so an event is
>   dropped only once THAT event was sent and a stuck batch head cannot censor what
>   is behind it;
> * eligibility for policy analysis keyed to the client's **updater revision**,
>   verified in the shipped engine bytes rather than a build log.
>
> **Four defects were found that each silently zeroed the recovery numerator while
> leaving the denominator intact** — so each biased the answer toward *"recovery never
> happens"* rather than adding noise, and none logged a loss. The details are worth
> reading before trusting any telemetry-driven policy:
> [`SESSION_SUMMARY_lifecycle.md`](SESSION_SUMMARY_lifecycle.md).
>
> **The system is now deliberately frozen.** No lifecycle-behaviour change until 100
> distinct eligible clients report a first ambiguity —
> [`MEASUREMENT_MODE.md`](MEASUREMENT_MODE.md) is that line, and
> [`THRESHOLD_ANALYSIS_PRECOMMIT.md`](THRESHOLD_ANALYSIS_PRECOMMIT.md) fixes the
> ratification criteria before any data exists. The remaining question is not
> technical: *among real clients experiencing a first ambiguous boot, does allowing
> one retry reduce expected user harm compared with immediate retirement?*
>
> **Parked, neither altering the eligible population:** unbounded queue growth while
> the server is unreachable, and the `isRouteBEngine()` cold-cache false negative (a
> non-patchable release is refused a patch, so such a client emits no lifecycle
> events at all and is absent from the population rather than distorted within it).

---

## 1. WHAT WE HAVE ACHIEVED

### Android code push — PROVEN, and effectively done

Release → patch → download → execute → persist → roll back, on our own engine,
our own artifacts, our own control plane. Device-verified (CPH2551 / Android 16 /
arm64). **No known gap in the core loop.** What is unvalidated is configuration
surface — flavors, defines, signing, tracks — not mechanism.

### iOS code push — PROVEN end to end, without upstream's private linker

This is the headline achievement. Upstream's iOS code push depends on
`aot-tools.dill`, their **private** AOT linker. We do not have it and do not need
it: Route B replaces a function's body with bytecode executed through the
interpreter, and the whole chain runs unattended.

    shorebird release ios -> edit one function -> shorebird patch ios
      -> control plane -> updater -> inflate -> install -> lifecycle promotion
      -> native pre-main activation -> patched Dart running -> relaunch still
      patched -> rollback to pristine AOT

Cost: **+4.5% size, +0.3% median frame time, zero added jank.** Both original
vetoes are closed.

**8 device-proven specimens**, 4 with screenshots showing the patched value
alongside `code patch: N` and unpatched control fields still at release values.

### Self-hosting independence — BUILT/PROVEN across 10 upstream dependencies

| # | upstream dependency | our replacement | status |
|---|---|---|---|
| 1 | `api.shorebird.dev` | `packages/code_push_server` | **Built** |
| 2 | `shorebirdtech/dart-sdk` (private) | vanilla Dart + 57-line shim | **Built** |
| 3 | private prebuilt Dart SDK (401s for us) | build from source | **Built** |
| 4 | `shorebird_cli` | forked, pinned, `+selfhost.N` | **Built** |
| 6 | `patch` binary | `vendor/updater/patch` — **byte-identical output** | **Done** |
| 7 | **their private AOT linker** | **Route B** | **replaced** |
| 8 | engine artifacts | own every artifact whose correctness we depend on | **Built** |
| 9 | artifact manifest | generated ourselves | **Built** |
| 10 | `shorebirdtech/flutter` git | mirror + our fork | **Built/Mirrored** |

**We can operate with upstream switched off.** That was the goal and it is met.

### The G15 investigation — mechanism closed

The long-running "patch attaches but the old value executes" mystery is
**explained and repairable**:

> A foldable constant-return target has its result substituted at every call
> site, so no call reaches the `Function`, nothing references it in the object
> pool, Route B attaches perfectly — and nobody ever calls it. Give the same
> target an opaque body and the call survives, the pool reference appears, and
> the patched value renders.

Demonstrated in both directions: synthetically on a matched pair, and by one-line
repair on the target that had failed for the entire investigation
(`ABSENT -> UNIQUE`, `OLD-kill -> NEW-kill`).

### Infrastructure achieved this session

* engine work moved from detached HEADs + `.patch` files onto real branches
  (`mml555/shorebird-flutter@route-b`; Dart SDK unshallowed to 121,349 commits);
* the cost of catching up to upstream Flutter **measured**: 5 conflicts across 39
  files and ~3,350 commits, `updater_rev` unchanged so the wire contract is safe;
* repo reduced from 16,930 tracked files to 1,206;
* publish durability content-read on both halves.

---

## 2. PARITY WITH UPSTREAM

### Where we EXCEED upstream (SUPERSET)

| capability | note |
|---|---|
| **Self-hosted control plane** | upstream is SaaS-only; we run the whole thing |
| **iOS code push without the private AOT linker** | upstream's iOS path requires `aot-tools.dill`; ours does not |
| **Air-gapped operation** | mirrors, overlay CDN, no outbound dependency |
| **Provenance/audit tooling** | measured ancestry per engine cell; upstream has no equivalent |

### Where we MATCH upstream

Android code push end to end; release/patch/rollback lifecycle; tracks and
channels; the patch differ (byte-identical output); artifact serving.

### Where upstream EXCEEDS us

| gap | status | why it matters |
|---|---|---|
| **iOS Dart language surface** | **PARTIAL** | upstream's linker patches arbitrary Dart. Route B accepts a defined subset and REFUSES the rest. Refusal is the designed failure mode — a rejected patch, never a wrong one |
| **Foldable-constant targets** | **KNOWN GAP** | a constant-returning function is optimised away at its call sites; a patch attaches and silently does nothing. Mechanism understood; the CLI does not yet refuse it |
| **Workflow surface** | **INHERITED** | flavors, defines, obfuscation on iOS, signing, tracks/rollouts, manual update API, add-to-app, CI runs — upstream code present in the fork, never exercised on our stack |
| **Windows / Intel-Mac hosts** | deliberately `compat-mirrored` | not built |
| **Multi-platform breadth** | upstream ships macOS/Windows/Linux paths we have not validated | |

### The honest summary

**We match upstream on Android, exceed it on self-hosting and on iOS-without-
their-linker, and trail it on iOS language coverage and on the long tail of
workflow features we inherited but never validated.**

---

## 3. WHAT IS PRODUCT vs WHAT IS EXPERIMENT

| area | engineering status | product contract |
|---|---|---|
| Android code push | **PROVEN** | supported |
| Self-hosted control plane | **BUILT** | supported |
| Independence from upstream services | **BUILT/PROVEN** | supported |
| iOS Route B, accepted language subset | **PROVEN** | **not yet generally advertised or supported** |
| iOS Route B, general Dart | **EXPERIMENTAL** | not in the contract |
| Engine patches `0001`-`0013` | **EXPERIMENTAL** | not in the contract |
| Tombstone/retry lifecycle semantics | **IN TESTING** | not in the contract |
| Inherited workflow surface | **INHERITED** | present but unvalidated here |

**The two columns are deliberately separate.** "We know this works" and "we
promise this to users" are different statements, and Route B is the case that
proves why: the mechanism is PROVEN inside its subset, and
`compatibility.yaml` still does not advertise it. Both are correct at once.

---

## 4. IF WE PUSHED UPSTREAM — WHAT WOULD ACTUALLY MATTER

Most of this is not upstream-shaped, and saying so plainly is more useful than
pretending otherwise.

### Not upstream-relevant

`code_push_server` (they sell the hosted plane), the mirrors/overlay CDN, the
selfhost docs and evidence tree, our fork pinning. These exist because we do not
want their SaaS. That is not a contribution to them.

### Genuinely upstream-relevant

| what | why they would care | readiness |
|---|---|---|
| **The unreachable-target hazard** | exposes a general code-push hazard worth CHECKING in upstream's linker path: a logically patchable source function may no longer have a surviving runtime invocation path after release optimization. **We have not tested their path** — their linker may rewrite optimized call sites, retain different metadata, or reject such targets earlier | **PROVEN for Route B**; unknown for theirs |
| **A CLI refusal for un-patchable targets** | turn the above into "we refuse this patch" instead of shipping a no-op. Small, self-contained, defensible | **NOT BUILT** — the highest-value upstream contribution available |
| **`aot_tools` link-failure diagnostics** | we already consume their `119406bb` | theirs, not ours |
| **Route B itself** | an iOS code-push path that needs no private linker. Strategically significant to them — possibly unwelcome | **EXPERIMENTAL**, large |
| **Boot-lifecycle safety (`0009`/`0010`)** | a patch retired by two ordinary process deaths is a false backout; the threshold work addresses it. **Mechanism CLOSED and device-proven 2026-08-19/20; the threshold VALUE is frozen pending fleet data.** The transferable part for upstream is not the threshold — it is the finding that *an explicit failure report and a process that merely disappeared must never produce the same action*, plus the four instrumentation defects that each silently zeroed the recovery numerator | **PROVEN (mechanism) / MEASURING (threshold)** |

### The one thing worth finishing for upstream credibility

Framed correctly, the feature is NOT "refuse foldable functions":

> **Refuse Route B publication when the exact release artifact has no supported
> surviving invocation path to the replacement target.**

A foldable constant is one CAUSE. The unsafe property is broader — successful
attachment to a replacement `Function` nothing reaches. Other causes will
include inlining, dead-code elimination, and any future optimization that removes
every relevant invocation path. Naming the property rather than the cause is what
keeps the gate correct as the compiler changes.

**Which signal is authoritative matters:**

| signal | role |
|---|---|
| **static call-site probe against the exact release artifact** | **AUTHORITATIVE.** Runs pre-publication, so it can gate. Already reproduces the condition (`NOT LOCATED` on the failing target, `CONSUMED` after repair) |
| `TPOOL_ABSENT` from the runtime scan | **DIAGNOSTIC ONLY.** Excellent corroboration and evidence, but it is observed on device AFTER a patch ships — it cannot be a pre-publication gate |

**The user-facing message must explain the condition, not the compiler theory:**

    Cannot publish this Route B target: the release artifact contains no
    surviving supported call site for it. The release compiler may have
    optimized the function away. Change the release implementation so the call
    remains observable, then create a new release.

**It must NOT suggest that changing the patch source repairs this.** The defect is
baked into the release artifact — that is precisely what the repair experiment
established, since only a NEW release with an opaque body restored execution.

Turning this into a refusal converts the project's most embarrassing failure mode
— attach, report success, do nothing — into its most defensible feature.

## 5. NEXT STEPS, in execution order

1. ~~**Finish tombstone/retry scoring.** One precommitted manual action outstanding.
   Ordered first NOT because it outranks the refusal strategically, but because
   its experimental state is already LIVE and expensive to reconstruct — the
   specimen is staged, the observer qualified, the state cleared. Do not leave a
   nearly-complete safety experiment suspended while changing release behaviour.~~
   **DONE 2026-08-19/20 — and the reason it was ordered first held up.** The
   manual method was not finished, it was **replaced**: a four-mode
   checkpoint-driven fixture with an uncatchable SIGKILL primitive, because a human
   trying to kill a phone inside a ~60 ms window was unmeasurable on this rig.
   Lifecycle behaviour is now frozen — [`MEASUREMENT_MODE.md`](MEASUREMENT_MODE.md).
   **So the next actionable item is 2.**
2. **Build the unreachable-target refusal** (section 4). Highest-value
   engineering task; converts a forensic lesson into a gate users cannot
   accidentally violate.
3. **Batch-validate the INHERITED workflow surface** — flavors, defines,
   obfuscation, signing, tracks. Cheap per item, many items; converts a large
   INHERITED block into PROVEN or KNOWN GAP.
4. **Apply the Flutter bump** — cost already measured; do it after any
   hybrid-dependent measurement, since `SNAPSHOT_HASH` will move.
5. **Park** `TPOOL_AMBIGUOUS` and pragma effects until they block something.

---

## 6. THE MATURITY BOUNDARY

Route B is no longer primarily an interpreter experiment. It now has multiple
independently evidenced iOS executions, measured size and frame-time costs inside
the previously defined veto bounds, understood failure semantics for a formerly
mysterious silent-no-op class, and a **measurable pre-publication condition** that
can turn that silent failure into a refusal.

That makes the next boundary clear: **move known assumptions out of evidence
documents and into executable product gates.** The unreachable-target refusal is
the first and best example — a hard-won forensic lesson becoming something a
future user cannot accidentally violate.
