# `--route_b_untabled_overrides`: dispatch-table calls made patchable (host)

Measured 2026-11-14 on the Mac's host release build
(`out/host_release_arm64_ddm`), Dart lineage branch
`selfhost/route-b-untabled-overrides` at `7b2b039e`. Host only: no iOS cell, no
device patch and no frame-time number yet.

## What it changes

A dispatch-table call loads a raw entry point and sets up neither the callee's
`Function` (`R0`) nor an arguments descriptor (`R4`), so `AttachBytecode` cannot
redirect it, and the framework reaches every `Widget.build` that way. Under the
flag, a regular method implemented outside `dart:` and `package:flutter/` gets
no table row for its selector. Its call sites become a cid-check chain of direct
calls (few receivers) or a switchable call (many), and both reach a patched
body. The VM side is three changes, described in
[`../../README.md`](../../README.md) ("Third option").

## 1. Call-form inventory

`selfhost/engine/route_b/inventory/run_inventory.sh`, same binaries, two arms:

| form | `--patchable_static_calls` | `+ --route_b_untabled_overrides` |
|---|---|---|
| top-level static | PATCHABLE | PATCHABLE |
| static method | PATCHABLE | PATCHABLE |
| instance method, monomorphic | PATCHABLE | PATCHABLE |
| getter | PATCHABLE | PATCHABLE |
| polymorphic, two receivers | not reachable | **PATCHABLE** |
| dynamic instance call | PATCHABLE | PATCHABLE |
| megamorphic, eight receivers, first link | not reachable | **PATCHABLE** |
| the same after the site went megamorphic | not reachable | **PATCHABLE** |
| control: a receiver the patch was not attached to | untouched (correct) | untouched (correct) |

The megamorphic case calls the patched receiver through the site FIRST, so the
site's first link targets the patched function, and asks again after every
receiver has gone through it.

## 2. The runtime fix is required

With the compiler change but without the
`PrologueNeedsArgumentsDescriptor` change (gen_snapshot and dartaotruntime both
rebuilt, since the snapshot version hash covers `object.cc`):

```
FORM megamorphic-first: PATCHED (NEW-part3)
si_signo=Segmentation fault: 11(11), si_code=SEGV_ACCERR(2), si_addr=0x1f
```

The first call resolves through the runtime and reaches the bytecode. The
runtime then links the site monomorphic to the function's current code, which
is the InterpretCall stub, and the second call enters that stub with the
receiver in `R0`.

## 3. A real Flutter app

`app.dill` of a counter app (`package:sbrel`), `--deterministic
--patchable_static_calls`, with and without the flag:

| | without | with the flag, compiler change only | with all three changes |
|---|---|---|---|
| snapshot bytes | 4,902,824 | 4,564,376 (−6.9 %) | 4,919,104 (**+0.33 %**) |
| instructions entries | 8,348 | 7,546 | 8,351 |
| `MyApp.build`, `_MyHomePageState.build`, `MyHomePage.createState` code | present | **missing** | present |

The middle column is why `NeedsMonomorphicCheckedEntry` is part of the change.
Without it the compiler gives these methods neither a receiver check nor a
place in their class's function array, since it assumes every non-dynamic call
goes through the table. Their code was dropped, about 800 functions in all.
The inventory could not see this, because its targets are all `vm:entry-point`,
which counts as a dynamic caller. The same state also crashed the snapshot
profile writer on dead entries of weakened canonical tables (`Request to create
artificial node for object with cid 94`); with the methods kept, the profile
builds unchanged.

The six entries that differ between the first and last columns are
identical-code folding picking a different representative name (`Builder.build`,
`KeyedSubtree.build`, `_TitleState.build` and three getters/closures).

## 4. Release probe, revision 2

`release_probe.dart` against each arm's profile:

| target | without | with the flag |
|---|---|---|
| `MyApp.build` | ZERO | **GREEN**, 2 switchable sites (`StatelessElement.build`, `StatefulElement.build`) |
| `_MyHomePageState.build` | ZERO | **GREEN**, 2 switchable sites |
| `MyHomePage.createState` | ZERO | **GREEN**, 1 switchable site (`new StatefulElement`) |
| `_MyHomePageState._incrementCounter` | ZERO | ZERO (reached through a tear-off; a separate form) |

The first run reported ZERO for both `build()` methods even with the flag.
Revision 1 told a target's own code from a caller by NAME, and the framework's
callers are named `build` too. Revision 2 decides it by identity (the `Code`'s
`owner_`), in the switchable path and in the direct-call path alike. The direct
path had the same flaw: a cid-check chain over two `pick()` implementations sits
in a function named `pick`.

`probes/p41_release_probe_gate.sh` (PASS=36 FAIL=0) now has a second specimen
compiled with the flag. Its `_P3.render` (eight receivers, switchable) and
`_DuoA.pick` (two receivers, direct calls) are ZERO through the table and GREEN
untabled. The `selfname` mutation puts the name test back and both go ZERO.

## Not yet

- An iOS cell built from this Dart revision, and a `build()` patch on the iPhone.
- Frame time on the device: the flag turns some table calls into switchable
  calls, which cost more per call once megamorphic.
- `routeBReleaseProbeRevision` in the CLI stays 1 until that cell is the pin.
