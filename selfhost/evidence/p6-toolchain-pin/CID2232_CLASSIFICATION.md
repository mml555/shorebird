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


---

# RESOLVED: it was toolchain incoherence, not the serializer

## The three-way host Dart SDK identity check

| | `dartaotruntime` | Dart | SDK revision | source |
|---|---|---|---|---|
| **A** | `4c9adc366dca04ec` | 3.12.2 | `db98bdaa9d8f` | the checkout producing the failing kernel |
| **B** | `f7b5049ee89d36e4` | 3.12.2 | `6b58bb3a72e2` | the **active cell's published** `dart-sdk-darwin-arm64.zip` |
| **C** | `f7b5049ee89d36e4` | 3.12.2 | `6b58bb3a72e2` | the checkout that built 1.13.0+1 |

`A != B`, `C == B`. So 1.13.0+1 *was* on the authoritative cell SDK — checked
rather than assumed, which was the right instinct: promoting a stale SDK to
"correct" because one release happened to work would have hidden the defect.

## Root cause: two independent stamps

    bin/cache/engine.stamp            -> engine artifacts
    bin/cache/engine-dart-sdk.stamp   -> host dart-sdk

The failing checkout had `engine.stamp = ca7d2c0d` (cell) and
`engine-dart-sdk.stamp = 69f9831c` (stock). Writing `engine.version` and
refreshing the engine left the kernel producer behind, giving a **mixed
toolchain**: the cell's `gen_snapshot` with a foreign frontend.

Two further derived-artifact consequences, both hit in sequence:
`flutter_tools.snapshot` is compiled **by** the host SDK and must be rebuilt, and
so must the CLI's own `shorebird.snapshot`, which otherwise refuses with
`Wrong full snapshot version`.

## The causal result

Correcting **only** the host SDK identity — `gen_snapshot` untouched and
byte-identical throughout — made the abort disappear:

| kernel producer | `app.dill` | mandatory profile writer |
|---|---|---|
| stock `db98bdaa9d8f` | `99ba465c9585498a` | **aborts** at `app_snapshot.cc:7868` |
| cell `6b58bb3a72e2` | `f1ae4a0df95bd5a5` | **succeeds** |

The old-vs-cell kernel experiment was therefore not needed: the identity fix was
the only variable, and it settled the question. The failing kernel is preserved
outside the repo (22 MB) at `app_dill_FAILING_99ba465c.dill` in the session
scratchpad; its hash is recorded above.

**`cid 2232` is closed as a non-defect for us.** No serializer patch, no Dart
bump, and `--write-v8-snapshot-profile-to` remains mandatory — P4.1 was not
weakened to obtain a green release.

## Machine-checked, not documented

`scripts/verify_toolchain_coherence.sh` asserts stamp agreement, that the
checkout's `dartaotruntime` is **byte-identical** to the cell's published one,
that every iOS `gen_snapshot` carries `patchable_static_calls`, and that the CLI
snapshot runs under the current SDK. Mutation-tested against a reconstruction of
the exact defective state: **2 failures, exit 1**; coherent checkout: **0
failures, exit 0**. (The first exit-code test was itself vacuous — `$?` came from
a `sed` in the pipeline — and was redone directly.)

`scripts/activate_cell.sh` performs the whole sequence as one operation and ends
by refusing to hand back an incoherent checkout.

## Exit criterion: two consecutive clean releases

**1.16.0+1** and **1.17.0+1**, both from the coherent checkout with **no cache
surgery between them**, both shipping `channel: beta`, and patch 1 published to
**beta only** against 1.17.0+1 (`stable: ABSENT`).

## Still open: the device smoke

Neither the operator nor I can launch the app in a way this lane accepts. Every
`ios-deploy` launch flag (`-d`, `-L`, `-m`, `-I`) goes through lldb/debugserver,
which `evidence/g15/manual_launch_control_precommit.md` classifies as
invalidating, and `devicectl` reports this iPhone 7 (`iPhone9,1`) as
`unavailable` — the known iOS 15 blindness. The release is installed and patch 1
is live on beta; the arm needs one physical tap sequence and nothing else.
