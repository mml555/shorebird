# STAGE20 — the "setter crash" is not about setters

Fork `a0ad21ce4c0` (+ two diagnostic commits), `gen_snapshot` built and stamped
by `m2/build_maot.sh`; every number below comes from that binary.

## 0. Two traps that had to be cleared first

Both would have produced a confident wrong answer, and neither announces
itself.

**A run without `--maot_install_trampolines` reports `rc=0`.** The flag is OFF
by default. A paired setter/getter run that omitted it returned `rc=0` for the
setter and looked like the crash had gone away. It had not: that run reported
`POST-DEDUP trampolines: installed=0 distinct=0` and `tramp=1 records=0` in the
relocation trace. The mechanism under test was absent. `rc=0` from a run in
which nothing was installed is not a pass; a flag matrix over
`--maot_dump_registry_precompile` and `--maot_trace_serializer` (8 runs, all
`rc=0`) would have "exonerated" the mechanism entirely.

**`Object::null()` is a real allocated heap object in this VM.** `object.cc`
allocates it first, of `Instance::InstanceSize()`, at `address + kHeapObjectTag`.
So a null `ObjectPtr` printed with `%p` shows a live-looking address. The
previous report flagged an apparent contradiction — a classifier printing
`registry=null` while the same expression printed `target=0x103488081` — and
refused to resolve it by picking the convenient reading. There was no
contradiction and no instrumentation bug: `0x103488081` **is** null. Independent
confirmation in the same trace: sibling calls print `dest_owner=0x107788081
dest_owner_desc=<null>`, the same address, for stub Code with a null owner.

A null destination therefore cannot be recognised from the pointer. The probe
now reads the static-call table slots instead.

## 1. The label is wrong — falsification in both directions

The getter subject is `String get v => 'OLD-ALPHA'`; the setter subject
interpolates. Their body Code differs by whether it makes static calls at all:
the getter's static-call target table is empty (`BEGIN ScanCallTargets` → `END`,
no iterations), the setter's has three pc-relative entries. So member kind and
"body makes static calls" were confounded. Two fixtures vary exactly that,
holding member kind fixed in each direction:

| arm | member kind | body makes static calls | result |
|---|---|---|---|
| `fixture_m5_setter` | setter | yes | crash `si_addr=0x4d50003f1b9` |
| `fixture_m5_getter` | getter | no | pass |
| `fixture_m5_callgetter` | **getter** | **yes** | **crash, identical address** |
| `fixture_m5_pursetter` | **setter** | **no** | **pass** |

The fault tracks static calls in a mutable body, not setters. Both crashing
arms show the same shape: the **last** entry of the mutable body's static-call
table has a null target, every earlier entry resolves to a stub, and the bogus
payload `0x4d50003f1c1` is byte-identical across runs whose every other address
differs — so it is not an address at all, but a constant word read out of the
null object.

## 2. Root cause, measured from both ends

`ProgramVisitor::WalkProgram` reaches a Function's Code only through
`Function::CurrentCode()` (`program_visitor.cc:173-174`). `InstallMaotTrampolines()`
makes the trampoline the declaration's `CurrentCode`, so the **body** Code leaves
program reachability and is held only by the registry's pins.

`Precompiler::ReplaceFunctionStaticCallEntries()` runs immediately after
installation and is what rewrites a pc-relative entry's Function target into a
Code target. It never sees the bodies. Their entries keep the Function and never
get a Code:

```
r1168 NULL_DEST fn_slot=Function '_interpolate@0150898': static.
      code_slot=<null> table_len=12
```

The binder's own counters, over the same kernel, one flag apart:

| | codes | entries | skipped_kind | bound |
|---|---|---|---|---|
| without trampolines | 1439 | 5296 | 206 | 1802 |
| with trampolines | 1439 | **5280** | 206 | **1798** |

Same code count — each body was swapped one-for-one for a trampoline. 16 fewer
entries = 4 declarations × 4 entries. 4 fewer bound = exactly the four
`_interpolate` calls. Counting can only imply that, so the pass also reports
which Code it reaches:

```
without:  BIND_VISIT owner=..._Alpha_set_v tramp=0 entries=12
with:     BIND_VISIT owner=..._Alpha_set_v tramp=1 entries=0
```

Direct observation: with trampolines the binder visits the trampoline and never
the body. The body is still serialized, because the registry pins it, so
`CodeRelocator` reaches it. `CodeRelocator::GetTarget`'s `ASSERT(target_.IsCode())`
is compiled out in this product build, so a null slot returns a null destination.
`Code::EntryPointOf` then reads Code's `instructions_` offset out of the much
smaller null Instance, gets a constant garbage word, and dereferences it —
`SEGV_ACCERR` at a fixed address, every run.

## 3. Exposure: this is a class, not an instance

The same hazard was already found and patched **in Dedup** — `program_visitor.cc`
carries the comment "once a declaration Function's CurrentCode is the trampoline,
its BODY Code is reachable only from these pins", and `MaotRegistry::CanonicalizeCodePins`
exists for it. Only that one pass was handled. Every program-walking pass
scheduled after `InstallMaotTrampolines()` skips declaration bodies:

```
MaterializeMutableAotRegistry();
InstallMaotTrampolines();            <-- bodies leave the walk here
FinalizeDispatchTable();
ReplaceFunctionStaticCallEntries();  <-- PROVEN: this is the crash
DropFunctions(); DropFields(); ...
DiscardCodeObjects();
ProgramVisitor::Dedup();             <-- partly compensated, for pin canonicalization only
RepinMutableAotImplementations();
PruneDictionaries();
```

`ProgramVisitor::Dedup` alone runs BindStaticCalls, NormalizeAndDedupCompressedStackMaps,
DedupPcDescriptors, DedupDeoptEntries, DedupCatchEntryMovesMaps, DedupUnlinkedCalls,
DedupCodeSourceMaps, DedupLists, DedupInstructions and AssignUnits, each of which
rewrites fields of every Code it visits. `CanonicalizeCodePins` canonicalizes the
pinned Code object; it does not perform those per-Code rewrites on a body.

Only the static-call binding has crashed so far, because it is the one that
produces a null dereference. The others fail quietly or not at all, which is
worse. This is stated as exposure, not as measured defect: only
`ReplaceFunctionStaticCallEntries` has been proven.

## 4. What this costs the established slices

`ARM64_AOT_INSTANCE_STAGE_REPLACEMENT_VERTICAL_SLICE` and
`ARM64_AOT_INSTANCE_GETTER_VERTICAL_SLICE` were both established on subjects
whose bodies are constant-string returns (`String v() => 'OLD-ALPHA'`,
`String get v => 'OLD-ALPHA'`) — empty static-call tables. Neither exercised
this path. What they measured stands: dispatch, install and execution genuinely
worked. What they cover is narrower than their names suggest, and the defect
sits inside the scope both nominally claim — a getter with a call in its body
crashes the snapshotter.

No disposition is changed here. Reported for ruling.
