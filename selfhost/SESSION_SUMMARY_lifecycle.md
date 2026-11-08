# The lifecycle lane, end to end

What was accomplished, what it cost, and what it changed. Companion to
`LIFECYCLE_POLICY.md`, `MEASUREMENT_MODE.md` and the `evidence/g15/` tree.

## 1. THE HEADLINE

A patch that a device merely *failed to finish booting* used to be permanently
destroyed on that device — and the telemetry that would have revealed it was itself
broken in three independent ways. Both halves are now fixed, device-proven, and
measured by an estimator that cannot silently under-count.

## 2. WHAT SHIPPED

| area | outcome |
|---|---|
| **Arm B — crash-backout** | An explicit Dart-phase failure retires a patch on the FIRST bad launch, event reaches the control plane, next launch runs the release. §15's gate closed — with the finding that it **hangs rather than crashes**, so the gate's own wording is wrong |
| **C3/C4 wired into production** | An ambiguous pre-success death is now RETRIED, not treated as proof the patch is bad |
| **Lifecycle telemetry** | Non-terminal `__patch_boot_lifecycle__` events with `ambiguous_boot_retry` / `recovered_after_ambiguity` / `retired_after_ambiguity` |
| **Event queue correctness** | Exact acknowledgement + failure rotation: an event disappears only once THAT event was sent, and a stuck batch head can no longer censor what is behind it |
| **Server** | Outcome-aware dedupe (migration 9), `updater_revision` (migration 10), `bootLifecycleMetrics()` |
| **Eligibility** | Defined by the client's own updater revision, stamped into every event, verified in shipped bytes |
| **Policy discipline** | Telemetry validity epoch + threshold-analysis criteria frozen before any data exists |

## 3. THE FOUR SILENT-LOSS DEFECTS

Every one destroyed the same number — the recovery numerator — while leaving the
denominator intact, so each biased the answer toward "recovery never happens" rather
than adding noise. None logged a loss.

1. **C3/C4 were never wired in.** `detect_boot_crash_on_init` had no production
   caller; `handle_prior_boot_failure_if_necessary` retired on the first
   un-succeeded boot. **18 host tests passed the whole time**, because they tested a
   function production did not call. The gap was even asserted as intent by a green
   test named `reports_patch_install_failure_if_patch_was_booting`.
2. **Server dedupe collision.** The key was
   `client|app|release|patch|type|timestamp`, so a retry and a recovery landing in
   the same second collided and the recovery was discarded. Found by inspection
   before shipping — then observed destroying a real recovery on device.
3. **Whole-queue wipe.** The flusher sent a batch captured by an earlier read and
   then called `clear_events()`, destroying anything enqueued in between. The source
   comment said *"that's OK for now"* — true for coarse counters, false the moment a
   queued event carried meaning.
4. **Head-of-line starvation.** `copy_events` takes the FIRST n, so with
   retain-on-failure, n stuck events form a permanent batch and censor everything
   behind them. Found by asking what the fix to (3) implied, not by observation.

## 4. THE DEVICE EVIDENCE

Paired runs, identical fixture source, checkpoints, kill primitive, observer and
scoring — **only the engine differed**:

| row | BEFORE (release 102) | AFTER (release 104) |
|---|---|---|
| 1-3 success / success-then-kill / success | clean, 0 events | same |
| 4 `hard-kill` | breadcrumb set, no explicit failure | same |
| **5 `success`** | **patch RETIRED single-strike, release renders** | **patch survives, patch boots, `recovered_after_ambiguity`** |
| 6 `dart-fail` | explicit, terminal, immediate | same |

Five stable controls, one variable, one flip. Then closure: both outcomes persisted
as distinct server rows under one correlation identity, and the metric counted the
recovery.

**Separately device-proven, needing no new engine:** an explicit patch-blaming
failure and an ambiguous disappearance are *observably different events* — different
report timing, breadcrumb state, classifying process, and wire message.

## 5. THE HARNESS THAT MADE IT MEASURABLE

* **Four-mode fixture** — `success` / `dart-fail` / `hard-kill` / `success-then-kill`,
  selected before startup, **checkpoint-driven not timer-driven**.
* **Uncatchable SIGKILL via FFI to libSystem** — no engine change, no plugin. Chosen
  over `Process.killPid`, which had already failed as a primitive because it returns
  a bool the caller dropped. The receipt line *after* the kill can only appear if the
  signal did not land, so a vacuous run is detectable.
* **Durable witnesses** — `success_diag.log` and `state_diag.log`, readable by
  `afcclient`, so absence from a 191 MB syslog could never be confused with absence
  of execution.
* **Per-instance state tracing** — `LOAD` / `QUEUE_EVENT` / `SAVE` with queue lengths
  and fingerprints, which is what turned "the event vanished" into a specific line of
  code.

This replaced the earlier method — a human trying to kill a phone inside a ~60 ms
window — which was unmeasurable on this rig and was abandoned rather than repeated.

## 6. TOOLCHAIN AND PIPELINE WORK

Getting a wired engine onto a device was most of the calendar time.

* **Coherence is relational.** Seven members must share one lineage: engine,
  `gen_snapshot`/`analyze_snapshot`, `flutter_patched_sdk_product`, `dart-sdk`, the
  Dart VM that RUNS the tooling, the generated `flutter_tools.snapshot`, and Route B
  producer artifacts. Every artifact can be individually correct while the
  installation is invalid.
* **A stale generated file, not a broken toolchain.** `version.cc` from Aug 10
  hard-coded the old SDK hash. The decisive clue was that a freshly built
  `gen_snapshot` was **byte-identical** to the old one — so the tool was not the
  variable.
* **`dart_sdk_verification_hash` is a pinned GN arg**, not derived. The SDK hash is
  configuration.
* **A real GN bug fixed** (`flutter@route-b`): the `dart_sdk_archive` entitlements
  entry lacked `rebase_path`, so `dart-sdk-darwin-arm64.zip` could never rebuild.
* **`isRouteBEngine()` cold-cache false negative** — absence of a not-yet-downloaded
  artifact reads as "not a Route B engine", silently suppressing
  `--patchable_static_calls` *and* the verification that would catch it. This was my
  own doing: I deleted the artifact cache, then spent a lane hunting a compiler
  regression that did not exist.
* **Two revision-stamp defects**, both caught by verifying bytes rather than logs:
  `git` is absent from the ninja action's PATH, and `.git/HEAD` does not change when a
  commit lands on a branch.

## 7. THE PRACTICES THAT DID THE WORK

* **Precommit the interpretation.** Every device run had its scoring table frozen
  first, including a STOP-and-preserve row. One precommit's rows turned out not to be
  mutually exclusive — recorded as a drafting fault rather than resolved by picking
  the flattering row.
* **Mutation-check every guard.** A green test proves nothing until you have seen it
  fail. This caught vacuous checks repeatedly, including one of my own diagnostics.
* **Entrypoint tests, not just helper tests.** Helper tests prove a mechanism
  exists; only entrypoint tests prove the product uses it. The C3 fix was driven
  red-first at the production entrypoint *while the 18 helper tests stayed green* —
  that contrast is the proof it aimed at the real defect.
* **Fetch-back gates.** Verify the bytes the consumer *selects and executes*, not the
  archive you published. This caught two different coherence failures.
* **Provenance describes what ships.** `compatibility.yaml` is stamped only after
  fetched-back bytes verify — and was reverted whenever a run blocked.
* **Supersede conclusions, preserve evidence.** Withdrawn attributions keep their
  reasoning under addition-only headers.

## 8. MISTAKES WORTH KEEPING

Recorded because the corrections are reusable.

* **Grepped the pinned copy** instead of the tree that builds the artifact, and
  concluded a constant did not exist. The device's own state contradicted me and I
  read past it.
* **Concluded ingestion was broken** and rolled back a correct server deploy — the
  rows existed but were not yet flushed, and `docker cp` showed the same stale state.
* **Two false negatives from my own tooling**: a `capture.sh` path that stripped a
  directory, and a `grep \b` that failed against a string-table neighbour. Both
  nearly produced the wrong verdict; an on-device control line is what saved one.
* **Shipped the client half before the server half**, against explicit instruction.
* **Predicted the wrong shape** of the lost update — a stale snapshot rather than a
  clear derived from an earlier read. The trace refuted it, and the distinction
  changed the fix.

## 9. WHERE IT STANDS

**Closed:** the mechanism. **Frozen:** lifecycle behaviour, until 100 distinct
eligible clients report a first ambiguity.

**Parked, neither altering the eligible population:** unbounded queue growth while
the server is unreachable; the `isRouteBEngine` cold-cache defect (a non-patchable
release is refused a patch, so such a client emits no lifecycle events at all and is
absent from the population rather than distorted within it).

**The remaining question is not technical:**

> Among real clients experiencing a first ambiguous boot, does allowing one retry
> reduce expected user harm compared with immediate retirement?

The `1.4`-`1.6` rows are kept visible, showing one ambiguity and zero recoveries
each. They are the standing proof of why **telemetry correctness has to be
established before telemetry is allowed to drive policy** — three separate defects,
each silently zeroing the same numerator, none of which any log reported as a loss.
