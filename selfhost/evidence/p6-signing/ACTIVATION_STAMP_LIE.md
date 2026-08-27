# The coherence gate passed over the wrong engine — found while activating 4792f0ec

A defect in our own verification, found because the new cell gave it something
real to catch. Fixed, and the fix is proven non-vacuous against the exact state
that exposed it.

## What happened

`activate_cell.sh 4792f0ec` reported:

    engine.version          4792f0eca461f376…
    engine.stamp            4792f0eca461f376…
    engine-dart-sdk.stamp   4792f0eca461f376…

    OK   engine artifacts match engine.version
    OK   host dart-sdk matches engine.version
    OK   dartaotruntime is the cell's
    OK   ios / ios-profile / ios-release gen_snapshot carries patchable_static_calls
    COHERENT: 0 failure(s)

The engine in the cache was the **previous cell's**, a week old:

    bin/cache/artifacts/engine/ios-release/…/Flutter
      cached  49182b375aeb858b   mtime Aug 20 22:01   carries f729f958e9be
      cell    62bd2395005cc315                        carries af6e842ccf87

A release cut from that checkout would have been built against the previous
runtime while every report named the new cell. That is the same class of failure
as release 1.14.0+1, and this time the gate that exists to prevent it said
nothing.

## Why every check passed

1. **`activate_cell.sh` never invalidated the engine artifacts.** It deleted
   `engine-dart-sdk.stamp`, `flutter_tools.{stamp,snapshot}` and the shorebird
   snapshot, then ran `flutter --version`. That refreshes the **host** artifacts
   and writes `engine.stamp` — it does **not** fetch iOS artifacts. So
   `engine.stamp` came to assert bytes that were never fetched. The script's own
   header warns against establishing a revision by writing stamps; it was doing
   exactly that, one level down.
2. **The coherence gate compared stamps, not bytes.** Checks 1 and 2 read stamp
   *contents*. A stamp asserts what the cache is *claimed* to hold.
3. **The one check that did read bytes could not discriminate.**
   `patchable_static_calls` is carried by **every** Route B cell's
   `gen_snapshot`, so it distinguishes Route B from stock — never this cell from
   its predecessor. It was a capability check being read as an identity check.

Three green checks, none of which could see the problem. This is the
"vacuous checks are worse than missing ones" failure with a concrete cost
attached: it would have certified Signing against the old runtime, and the device
gate's `Reporting launch start.` row would then have failed for a reason nobody
would have understood.

## The fix

**`verify_toolchain_coherence.sh` gains check 3b:** for each iOS mode, extract
the engine binary from *that cell's own published `artifacts.zip`* and compare it
byte-for-byte against the cached one. Not cached yet is reported as such, not as
a pass in disguise; cached-but-no-published-zip is a failure.

**`activate_cell.sh` now deletes `bin/cache/artifacts/engine`,
`bin/cache/downloads` and `bin/cache/engine.stamp`**, and then runs
`flutter precache --ios` explicitly, because `--version` does not fetch iOS
artifacts. `engine.stamp` must go *with* the artifacts — leaving it behind is how
the revision got "established" without the bytes arriving. The explicit precache
also satisfies the mint script's precondition 3: `isRouteBEngine` returns false
when the `ios-release` binary does not merely mismatch but does not *exist*, so a
cache that is empty rather than wrong still makes the first release silently take
the non-Route-B path.

## Proof the new check is not vacuous

Run against the stale cache, before fixing activation — all three modes caught,
with the predecessor's digests named:

    FAIL ios         cached 567acd54c9a725a5, cell 745e178c447789ce
    FAIL ios-profile cached 7cde65d962742568, cell de68eefd42df7bbb
    FAIL ios-release cached 49182b375aeb858b, cell 62bd2395005cc315
    INCOHERENT: 3 failure(s) — do NOT cut a release from this checkout

`567acd54` and `49182b37` are exactly the digests measured earlier from cell
`ca7d2c0d`'s published `ios/artifacts.zip` and `ios-release/artifacts.zip`. The
check named the right wrong bytes.

After the activation fix, same command:

    OK   ios cached engine IS this cell's (745e178c447789ce)
    OK   ios-profile cached engine IS this cell's (de68eefd42df7bbb)
    OK   ios-release cached engine IS this cell's (62bd2395005cc315)
    OK   shorebird.snapshot runs under the current SDK
    COHERENT: 0 failure(s)

And `PLATFORM=android` still reports *iOS Route B capability: NOT EVALUATED*, so
the platform scoping settled earlier is intact.

## Final state of the activated checkout

    Shorebird 1.6.115+selfhost.1
    Flutter   3.44.8+selfhost.1 • a4a3c0d1b1b0f9975a61f446f0bfa2bbe587ce61
    Engine    4792f0eca461f3761001a1adbe131b4b115e3684

    consumed ios-release engine  62bd2395005cc315…
      af6e842ccf87                 present
      Preparing next boot          present
      Next boot candidate rejected present
      f729f958e9be                 ABSENT

## What this does not settle

The consumed bytes contain the new runtime. Whether the engine *calls* it is
still only decidable on device: `report_launch_start` remains linked in the Rust
library, so a binary on the old path would carry both strings. The precommitted
device row stands — `Preparing next boot.` present, `Reporting launch start.`
absent, in the syslog.

## Worth asking separately

Earlier cells were activated during the epoch-crossing work, which cleared caches
explicitly, so their verdicts were probably sound. "Probably" is doing real work
in that sentence, and any past COHERENT verdict from a partial activation is now
known to be unreliable. Cell `ca7d2c0d` was activated on 2026-08-20 and the iOS
artifacts in the cache dated from that same activation, which is consistent with
a correct fetch then — but this gate could not have told us otherwise.
