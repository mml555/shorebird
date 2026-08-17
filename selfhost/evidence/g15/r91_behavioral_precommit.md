# Hybrid release 91 — BEHAVIORAL LINEAGE DISCRIMINATOR, precommit

Written 2026-08-17, **before the run.** Release 91's shipped snapshot, its exact
historical patch 59, on the current instrumented engine lineage
(cell `50bdae36…`, patches 0011/0012/0013).

**Target unchanged. Patch unchanged.** The only substitution is the engine, and it
is the same hybrid whose admissibility was established in
`r91_vs_r96_tpool_verdict.txt` (SNAPSHOT_HASH match; `rc=0` attach proving the
running build id is release 91's).

## Why behavioral and not another structural probe

Two structural measurements — result-consumption and target→pool — have now each
failed to separate the working specimen from the failing ones. Both were the
leading explanation when proposed; both died by showing 91 and the failing
releases share the state. A third structural probe is the lowest-yield move
available.

The remaining candidate space is **engine/cell lineage** vs **release-production
lineage** (CLI `98f84c17`, compiler inputs, platform dill). One behavioral run
splits it.

## THE OUTCOME TABLE, precommitted

| observation | what it licenses | what it does NOT license |
|---|---|---|
| **hybrid 91 renders `NEW-kill`** (patch Installed) | the current engine-side changes are COMPATIBLE with the historically working behavior. The search moves toward **release-production lineage** — CLI, compiler inputs, platform dill | NOT that the engine changes are irrelevant to anything; only that they do not by themselves destroy the working behavior |
| **hybrid 91 renders `OLD-kill`** (patch Installed) | **the current engine/cell lineage is a real discriminator**, despite 91 and 96 sharing the ABSENT structural result. A behavioral delta with no structural delta is itself the finding | NOT a mechanism, and NOT an arm A PASS/FAIL — arm A's table is about release 96's own specimen |
| **patch tombstones before an admissible screen** | **NO behavioral verdict.** Report as unrun; preserve the lifecycle state for the separate tombstone/retry lane | NOT substitutable by a screen taken after `Bad{BootCrash}`, which is the exact error this cycle already made once |

## THE COLLECTION REQUIREMENT, and it is the point of writing this down

Arm A's launch 4 was a collection failure: the one launch that both rendered AND
had the patch active was not screenshotted, and the screen captured two launches
later showed `OLD-kill` from a TOMBSTONED patch — which means nothing. This
precommit exists so that cannot recur.

**An admissible observation requires ALL FOUR, and they must be the SAME launch:**

1. **a screenshot** showing both the `route B value:` line AND the
   `launch <id>` line — the fixture prints its own launch id, so the screen
   carries its correlation key;
2. **the receipt** containing that SAME `<id>` with `arm:render` AND
   `first-frame` — proving the launch rendered rather than took the kill arm;
3. **`patches/1/state.json` = `{"kind":"Installed"}`**, pulled BOTH before and
   after the launch, bracketing it — a patch that is `Bad{BootCrash}` at either
   end invalidates the screen;
4. **the patch actually active on that boot** — `pointers.json` showing the patch
   as the booting/booted patch, and a `v=5` trace line with `rc=0`.

**If any one of the four is missing, the run is reported as UNRUN, not as a
result.** A screen without its receipt id, or with the patch tombstoned at either
bracket, is exactly the artifact that made launch 6 worthless.

## Sequencing hazard, named in advance

The fixture self-alternates: marker absent → SIGKILL, marker present → render. So
render launches are every other boot, and each kill launch with the patch active
is a boot that does not bank success — which is what drives the counter toward
tombstoning. **The admissible window is therefore narrow and may close.** That is
the third outcome above, and it is a legitimate result, not a reason to relax
requirement 3.

## AMENDMENT, before the run — three deviations, each with its reason

Written after inspecting the device and release 91's binary, and BEFORE any
launch. Recorded here rather than explained afterwards.

### 1. Requirement 1-2 are UNSATISFIABLE for release 91, and are substituted

Release 91 is `1.0.2+1` and **predates the receipt instrumentation entirely.**
Measured on its shipped `App`:

    arm:render  0     first-frame  0     dart-main-entered  0
    g15_receipt 0     "launch "    0     (release 96 has all five)

Its UI carries `G15 arm 2` and `route B value:` and no launch id. main.dart's own
comment dates the phase-log after `1.0.3+1`, so this is expected, not a fault.

**Substituted, preserving the intent of each:**

| original | substitute | why it carries the same weight |
|---|---|---|
| screenshot shows `launch <id>` | screenshot shows the RENDERED UI (`G15 arm 2` + `route B value:`) | requirement 2's purpose was to prove the render arm. **A drawn UI is self-evidencing**: the kill arm SIGKILLs before `runApp` and never draws |
| receipt line with matching id | **trace line-count DELTA across the launch** (N → N+1) | proves the patch ACTIVATED on this specific boot — a per-launch correlation the receipt id was standing in for |
| — | screenshot must NOT show a `launch <id>` line | positively discriminates release 91's UI from release 96's, so a stale r96 frame cannot be mistaken for this run |

Requirements 3 (Installed bracket before AND after) and 4 (patch active, `rc=0`)
are unchanged and still binding.

### 2. The window is ALREADY CLOSED, so the updater state is CLEARED — not asserted

`BOOT_FAILURE_THRESHOLD = 2` (`0010`), and the device sits at
`boot_attempt_count: 1` with an unfinished breadcrumb
(`currently_booting_patch: 1`, `last_booted_patch: null`). The next boot
increments to 2, and `2 < 2` is false — so it backs the patch out **at init,
before Dart runs.** Any screen captured from here would show `OLD-kill` from a
tombstoned patch: precisely the artifact this precommit exists to forbid.

So `/Library/Application Support/shorebird` is **deleted** (`ios-deploy --rmtree`)
and the updater re-downloads and re-installs the patch by its own logic.

**This asserts nothing.** No `pointers.json` or `state.json` is hand-written; the
Installed state and the zeroed counter are REACHED by real work. It is the same
rule the mint applies to cache stamps — *"delete the state and force consumption
instead"*, never write a stamp claiming what is already there. The app itself is
NOT uninstalled, so Local Network consent survives.

### 3. The render arm is FORCED, by creating the fixture's own marker

`Documents/g15_armed` is uploaded before the launches that must render. Its
presence is the state **the fixture itself creates on every kill launch**; the app
deletes it and renders.

This selects WHICH ARM a launch takes and nothing else. It does not touch
`routeBValue`, the patch, the engine, or the value displayed. It is done because
each unnecessary SIGKILL is a boot that does not bank success, which drives the
counter toward the threshold and closes the admissible window — the exact failure
mode being worked around. **Forcing render protects the observation; it cannot
manufacture its result.**

## Explicitly out of scope

* **The `boot_attempt_count: 1` state captured during the structural run stays
  out of this experiment entirely.** It is valuable and it belongs to the
  dedicated tombstone/retry lane, which needs counters bracketed per launch by
  design rather than harvested opportunistically here.
* **Arm A is not re-scored.** `gate5_arms_precommit.md` concerns release 96's
  specimen; this is release 91's.
* **Claim 1's wording is unchanged**: instrument established; positive locator not
  yet proven. Nothing in a behavioral run can validate the positive-location
  branch, since that requires a `TPOOL_UNIQUE` reading and neither specimen
  produced one.
