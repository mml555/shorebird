# `cid 2232` — classified: the v8 snapshot profile writer, not Xcode

## Correction first

I called this an "Xcode error". **It is not.** The message comes from the Dart
VM's AOT snapshot serializer:

    ../../flutter/third_party/dart/runtime/vm/app_snapshot.cc: 7868:
    error: Request to create artificial node for object with cid 2232

Calling it an Xcode error pointed at signing/archive machinery and would have
sent the next person to the wrong layer entirely.

## Identities, recorded before any experiment

    flutter revision : a4a3c0d1b1b0f9975a61f446f0bfa2bbe587ce61
    engine.version   : ca7d2c0d43bf975db2c42cc0aa6351d527443abf
    engine.stamp     : ca7d2c0d43bf975db2c42cc0aa6351d527443abf   (agrees)
    app.dill         : 99ba465c9585498a  (22,502,856 bytes)

Tool bytes vs the OLD checkout that built 1.13.0+1 **successfully**:

| artifact | new | old | |
|---|---|---|---|
| `ios-release/gen_snapshot_arm64` | `3bae134d4f1b24ec` | `3bae134d4f1b24ec` | **SAME** |
| `ios-release/analyze_snapshot_arm64` | `5c3956cc3c4a14fd` | `5c3956cc3c4a14fd` | **SAME** |
| `common/…/platform_strong.dill` | `099b03133aea3927` | `099b03133aea3927` | **SAME** |
| `dart-sdk/bin/dartaotruntime` | `4c9adc366dca04ec` | `f7b5049ee89d36e4` | **DIFFER** |

So this is **not** tool drift: the compiler that aborts is byte-identical to the
one that worked. What differs is the host Dart SDK — which is what *produces*
`app.dill`.

## Three executions, and what each settled

**1 · The exact captured invocation, run directly outside Xcode** →
`Abort trap: 6`, same assertion. **Outcome A: Xcode is innocent.**

**2 · The same binary, the same `app.dill`, the same flags — minus only
`--write-v8-snapshot-profile-to`** → **`rc=0`**, a 9,452,806-byte assembly
produced. The failure is confined to the **v8 snapshot profile writer**. AOT
compilation of this exact program is fine.

**3 · The failing invocation repeated on the same input** → aborts again, and
`app.dill` is unchanged (`99ba465c9585498a` before and after all three runs).
**Deterministic for a given input.**

## What this means

The trigger is Route B's own evidence channel. `--write-v8-snapshot-profile-to`
is passed because P4.1 requires a release snapshot profile, and
`P41_RELEASE_PROBE_SPEC.md` makes that non-optional: *no release profile → no
P4.1 evidence → no Route B patch publication*. So the profile writer aborting
blocks the release by design rather than by accident.

Because run 3 shows determinism per input, the earlier run that **archived
successfully and then failed at export** cannot have had this `app.dill`. That
points the remaining question upstream of `gen_snapshot`: **why does the kernel
differ between nominally identical runs** (the user's Outcome D), with the
differing `dartaotruntime` the obvious first suspect, since the new checkout
carries a different host Dart SDK than the one that produced 1.13.0+1's kernel.

## Explicitly NOT done

* No caches deleted, no `flutter clean`, no DerivedData surgery — the failing
  `app.dill` is preserved at
  `.dart_tool/flutter_build/0d277349d1fac40707d5452d2622c348/app.dill` and is
  the reproducer.
* No change to app code, the Flutter fork, or the engine.
* `cid 2232` was not resolved to a class name; the abort carries no name and
  getting one needs a debug VM or a serializer patch.

## Next question for whoever picks this up

Not "fix Xcode" and not "bump Flutter". It is:

> Which host Dart SDK produced 1.13.0+1's `app.dill`, and does that kernel still
> serialize a profile with this same `gen_snapshot`?

If yes, the defect is a kernel-shape sensitivity in the profile writer and the
actionable fix is on the Dart side. If the old kernel also aborts, then something
outside the kernel changed and the tool-hash table above is the place to look
next.
