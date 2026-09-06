<!-- cspell:words dartaotruntime dill semantic linker nodm dynmod KBC -->
# SL1-G1 — the matched OFF/ON substrate

**Gate:** [#38](https://github.com/mml555/shorebird/issues/38) · **Tracker:** [#36](https://github.com/mml555/shorebird/issues/36)
**Run:** 2026-09-06 · **Verdict: BUILT AND MATCHED. Every precommitted prediction held.**

Predictions: [`PRECOMMIT.md`](PRECOMMIT.md), committed at `e990647a` while the
builds were still compiling. Machine-readable results:
[`g1_manifest.json`](g1_manifest.json). Transcripts:
[`evidence/`](evidence).

## The pair

Both configurations were built from **one** staged source tree, in one session,
from **one** `tools/gn` run. `build_matched.sh` refuses to start unless the two
`args.gn` differ by exactly one line, and that line is the experiment:

    < (nothing removed)
    > dart_dynamic_modules = true

|  | OFF — `out/sl1_dm_off` | ON — `out/sl1_dm_on` |
|---|---|---|
| `dart_dynamic_modules` | absent | `true` |
| `dart_version` stamped | `9e8c898a…` | `9e8c898a…` |
| `gen_snapshot` | `a1220d87…` | `935f3938…` |
| `dartaotruntime` | `4f2ff7a8…` | `a9cd02be…` |
| `dart-sdk/bin/dart` | `c34dec14…` | `b706f8c8…` |
| `vm_platform.dill` | `015ef32c…` | `015ef32c…` (identical — see below) |

The three executables **differ**, which discharges the falsification criterion
"ON and OFF producing byte-identical binaries → the flag never reached the
compile, and the pair is one build measured twice."

## Why the existing `nodm` tree was not used as the control

It is the obvious candidate and it is not a matched pair. Its `args.gn` records
`dart_version = 9e8c898a…` while the dm host beside it still records
`6b58bb3a…`, and the two were built three weeks apart. Two settings differ, not
one, so it cannot attribute a difference to the flag. Nothing about it was
changed; it simply is not this gate's control.

## Results, both arms

Each native now runs in **its own process**. The first version ran attach and
then load in one process and load came back
`StateError: library '…replacement.dart' is already loaded` — attach had loaded
that same module moments earlier. That is the harness contaminating its own
measurement, and it would have been recorded as if it said something about the
load path.

| | OFF (control) | ON (experiment) |
|---|---|---|
| normal AOT, no module | `target()=OLD hostSuffix()=HOST`, exit 0 | same, exit 0 |
| `attachBytecodeToFunction` | **`returned=false`** | **`returned=true`**, `IsInterpreted` 0 → 1, `HasBytecode` 0 → 1 |
| interpreter actually ran it | — | **`C++ invoke of target returned: NEW`** |
| Dart-side call after attach | `OLD` | `OLD` |
| `loadDynamicModule` | **throws `UnsupportedError: Loading of dynamic modules is not supported.`** | **`returned=NEW`** |

Scored against the precommit: **4 of 4 OFF predictions held, 4 of 4 ON
predictions held.** In particular the asymmetry the precommit named in advance —
attach refuses by *return value*, load refuses by *throwing* — is confirmed. A
probe expecting one shape for all three would have scored the control as broken.

`DART-CALL: target()=OLD` on the ON arm is **expected and is not a failure**: in
AOT those call sites are statically bound. That is the 2026-08-04 call-emission
gap, which G1 does not close and does not claim to. A run reporting `NEW` there
would have meant the harness had changed, not the VM.

## The experiment patch set is EMPTY, and that is a result

G1 asks for every experiment-only engine/Dart patch to be banked with a digest.
There are none. The frozen lineage already registers
`Internal_attachBytecodeToFunction`, `Internal_detachBytecodeFromFunction` and
`Internal_loadDynamicModule` unconditionally in `bootstrap_natives.h`, and
exposes all three on `dart:_internal`. The substrate under test needs no
experiment-only source change at all.

`killgate/0001-attach-bytecode-native.patch` still exists because it predates
that landing. **It is not applied here**, and applying it would be a mistake.

## One shipped cell member reproduces from the bank; the executables do not

Stated per member, because both "the cell reproduces" and "nothing reproduces
the cell" would be wrong:

| shipped member | shipped | rebuilt here | |
|---|---|---|---|
| `vm_platform.dill` | `015ef32c…` | `015ef32c…` | **byte-identical** |
| `dartaotruntime` | `075ccbb2…` | `a9cd02be…` | differs |

This is independent corroboration of G0: a fresh build, in a fresh out dir, from
the banked frozen lineage, reproduced a shipped cell member exactly — which it
could not do if the bank did not reconstruct the producing source. It narrows,
but does not overturn, `NEXT_LANES.md`'s "nothing reproduces the cell": the
deterministic kernel dill reproduces, the linked executables do not, and the
other six members are produced by build steps this gate did not run.

## The dynamic-interface contract is measured, not asserted

[`probe/di.yaml`](probe/di.yaml) lists every host declaration this lane exposes,
in upstream's own schema. `gen_kernel` was run with
`--dump-detailed-dynamic-interface`, so what the annotator **applied** is
recorded beside what was **requested** (`evidence/di_applied_*.json`): both
`target` and `hostSuffix` appear under `callable`, alongside the SDK entries the
annotator discovers on its own.

`can-be-overridden` is deliberately absent and the file says why: that section is
built with `annotateStaticMembers: false`, so listing a top-level function there
would be a retention claim the toolchain silently ignores. Instance-member
retention is G3's question.

## The supported producer was not touched

Re-read off the disk after both builds, not asserted:

    engine tree         26acc7f4…  == frozen
    dart effective tree 7b04b01b…  == frozen
    out/host_release_arm64 (the cell's own bytes)  still present

The lane's own source is verified to equal the frozen lineage in the same pass.

## Acceptance

- [x] OFF and ON derive from identical frozen source except the intended flag — by construction, and refused otherwise
- [x] Every build input and artifact machine-readable and hashed — `g1_manifest.json`
- [x] Experiment patches banked — the set is empty, and why is recorded
- [x] Supported cell/selectors byte-for-byte untouched — re-verified after the builds
- [x] OFF normal AOT works, module loading refused (both shapes)
- [x] ON normal AOT works, dynamic-module path available
- [x] Positive dynamic-interface source and digest banked, plus what was actually applied

## What G2 inherits

1. Two substrates that differ in one flag, and a probe harness that already
   drives attach, load, and a plain AOT run in separate processes.
2. `ATTACH: pool len=1685, rewrote 0 slot(s) (other Code slots=117)` — the
   attach native already reports object-pool state. G2's shared-heap and
   identity questions will want that instrumentation, and it is worth reading
   before adding any.
3. The Dart-side call gap is unchanged and must stay the *known* answer: any G2
   probe whose conclusion depends on a Dart-side call reaching the new body is
   measuring the binder, which is not yet built.
