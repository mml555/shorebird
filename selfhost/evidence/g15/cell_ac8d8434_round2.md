# CELL `ac8d8434` ROUND 2 — consumer coherence SOLVED, blocked on patchable-site emission

Outcome: **BLOCKED**, one layer further in than round 1. The boundary is new,
narrow, and mechanically located. **No lifecycle verdict is changed.**

## WHAT NOW WORKS — everything round 1 was blocked on

### The runner mismatch — proven, then fixed through the supported path

Measured in both directions **before** changing anything, as required:

| runner | snapshot | result |
|---|---|---|
| OLD | old | **ok** |
| OLD | new | Wrong: expected `8889ac395b` found `21139db277` |
| NEW | new | **ok** |
| NEW | old | Wrong: expected `21139db277` found `8889ac395b` |

**This CORRECTS round 1's conclusion.** `8889ac395b` is the OLD runner's format and
`21139db277` the NEW one — so the original failure (`expected 21139db277 found
8889ac395b`) was the **NEW VM running an OLD snapshot**, the reverse of what round
1 recorded. The stale snapshot was `shorebird.snapshot` (the CLI's own), not only
`flutter_tools.snapshot`.

**Fixed with no cache surgery**, using the CLI's own mechanisms:

    bin/internal/engine.version   <- the cell selector
    update_engine_version.sh      <- propagates it to bin/cache/engine.stamp
    update_dart_sdk.sh            <- curl-downloads dart-sdk for THAT stamp
    delete shorebird.stamp        <- shared.sh:181 regenerates the CLI snapshot
                                     with the NEW $DART_PATH

**The key rig fact, which cost round 1 the run:** `update_dart_sdk.sh` reads
`bin/cache/engine.stamp`, **not** `bin/internal/engine.version`. Writing the
version file alone silently keeps downloading the old cell. And never delete
`dart-sdk` itself — `shared.sh` needs a working `dart` to bootstrap; delete the
STAMP instead.

Result: `shorebird --version` reports `Engine • revision ac8d843451f0…`.

### Route B producer tooling — published, audited CLEAN, fetched, probed

All four producer artifacts were STALE (`dart rev 6b58bb3a72`) and were rebuilt
from the current tree to `9e8c898a4d`, then published with
`publish_route_b_compiler.sh`.

**The auditor caught a real drift on the first attempt:**

    FINDING: PLATFORM DILL SPLIT: address computed over 9f5a5f754a93dd8e…,
    builds download 099b03133aea3927…

`FLUTTER_PLATFORM` defaults to a stale `published_sdk/` path, so the bundle's
platform dill did not match the one the cell delivers — precisely the drift that
script's own header documents. Re-published with `FLUTTER_PLATFORM` pointed at the
cell's delivered dill → **AUDIT CLEAN**, including "served platform dill is the one
the address was computed over".

Fetch-back probe: HTTP 200, all seven required files present, and the **fetched**
`dartaotruntime` + `dart2bytecode.aot` pair executes and advertises
`--target flutter`.

### Release 103 built

`✅ Published Release 1.3.0+1` with **no** SDK-hash error, **no** snapshot-version
error and **no** producer-tooling warning. Shipped app carries engine
`LC_UUID 4C4C447D` and all four lifecycle strings, where the BEFORE engine has zero.

Fixture source byte-identical to the freeze
(`b284143628441e50543317f5f78ca7da…`); only version metadata differs.

## THE NEW BLOCKER — the release is not patchable

    This release was not built with Route B patchable call sites
    (8 sites, 3/MiB), so it cannot accept a Dart code patch.

**Located to the emitter, not the counter**, by running the SAME scanner over both:

    release 102 (BEFORE engine)  5,843 sites (1,813/MB)  PATCHABLE
    release 103 (wired engine)       8 sites     (3/MB)  NOT PATCHABLE

Both cells' `gen_snapshot_arm64` **accept** `--patchable_static_calls` — each
proceeds to the `--elf` argument error rather than rejecting the flag — and the
CLI did pass it (`--extra-gen-snapshot-options=--patchable_static_calls`). So the
flag is accepted and has no effect in the new lineage.

**Not diagnosed further**, deliberately: that is the next lane's first question,
and it is an emission question, not a lifecycle one.

The obvious candidates, untested and recorded as such:
* a GN-level prerequisite our `ios_release` config lost (`shorebird_use_interpreter
  = false` with `dart_dynamic_modules = true` is an unusual pairing, chosen
  deliberately for the interpreter);
* the route-b Dart patch implementing the flag not reaching the arm64 AOT path in
  this configuration;
* `--patchable_static_calls` being consumed by a different gen_snapshot than the
  cell's.

## RIG STATE — restored and verified

`engine.version` and `engine.stamp` back to `50bdae36…`, `dart-sdk` re-downloaded
for it, snapshots and artifacts cleared so they regenerate; fixture back to
`1.2.0+1`. `shorebird --version` reports `Engine • revision 50bdae36f6da…`.

**`compatibility.yaml` was NOT stamped** — the definition of done requires a real
Route B build first, and there was none.

Release 103 EXISTS on the control plane and is **not patchable**. It is evidence,
not a usable specimen. Cell `ac8d8434` remains published with a CLEAN producer
bundle.

## WHAT IS UNCHANGED

explicit-vs-inferred failure **device-PROVEN** · hard-kill primitive
**device-qualified** · release-102 baseline **PROVEN** · wiring + telemetry
**BUILT / host-tested** · row-5 recovery **pending**.
