# gen_snapshot INVOCATION CAPTURE — the defect is in the CLI, not the compiler

Scored against `gs_invocation_precommit.md`. **BUILT FIX** territory: the wired
engine emits patchable sites correctly, and release 103's failure has a complete
mechanical explanation that involves no compiler behaviour at all.

## THE CAPTURE — two invocations, both recorded

| | invocation 1 | invocation 2 |
|---|---|---|
| pid / argc | 2897 / 4 | 5488 / 11 |
| output | `--assembly=/dev/null` (capability probe) | real `snapshot_assembly.S` |
| input dill | — | `app.dill` sha256 `0b99c4cbb3eaacc0…`, 22,482,104 B |
| `--patchable_static_calls` | ABSENT | **PRESENT** |
| real binary sha256 | `3bae134d4f1b24ec…` | `3bae134d4f1b24ec…` |

The binary digest **matches the cell's published `gen_snapshot_arm64` exactly**, so
the binary-selection question is closed: the expected snapshotter ran.

Recording ALL invocations mattered — invocation 1 legitimately lacks the flag
because it writes to `/dev/null`; reading it as "the app AOT step" would have
produced the wrong verdict.

## AND THE RELEASE CAME OUT PATCHABLE

Release `1.4.0+1`, engine `LC_UUID 4C4C447D` (the wired engine):

    patchable sites : 5,843  (1,813 per MB)
    RESULT: PATCHABLE — this release can be patched by Route B

**Identical to release 102's 5,843.** So the wired lineage emits exactly as well as
the known-good one, through the real Flutter build — not just the toy A/B.

## WHY RELEASE 103 GOT 8 SITES — a CLI defect, fully mechanical

`ios_releaser.dart:855` gates the flag on `isRouteBEngine(_routeBEngineBinary)`,
and `route_b.dart:29`:

    bool isRouteBEngine(File engineBinary) {
      if (!engineBinary.existsSync()) return false;   // <-- absence == "no"
      return _containsAscii(engineBinary.readAsBytesSync(), 'InterpretCall');
    }

`_routeBEngineBinary` is
`<flutter>/bin/cache/artifacts/engine/ios-release/Flutter.xcframework/ios-arm64/Flutter.framework/Flutter`
— **exactly the path deleted by `rm -rf bin/cache/artifacts` before the 103
build.**

The chain:

1. artifact cache cold (I had deleted it);
2. the gate runs BEFORE the build downloads artifacts;
3. binary absent -> `isRouteBEngine` returns **false** -> read as "stock engine";
4. `--patchable_static_calls` never added;
5. `_verifyPatchableRelease` **skipped** — deliberately, because
   `_addPatchableCallArgs` returned false and the CLI "will not verify what you did
   not ask for";
6. a **silently non-patchable release published on a Route B engine.**

Release 104 differed in one respect: `flutter precache --ios` ran first, so the
binary existed, the gate returned true, the flag was added, and the built bytes
were verified. Confirmed directly: engine present `True`, contains
`InterpretCall` `True`, so `isRouteBEngine` returns `True`.

**THE DEFECT: absence of a not-yet-downloaded artifact is treated as a negative
capability verdict rather than as "unknown".** The one guard that would have caught
it is switched off by the same false. The only user-visible signal is a MISSING
informational line, which is not a signal.

Suggested fix, not applied here: ensure artifacts are precached before the probe,
or treat a missing engine binary as an error/unknown so the release refuses rather
than silently downgrading.

## PRECOMMIT SCORING

The frozen table's second row applies — "flag present, expected snapshotter ran"
— **but its predicted conclusion does not**, because the premise "still 8 sites"
is false: with the flag present the release came out at 5,843. The
missing-flag hypothesis is **confirmed for release 103** and the emitter is
exonerated. The replay plan is unnecessary; there is nothing left to reproduce.

## TWO EARLIER CHECKS OF MINE THAT PROVED NOTHING — kept so they are not repeated

* the build trace records **no command arguments**, so "0 mentions of the flag" was
  **vacuous**;
* `.S` output stores instructions as `.quad` data, so text-grepping for `ldur`
  returns 0 for both lineages — inconclusive by construction. Assembling with
  `clang -c` and byte-scanning is the valid method (936/935).

I also floated a `build/shorebird` stale-cache hypothesis. **It was wrong** — that
directory holds only trace files, and it is recorded here so nobody pursues it.

## RIG STATE — a deliberate deviation from the precommit, stated plainly

The precommit said restore to cell `50bdae36`. That clause assumed a diagnostic
outcome. The outcome is instead a **working configuration**, so the rig is left on
cell `ac8d8434`:

    engine.stamp / engine.version   ac8d843451f0bb8524932db2bc1fe6ee58c03c0f
    dart runner                     the cell's (Aug 18 lineage)
    gen_snapshot_arm64              3bae134d… (wrapper removed, real binary back)
    release 1.4.0+1                 PATCHABLE, 5,843 sites, wired engine 4C4C447D

Reversal is one sequence: write `50bdae36…` to `bin/internal/engine.version`, run
`update_engine_version.sh` then `update_dart_sdk.sh`, and clear
`artifacts/`, `flutter_tools.snapshot`, `shorebird.snapshot` and their stamps.

`compatibility.yaml` remains **unstamped** — that is a separate gate and belongs to
whoever declares this lane done.

**Release 1.4.0+1 is a patchable specimen on the wired engine**, i.e. the thing the
frozen lifecycle after-run has been waiting for. No lifecycle work was done here.
