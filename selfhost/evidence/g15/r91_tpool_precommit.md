# Release 91 target→pool scan — PRECOMMIT

Written 2026-08-17, **before release 91 is fetched and before any scan runs.**
The question: *does the working specimen's target appear in the global object
pool, where release 96's does not?*

## Why this comparison and not another

`claim2_armA_measurement.txt` measured release 96 as `TPOOL_ABSENT`. ABSENT is the
inlining hypothesis's signature, but it cannot be the differentiator unless the
WORKING specimen differs. This is the same logic that killed the fold: the fold
died when releases 91 and 95 were shown to share the consumption shape. If 91 and
96 share the target-pool shape, inlining loses causal force the same way.

## THE OUTCOME TABLE, precommitted

| observation | what it means | what it does NOT mean |
|---|---|---|
| **91 = ABSENT** (96 = ABSENT) | inlining loses causal force. Working and failing specimens share the target-pool shape, exactly as they shared the consumption shape. The differentiator is elsewhere | NOT that inlining is impossible; only that it does not distinguish working from failing |
| **91 = UNIQUE** (96 = ABSENT) | **the first target-specific structural delta between working and failing specimens.** Localises the regression into release/codegen lineage rather than delivery or attachment | NOT an `OLD-kill` explanation, and NOT proof of mechanism. A delta is a place to look |
| **91 = AMBIGUOUS** | multiplicity is PRESERVED. Report `tpool_index` and `tpool_index2`; choose no slot. Feed `--pool-offset` nothing | NOT resolvable by picking the plausible one |
| **scan cannot run, or evidence inadmissible** | the comparison stays OPEN and is reported as unrun | **NOT** substitutable by aggregate patchability counts, by the old AMBIGUOUS `assert_result_consumed` scans, or by any proxy |

## THE ADMISSIBILITY PROBLEM, named before it can be rationalised

The target→pool scan is a **runtime** instrument: it lives in the engine and reads
the loaded snapshot's global object pool. Release 91 shipped with its OWN engine,
which predates `0012` and has no scan. **So release 91 as shipped cannot produce a
`tpool_*` reading at all.**

The only way to point the proven instrument at release 91's snapshot is a HYBRID:
release 91's `Runner.app` with its `App.framework` (the snapshot under test)
intact, and `Flutter.framework` replaced by the `0012/0013` engine.

This is sound in principle — the global object pool is snapshot-resident data, and
the runtime only reads it — but it is a substitution, so it gets explicit
admissibility conditions rather than an assumption.

**ADMISSIBLE only if ALL of these hold:**

1. the snapshot LOADS — no "Wrong full snapshot version". This is the load-bearing
   one: it is the runtime's own statement that engine and snapshot are compatible;
2. `Dart_RouteBReleaseBuildId()` at runtime equals **release 91's** build id, read
   from the trace/report — proving 91's snapshot is what is running, not 96's;
3. release 91's own patch attaches with `rc=0` — proving the target resolved
   inside 91's snapshot;
4. `tpool_scanned > 0` and `tpool_status ∈ {ABSENT, UNIQUE, AMBIGUOUS}`.

**INADMISSIBLE, and reported as "cannot run" rather than as a result, if:**

* the snapshot refuses to load, or the app will not start;
* the running build id is not 91's;
* the patch is REFUSED (`wrong-release` or otherwise);
* `tpool_status=0` (NOT_REQUESTED) or `tpool_scanned=0`.

**A REBUILD OF RELEASE 91'S SOURCE IS NOT RELEASE 91.** If the hybrid cannot run,
recompiling `1.0.2+1`'s source on the current cell produces a DIFFERENT snapshot
with different codegen, and the entire question is about the shipped snapshot's
structure. Such a rebuild may be run, but it is a separate and weaker
observation, labelled as such, and it does NOT fill this row.

## FEASIBILITY — SETTLED, and the hybrid is viable

Determined 2026-08-17, before any device run, and it is the result that makes this
measurement possible at all.

The hybrid's one fatal risk was the snapshot version check: if `SNAPSHOT_HASH`
differs between release 91's engine and the `0012/0013` engine, release 91's
already-published `App.framework` refuses to load with "Wrong full snapshot
version", and — worse — that would surface as a brand-new device failure on the
very run meant to explain one.

**Measured, on the shipped binaries rather than reasoned about:**

    release 91 engine  (Flutter.framework/Flutter)   21139db2770724220da55c72db00acdc
    release 96 engine  (0012/0013, instrumented)     21139db2770724220da55c72db00acdc

**Identical.** Release 91's snapshot is loadable under the instrumented engine.

This is not luck — it is the design holding. `dart_route_b_trace.h` documents that
`runtime/vm/object.{cc,h}` are in `VM_SNAPSHOT_FILES` (`tools/make_version.py:20-36`),
so `0012` deliberately put its traced sibling in `runtime/lib/object.cc`, which is
NOT a snapshot file, precisely so already-published snapshots keep loading. The
matching hash is that decision, confirmed empirically.

Preserved this session for the measurement:

* `evidence/releases/91/` — `App`, `App.dSYM.DWARF`, `LC_UUID`
  `e8665b59fa7f39338006007fd00cc28e`;
* release 91's `runner` bundle at `/Volumes/build/route-b/r91fetch/run91`,
  signed `dev.selfhost.killswitchProbe`, team `SK85S6YZP9`.

Admissibility condition 1 is therefore PREDICTED to pass, and conditions 2-4
remain to be observed on the run itself. Nothing above is a scan result.

## What stays independent of this comparison

1. **The tombstone-after-one-kill observation** gets its own deliberate lifecycle
   experiment, with `pointers.json` captured BEFORE and AFTER each launch so the
   threshold arithmetic is caught in flight. It must not become an `OLD-kill`
   explanation.
2. **Claim 1's limitation stands verbatim.** `0012`/`0013` is proven to execute,
   to scan, to distinguish supplied from derived state, and to refuse a stale
   valid-in-range slot correctly. It is **not yet proven to emit a correct
   positive `TPOOL_UNIQUE` location in the field.** "Instrument established" is
   justified; "positive locator proven" is not.

   Note the asymmetry this creates, and it is not a reason to discount a UNIQUE
   result — it is a reason to state its status precisely. A `91 = UNIQUE` reading
   would ALSO be the first field exercise of the positive locator. It would
   therefore be reported as *both* a delta *and* the first positive-locator
   observation, neither of which validates the other.

## Arm A

Unchanged by anything here. `gate5_arms_precommit.md` still requires `NEW-kill` on
screen for a PASS. No scan of any release is a screen.
