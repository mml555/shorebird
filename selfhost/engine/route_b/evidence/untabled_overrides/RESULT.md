<!-- cspell:words untab -->
# `--route_b_untabled_overrides`: dispatch-table calls made patchable

Measured 2026-11-14 on the Mac's host release build
(`out/host_release_arm64_ddm`), Dart lineage branch
`selfhost/route-b-untabled-overrides` at `4c9f79f2`, and on 2026-11-15 on an
iPhone 7 (iOS 15.8) from a local test cell built from the same revision
(sections 7 and 8). No frame-time number yet.

## What it changes

A dispatch-table call loads a raw entry point and sets up neither the callee's
`Function` (`R0`) nor an arguments descriptor (`R4`), so `AttachBytecode` cannot
redirect it, and the framework reaches every `Widget.build` that way. Under the
flag, a regular method implemented outside `dart:` and `package:flutter/` gets
no table row for its selector. Its call sites become a cid-check chain of direct
calls (few receivers) or a switchable call (many), and both reach a patched
body. Besides the table change the VM side has four, described in
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
| megamorphic, eight receivers, no `vm:entry-point` on the method, first link | attach finds no method | **PATCHABLE** |
| the same after the site went megamorphic | attach finds no method | **PATCHABLE** |
| control for that case | attach finds no method | untouched (correct) |
| the same with an `int` parameter, first link and megamorphic | attach finds no method | **PATCHABLE**, argument intact |
| the same with a `double` parameter, first link and megamorphic | attach finds no method | **PATCHABLE**, argument intact |
| controls for those two | attach finds no method | untouched (correct) |

The megamorphic case calls the patched receiver through the site FIRST, so the
site's first link targets the patched function, and asks again after every
receiver has gone through it.

The `noentry` rows were added after the failure in section 5, the `int` and
`double` rows after the one in section 6. Their patched bodies echo the
argument, and a row whose echo is wrong reads `WRONG ARGUMENT`, not PATCHABLE. Only the class
is an entry point there, as the attach native needs to find it by name. Without
the flag the method is reached only through the table, so nothing keeps it in
its class's function array and the attach reports `member paint not found`.

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

| | without | with the flag, compiler change only | with all the changes |
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
| `MyApp.build` | ZERO | **GREEN**, 2 switchable sites (in `StatelessElement.build` and `StatefulElement.build`) |
| `_MyHomePageState.build` | ZERO | **GREEN**, 2 switchable sites |
| `MyHomePage.createState` | ZERO | **GREEN**, 1 switchable site (`new StatefulElement`) |
| `_MyHomePageState._incrementCounter` | ZERO | ZERO (reached through a tear-off; a separate form) |

A switchable site names a selector, so the count is per selector:
`StatefulElement.build` calls `State.build` and can never reach `MyApp.build`,
yet both sites count for both targets. That is the probe's documented direction
(it reports a site that may never run the target, never the reverse).

The first run reported ZERO for both `build()` methods even with the flag.
Revision 1 told a target's own code from a caller by NAME, and the framework's
callers are named `build` too. Revision 2 decides it by identity (the `Code`'s
`owner_`), in the switchable path and in the direct-call path alike. The direct
path had the same flaw: a cid-check chain over two `pick()` implementations sits
in a function named `pick`.

`probes/p41_release_probe_gate.sh` (PASS=42 FAIL=0) now has a second specimen
compiled with the flag. Its `_P3.render` (eight receivers, switchable) and
`_DuoA.pick` (two receivers, direct calls) are ZERO through the table and GREEN
untabled. The `selfname` mutation puts the name test back and both go ZERO.

Switchable sites count only under a revision-2 binding, which the CLI writes
exactly when it passed the flag. Bound at revision 1, the flagged specimen's
`_P3.render` is ZERO, and a mutant that ignores the binding's revision turns it
GREEN. Synthetic rows put an `UnlinkedCall` in an unowned pool and in a
tear-off's pool; both stay ZERO, and each has a mutant that counts it.

## 5. Two runtime failures the inventory could not see

Every inventory target is a `vm:entry-point`, and the pragma does more than
keep a function: TFA treats an entry point as called dynamically. Two programs
without it call methods through eight-receiver sites and run on
`dartaotruntime`:

| program | flag off | flag on, `7b2b039e` | flag on, fixed |
|---|---|---|---|
| [`plain_receivers.dart`](plain_receivers.dart): plain methods | `OK 192` | `NoSuchMethodError`, receiver an `int` | `OK 192` |
| [`descriptor_params.dart`](descriptor_params.dart): optional, named, type parameters | `OK 480` | `NoSuchMethodError` | `OK 480` |

Two causes, two fixes:

- **The calling convention.** In AOT a method TFA never sees called dynamically
  takes its first parameters, the receiver included, in registers, and its
  callers fill them. A switchable call passes everything on the stack:
  `EmitInstanceCallAOT` loads the receiver from the stack slot, which the
  caller never wrote. The runtime then resolved the selector against whatever
  was there (here an `int`). `Function::MaxNumberOfParametersInRegisters` now
  answers 0 for an untabled selector, and since the interface target shares the
  selector, callers and implementations agree. Every `build()` in the counter
  app had this shape; its release probe was GREEN because the probe reads call
  sites, not whether they run.
- **Pruning.** `NeedsMonomorphicCheckedEntry` answers false before reaching the
  new check for a method whose prologue needs an arguments descriptor, so it was
  never filed as called dynamically and was pruned from its class's function
  array, where the runtime looks the selector up. `Precompiler::AddTypesOf` now
  files every untabled implementation, whatever its prologue.

To reproduce: `gen_kernel --aot` the file, then `gen_snapshot
--patchable_static_calls --route_b_untabled_overrides`, then `dartaotruntime`.

The real app's numbers in sections 3 and 4 were taken again with both fixes.
Its kernel came from the Flutter toolchain and names the base Dart revision, so
the rebuilt `gen_snapshot` refused it until its SDK hash was set to the null
value (`0000000000`), which the VM accepts from any revision.

## 6. Unboxed parameters

TFA passes an `int` or `double` parameter unboxed to a method it never sees
called dynamically, and the bytecode interpreter takes boxed values only. The
review of this change attached a patch to such a method through an
eight-receiver site:

| target | release-style dynamic interface | none, before the fix | none, fixed |
|---|---|---|---|
| `paintn(int)` | patched, `NEW-41` / `NEW-42` | segfault, `si_addr=0x28` | patched, `NEW-41` / `NEW-42` |
| `paintd(double)` | patched, `NEW-1.5` / `NEW-3.5` | patched, `NEW-2304717109306851328` | patched, `NEW-1.5` / `NEW-3.5` |

A release was never exposed: `gen_dynamic_interface.dart` makes every app
library `callable`, which TFA treats like an entry point, so its values stay
boxed. But the flag lets the attach native find any untabled method by name,
including ones no interface covers, and the AOT runtime has no record of
which parameters a compiled method takes unboxed, so the native cannot refuse
one. `Precompiler::BoxRouteBUntabledSignatures` instead clears the unboxing of
every untabled selector before anything compiles. TFA decides unboxing per
selector, and the pass covers every method of the selector, interface targets
included, so callers and implementations still agree. The counter app's
snapshot is unchanged at 4,919,104 bytes, since its `build` methods take
objects.

The inventory's `int` and `double` rows cover this. With the pass's call
commented out and gen_snapshot rebuilt, the `int` rows end in a segfault
(`si_addr=0x28`, so no FORM line, which reads INCONCLUSIVE) and the `double`
rows read `WRONG ARGUMENT` (`NEW-2304717109306851328`); with it, all six pass.

## 7. A `build()` patch on the iPhone

A local test cell (`ios-release` and the host tools rebuilt from `4c9f79f2`,
SDK hash null as in section 5) and a CLI at this branch. The app is
`flutter create` with one widget whose `build()` carries no pragma, so the
framework reaches it only through what was a dispatch-table call:

```dart
class Label extends StatelessWidget {
  const Label({super.key});

  @override
  Widget build(BuildContext context) {
    final text = 'UNTAB-V1';
    debugPrint('untab-label $text');
    return Text(text, style: const TextStyle(fontSize: 48));
  }
}
```

`shorebird release ios` and `shorebird patch ios` both ran with
`-- --extra-gen-snapshot-options=--route_b_untabled_overrides`. The release
probe of the app's first release was GREEN for `Label.build`, one switchable
site (`probe_revision: 2`). The patch changes the one string:

| launch | device log | screen |
|---|---|---|
| base release | `no active patch`, `untab-label UNTAB-V1` | UNTAB-V1 |
| after publishing patch 1, second launch | `ROUTEB: activated Label.build in package:untab/main.dart before main`, `applied 1/1 targets`, `Launch success for patch 1`, `untab-label UNTAB-V2` | **UNTAB-V2** |
| after rolling patch 1 back, first launch | still `UNTAB-V2`; the check returns `rolled_back_patch_numbers: [1]` | UNTAB-V2 |
| second launch | `Prepared boot of the base release`, `untab-label UNTAB-V1` | UNTAB-V1 |

The first attempt at this, on the same cell, crashed at boot. Section 8 is why.

## 8. Framework names a patch uses

```
bytecode_reader.cc: 1173: error: Unable to find class BuildContext in
Library:'package:flutter/src/widgets/framework.dart'
```

The patch's body was the release's own, one string changed, but its signature
names `BuildContext`, and its body names `Text`, `TextStyle` and `debugPrint`.
The loader finds every class and member a patch names by name, and the
release's interface had kept the app's library and four `dart:core` members,
nothing from Flutter. Earlier device patches only replaced top-level helpers
that named nothing outside the app, so none of them hit this.

`gen_dynamic_interface.dart` now also keeps what the app's own code uses
outside the app: each class as `can-be-used-as-type` (findable by name, members
untouched) and each member it calls, reads or names in a constant as a
`callable` member item. Constants count for their fields, private ones
included, because the loader looks up every field of an instance constant:
`const TextStyle(fontSize: 48)` names all 26 fields of `TextStyle`, including
`_package`. The walk reads the non-AOT kernel, which is what the source says
(the prepass has had TFA drop the `style:` argument and the constant with it),
and takes `dart:` references from the prepass, since the non-AOT kernel does
not carry the SDK. `--no-framework-uses` turns it off.

Its cost on this app, same kernel inputs, iOS `gen_snapshot` ELF:

| interface | named members | snapshot bytes |
|---|---|---|
| before: the app library and four `dart:core` members | 4 | 4,490,208 |
| + framework classes as types | 4 | 4,505,504 (+0.34 %) |
| + members the app calls | 9 | 4,511,800 (+0.48 %) |
| + fields named by constants (what ran in section 7) | 120 | 4,547,856 (**+1.28 %**) |

The fields are most of it: retaining a field keeps it, and its value, where
TFA would have dropped a field nothing reads. A loader that skipped a constant's
fields the release does not have would need only the first two rows, and
nothing in the release can read such a field.

One kind of member is left out: a `dart:` instance member the app reaches
through code, such as `Iterable.iterator`. Such a member is implemented across
the SDK, and declaring it callable keeps every implementation.
[`probes/fw_use_binding.sh`](../../probes/fw_use_binding.sh) measured it on the
host, with `package:crypto` in Flutter's place and a body naming `sha256`,
`convert` and `Digest`, which the target already uses:

| interface | the crypto body | snapshot bytes |
|---|---|---|
| `--no-framework-uses` | `Unable to find library package:crypto/src/sha256.dart` | 983,776 |
| framework uses, `dart:` instance members included | binds | 1,084,408 (+10.2 %) |
| framework uses, the default | binds | 985,824 (**+0.21 %**) |

The Flutter app above reaches no `dart:` instance member through code, so its
interface is the same either way, byte for byte.

The cost of leaving them out: a patch that calls an SDK instance member by
interface (`list.add`, `text.isNotEmpty`) fails at load, as it did before this
change. The probe's first body used `.isNotEmpty`, which the target never
calls, and died with `Unable to find function get:isNotEmpty in Library:'dart:core'
Class: String`. A string `==` binds without it. So does a patch naming a
framework member the release's code never used: it still fails at load, and
the analyzer does not refuse it yet.

## Not yet

- Size and frame time on a real app. The flag turns table calls into switchable
  calls, which cost more per call once megamorphic, and a shared selector
  carries SDK and framework calls along with the app's. One counter app is not
  a measurement of that.
- Patch and roll back a method with optional, named or type parameters
  through a switchable site. Section 5 shows such calls run; it does not
  attach a patch to one.
- Activation timing. The runtime change assumes Route B activates before any
  switchable site links. A site linked monomorphic to the original code before
  activation would keep calling the unpatched body, silently. Section 7
  activates before `main`, so it does not test this.
- A cell anyone can install. Section 7's cell is local, and a published cell
  needs this Dart revision built into the engine with a matching SDK hash.
- The analyzer refusing a patch that names a framework class or member the
  release did not keep.
- A way to keep an SDK interface member findable by name without keeping every
  implementation, so a patch can call `list.add`.
