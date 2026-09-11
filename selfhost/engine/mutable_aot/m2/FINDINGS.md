<!-- cspell:words MAOT precompiler dartaotruntime untagged patchability -->

# MAOT-2 (#66) — measured findings so far

Fork `maot/build`, in the order the findings below were measured:

| revision | what it carried |
|---|---|
| `38b31d7cd2e44ee188df324bd878dc736bccd1dd` | the first crossing of the compiler → runtime boundary |
| `f74a637790b802e025c79a9715afc02be028d37d` | binding, retention and the executable-body invariant |
| `c1a3f09af98df1d87bc52455a1a4b0750fd81964` | registry semantics, the self-test, and the two soundness fixes |
| `d267e5f9204d9fccc9ffdee9933938948f3bb398` | the descriptor pins the Code, not just the Function |

Tree `d13e92ab0166df8c560922d545cc4eacb214ce8c`. A branch is transport; the
commit and tree are identity.

## The architectural boundary is crossed

A #65 declaration id travels: Kernel → `vm.maot-declaration-id` metadata →
`KernelLoader` → `ObjectStore` root → AOT snapshot → `dartaotruntime`. The
runtime dump reports `runtime_mode: precompiled`, the release namespace
survives, and an entry is present. **No reconstruction step anywhere.**

## Two placement facts, both found by measurement

**ObjectStore roots must sit before `slow_tts_stub`.** `to_snapshot(kFullAOT)`
stops there; fields after it are never written. Appended at the end of the
field list, the registry was populated during the build and was *absent* from
the runtime — the exact "do not infer snapshot survival" failure. They must
*also* sit after the last field in `runtime_offsets_extracted.h`, or every
later offset shifts and `CheckOffsets` aborts `gen_snapshot`.

**The metadata cursor already adds `data_program_offset_`.** The in-loader
convention is the raw reader offset (`procedure_offset + correction_offset_`),
matching `ReadInferredType`.

## Binding is CORRECT — and the earlier diagnosis is retracted

The claim that app procedures bypass `LoadProcedure` was **wrong**, and the
correction matters. `FinishTopLevelClassLoading` does loop top-level procedures
into `LoadProcedure`; it is merely *deferred* for a normal registered library
rather than called from `LoadLibrary`. The app's procedures were misses that a
`head` truncation hid, not absences.

The real cause was two constructors with two offset conventions that agree only
on the eager path:

| loader | `correction_offset_` | `library_kernel_offset_` | reader sees |
|---|---|---|---|
| eager (whole program) | library start | library start | whole component |
| **deferred (per library)** | **0** | **library start** | **library slice** |

Top-level procedures of a registered library take the deferred path, so
`+ correction_offset_` yielded slice-relative offsets (71, 119, 182, 225, 261)
matching no mapping — and once *collided* with a mapping belonging to another
declaration, which is how a correct id came to be bound to
`Function 'get:offsetInBytes'`. `ReadInferredType`, the working precedent in the
same file, already used `+ library_kernel_offset_`.

Measured (`rel`/`corr`/`libstart`/`abs` side by side, per the four-fact rule):

    HIT rel=71  corr=0 libstart=19 abs=90  name=compute
    HIT rel=182 corr=0 libstart=19 abs=201 name=mutableTopLevel

All five procedures now pair with their own Function and carry the right
selection flag. Evidence: `evidence/binding_four_facts.txt`.

## Selection is now a retention reason

The illegal-CID failure is gone, and for the right reason. Selected
declarations are fed into the **ordinary precompiler worklist** rather than
pinned behind its back:

* `SeedMutableAotRoots()` before `Iterate()` —
  `AddFunction(fn, RetainReasons::kMutableAotDeclaration)` plus `AddTypesOf`,
  which is what gives `Widget` a legal cid;
* `MaterializeMutableAotRegistry()` after the drop phases — rebuild from
  `functions_to_retain_`, keeping **only selected** declarations.

The later seam is deliberate: the final registry should describe the final AOT
program, not influence pruning by being reachable during it. *GC-reachable* and
*legally retained by the precompiler* are different properties, and conflating
them caused the earlier failure.

`BindMaotDeclaration` is now the single seam, called from **both** authoritative
creation paths. Constructors come from `FinishClassLoading`, not
`LoadProcedure`, so wiring only the procedure path left a selected constructor
with no slot — 5 of 6, exactly the "basically complete" failure the gate must
refuse.

### Measured end to end

| | |
|---|---|
| selected bound, seeded, retained, materialized | 3 of 3, 0 dropped |
| unselected in final registry | **0** |
| duplicates | **0** |
| `gen_snapshot` / `dartaotruntime` | exit 0 / exit 0 |
| runtime mode | `precompiled`, namespace intact |
| each entry | `kind: AOT`, `version: 1`, distinct ABI |

Evidence: `evidence/runtime_registry_precompiled.json`.

## The retention blocker is CLOSED

`ConstantPragmaAnnotationParser.parsePragma()` calls
`target.isSupportedPragma(pragmaName)` **before** its switch, and `VmTarget`
accepted only `vm:` and `dyn-module:` prefixes. So `case
kMaotMutablePragmaName` was literally unreachable — the pragma looked fully
implemented and did nothing. This is the general trap worth keeping: **a parser
arm for an unsupported pragma name is dead code, and nothing says so.**

`VmTarget` now accepts **exactly** `kMaotMutablePragmaName`, not a `maot:`
prefix. We own one pragma, so one is accepted and anything else stays
fail-closed; a misspelled or future `maot:` name must not silently acquire
retention semantics. The constant is shared rather than duplicated — `pragma
.dart` depends only on the abstract `Target`, so there is no cycle.

### Measured through the whole chain

| stage | result |
|---|---|
| selected pre-shake | 4 |
| `selectedButAbsent` | `{}` — clean because retention worked |
| bound at VM load | 4 |
| seeded as retention roots | 4 |
| materialized from `functions_to_retain_` | 4 of 4, 0 dropped |
| runtime registry | 4, **exact set equality both directions** |
| unselected slots / duplicates | 0 / 0 |

`neverCalled` — selected, never called by the release — survives the Dart tree
shaker and carries **real compiled AOT code**. Selection changes what the
release considers live, which is the property #66 exists to establish.
`@pragma('maot:not-a-real-contract')` acquires no selection and no slot.

## A fixture defect that flattered the result

The earlier fixture used literals throughout, so TFA constant-folded every
selected declaration into `main`: three of four had **no standalone Code** while
still appearing correctly retained and registered. The registry looked right
and its AOT descriptors pointed at bodies the optimizer had dissolved. Values
are now opaque to the compiler.

## M2_RETENTION_BINDING_PROOF is met — and a retraction

**The earlier "2 of 4 lack standalone code" claim was wrong**, and how it was
wrong is the lesson: it came from `--print_instructions_sizes_to`, which is not
authoritative about VM state. Instrumenting the real checkpoints shows all four
selected declarations are queued — neither `AddFunction` early return fires —
retained, and carry `Code`:

```
seed ::cls:Widget::ctor:          possibly_retained_before=0 seen_before=0 queued=1
seed ::cls:Widget::method:compute possibly_retained_before=0 seen_before=0 queued=1
seed ::fn:mutableTopLevel         possibly_retained_before=0 seen_before=0 queued=1
seed ::fn:neverCalled             possibly_retained_before=0 seen_before=0 queued=1
materialize <all four>            retained=1 hascode=1
```

In the precompiled runtime every descriptor is `AOT v1` with a real body:

| declaration | size |
|---|---|
| `Widget` ctor | 32 B |
| `Widget.compute` | 68 B |
| `mutableTopLevel` | 56 B |
| `neverCalled` | 80 B |

Exact set equality both directions, 0 unselected slots, 0 dropped.

### Executability is fail-closed

Materialization now refuses a retained `Function` shell with no `Code`.
`kind=AOT, version=1, Function present, nothing to replace` is false-safe
state, and an AOT descriptor that cannot point at an executable release
implementation is not a descriptor.

`--maot_disable_seeding` is a permanent falsification control: it leaves
binding and registration intact while disconnecting selection from
`Precompiler::AddFunction`, and all four are then refused
(`retained=0 executable=0`, **0 of 4 materialized**). That proves retention is
a *consumed semantic decision* rather than an ObjectStore reachability side
effect — registry existence alone is insufficient.

Evidence: `evidence/retention_and_executability.txt`.

## Inlining is #68's problem, deliberately

Inlining is untouched. A caller may also hold an inlined copy; #66 only
guarantees there is a canonical standalone body for the slot to reference.
`OPTIMIZER_BYPASS_NOT_YET_PROVEN`, owned by **#68**.

## Superseded: remaining, and not forced

With non-foldable values, `neverCalled` (80 B) and `mutableTopLevel` (56 B)
have standalone code; `Widget.compute` and the `Widget` constructor are still
inlined at their single call site and have none.

**Retention is not the same as compilation to a replaceable standalone body.**
Whether an inlined selected declaration is a #66 gap or the #68 optimizer-bypass
concern is a real architectural question, and it is not decided here.

## Superseded: one selected declaration did not survive

`neverCalled` — selected but uncalled — is removed by the **Dart tree shaker**
before metadata attachment: an earlier boundary than the VM precompiler.
Making `maot:mutable` parse as an entry-point pragma did **not** retain it, and
a probe print proved why: `parsePragma` is never invoked with `maot:mutable` at
all, so the switch case is unreachable. Located, not guessed.

The discrepancy is no longer decorative. `recordSelectedAbsences` compares the
pre-shaking selected set against what received metadata and reports
`selectedButAbsent` for the gate to consume — a set holding the id of a deleted
declaration must fail the release closed rather than ship a namespace that
silently promises less than it claims.

## Superseded defects

1. ~~**The registry pins pre-precompilation `Function` objects.**~~ **FIXED**
   by the retention integration above. With the
   binding fixed, `gen_snapshot` now refuses:

       Unexpected object (Class with illegal cid, full-aot):
         Library:'package:m2app/app.dart' Class: Widget

   Only statics were registered before, so this never surfaced; class-owned
   Functions trip it. The association must still be established at load, but
   materialising the final registry may have to wait until the precompiler has
   settled which Functions survive. **Not fixed, and not guessed at** — this is
   the retention question, arriving early.

2. ~~**The constructor is not registered.**~~ **FIXED** by
   `BindMaotDeclaration` at the `FinishClassLoading` seam. The Dart side maps 6 declarations;
   the VM registers 5. `::cls:Widget::ctor:` is created by `LoadClass`, not
   `LoadProcedure`, so it needs its own join point. Recorded rather than
   papered over: a selected constructor would silently have no slot.

## Checkpoint status against M2_RETENTION_BINDING_PROOF

Met: constructor seam included; `AddFunction` consumed selection; owner class
retained; survives `DropFunctions`; unselected slots 0; duplicates 0;
`gen_snapshot` and `dartaotruntime` exit 0; `runtime_mode: precompiled`.

**Not met:** one missing selected id (`neverCalled`). The checkpoint is
therefore **not** reached, and the remaining #66 work — staging, ABI mismatch,
wrong namespace, duplicate/missing injection, measurements, the falsification
bank — stays gated behind it, as instructed.

## An ABI observation worth keeping

`Widget(this.n)` reports `p0/0` — zero positional parameters. That looks wrong
but is likely correct: `main` only ever calls `Widget(0)`, so `SignatureShaker`
drops the constant parameter. It argues that the ABI descriptor must be
computed **late**, after transforms, which is where it is computed. Worth
confirming explicitly when ABI gets its own falsification.

## Superseded: what was not yet claimed

Superseded on 2026-09-11 by the sections below. The reasoning above stands as
written; it was accurate when the registry existed but its semantics, its
falsification bank and its verdict did not.

## Two soundness defects, both found by the program that selects nothing

The fixture had a `@pragma('maot:mutable')` on it from the first day, so every
measurement until now was taken on a program that used the feature. The cost
measurements needed a baseline, so the gate grew a **control**: the identical
source with every pragma removed. The control did not build.

```
Unexpected object (Class with illegal cid, full-aot):
  Library:'package:m2app/app.dart' Class: Widget
```

The discriminating test is short and worth stating, because "the fixture is
odd" was the comfortable reading: **the stock, non-MAOT `gen_snapshot` from
Route B compiled that exact kernel file, 840,184 bytes, exit 0.** The MAOT
`gen_snapshot` aborted on it. The defect was mine, and a release that never
adopted the pragma is the common case, not an edge case.

### Defect 1 — `Clear()` released nothing

```cc
storage.SetLength(0);   // does not release anything
```

A `GrowableObjectArray` keeps its backing `Array` at full capacity, and every
slot past the new length still holds the old pointer. **Both the GC and the
snapshot serializer walk the backing array, not the logical length.** So a
`Function` "cleared" this way stayed reachable from an `ObjectStore` root. The
precompiler resurrected `Function`s whose owner `Class` `DropClasses()` had
already removed from the class table, and serialization then found a class
with an invalidated cid.

`Clear()` now replaces the storage outright. It is the array that has to go,
not its length.

This also means the earlier shipped registries carried stale `Function`
pointers in the tail of the backing store. `registry_array_slots` is now
exactly `entries × slots_per_entry` (40 for 4), which is the mechanical way to
see that there is no tail.

### Defect 2 — materialization ran after the drop phase

`MaterializeMutableAotRegistry()` was called after `DropLibraries()`, with
this comment:

> the final registry should describe the final AOT program, not influence
> pruning by being reachable during it.

The intent was right and the code did not achieve it. Kernel loading registers
**every** declaration it sees, selected or not, so for the whole drop phase the
registry was an `ObjectStore` root holding exactly the `Function`s the
precompiler was removing. Those references do not make a `Function` *retained*
— `DropFunctions()` rebuilds each class's function array from
`functions_to_retain_` — but they keep the objects *reachable*, which is all
the serializer needs.

It now runs immediately after `TraceForRetainedFunctions()`. Every input is
final there: selection came from the kernel metadata, retention is
`functions_to_retain_`, and code attachment finished with the compilation loop
above it. Afterwards the registry references only `Function`s that are being
kept, which makes the original comment true rather than aspirational.

Both fixes are required. Either alone leaves the crash: without the move the
registry still roots everything during the drop, and without the `Clear()` fix
the reduction releases nothing.

## A gate defect, caught by a falsification arm rather than by a test

`F10` failed in a run where the implementation was correct. The cause was not
in the fork:

```bash
ninja -C out/maot_host gen_snapshot dartaotruntime 2>&1 | tail -5; echo "exit=$?"
```

`$?` is `tail`'s status. Ninja had failed (`vpython3: command not found`), the
binary was seven minutes stale, and the gate measured a program that was not
the one it named. Nothing in the lane would have noticed; the arm noticed.

The gate now refuses to run against a binary older than a MAOT source that is
**linked into that binary** — `precompiler.cc` is compiled into `gen_snapshot`
only, and comparing it against `dartaotruntime` would report staleness that
cannot exist. `F21` asserts the guard both ways: silent now, and firing on
both binaries against a source dated one hour ahead.

## MAOT-0 re-derivation: content and stamp are different facts

Re-running the #63 gate reported `DIFFERS` — "the frozen universes no longer
describe this tree". They do. Both universes' **entries are byte-identical**;
the only difference in either file was one token:

```
provenance.dart_tree_head
  now    f74a637790b802e025c79a9715afc02be028d37d   (R3 borrowed for MAOT-2)
  freeze 9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c
```

Whole-file byte equality conflated two different claims. A change in the
**content** means the frozen matrix no longer describes the language surface,
and it is blocking. A different **commit stamp** is an observation — and when
the content matches it is a *wider* statement than the freeze made alone: the
universe is unchanged across both commits.

`lib/reverify_universe.py` now separates them, normalising only that one token
and only when both ends are well-formed 40-hex, so a missing or malformed head
cannot be normalised into agreement. The content assertion stays blocking; the
tree is recorded as a note and kept out of the assertion count, so
"N checked: P pass, F fail" remains an accounting of checks.

## A Function is not an implementation

Reviewing #66's own acceptance list turned up two required falsifications with
nothing behind them:

> - lookup that accidentally succeeds by function name while declaration IDs
>   differ;
> - a replacement mutating a `Function`/`Code` object directly while registry
>   state remains old.

The first needed a fixture change, not a code change: the program had no two
declarations sharing a VM `Function` name, so there was nothing a name-keyed
lookup could have confused. `compute` now exists both as a top-level function
and as `Widget.compute`, and `L01` refuses to pass when no such pair is
present — an arm that could not run is not an arm that passed.

The second was a design gap. The issue asks a descriptor to hold a
"reference to executable implementation", and the descriptor held a
`Function`. `Function::CurrentCode()` is a mutable field, so a descriptor
holding only the `Function` follows whatever code is attached to it later, and
"the registry still says AOT v1" is indistinguishable from correct state. Each
entry now pins the `Code`, and `CountDivergedImplementations()` compares the
pin against what the `Function` currently points at.

Pinning had to move after dedup. Materialization runs before the drop phase,
which is before `ProgramVisitor::Dedup`, so the pinned `Code` can be one dedup
later merges away — and holding the pre-dedup object keeps two `Code`s with
identical `Instructions` reachable, which the serializer refuses outright:

```
RELEASE_ASSERT(!FLAG_precompiled_mode)   // app_snapshot.cc:2787
```

`RepinMutableAotImplementations()` runs once after dedup. Not a way around
the assertion: before dedup, the object the descriptor is supposed to name
does not exist yet.

### The arm that tested the wrong object

`X02` first reported "divergence was not observed". The implementation was
right; the arm was wrong. It chose its subject before the arms that mutate
state ran, and by the time it swapped that `Function`'s code, `S04` had
already promoted a staged replacement — the entry pointed somewhere else
entirely, so the swap changed nothing any descriptor was watching. It now
selects its subject at the moment it runs.

The instinct on seeing a red arm is to doubt the implementation. Here the
implementation was fine and the measurement was stale, which is the same class
of mistake as the stale binary above: in both cases the lane was looking at
something other than the thing it named.

## What is NOT claimed

No body replacement, no call-site redirection, no execution of `PATCH_CODE`.
A caller may hold an inlined copy of a selected body; proving it cannot bypass
the slot is #68. Transactions are single-entry and test-only — #71 owns atomic
multi-declaration transactions. The registry is read by no call site; #67 owns
that.
