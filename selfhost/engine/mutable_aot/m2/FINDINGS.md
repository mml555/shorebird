<!-- cspell:words MAOT precompiler dartaotruntime untagged patchability -->

# MAOT-2 (#66) — measured findings so far

Fork `maot/build` = `38b31d7cd2e44ee188df324bd878dc736bccd1dd`.

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

## What is NOT yet claimed

No body replacement, no call-site redirection, no execution of `PATCH_CODE`.
The 14 required behaviours, the 12 falsification arms, the measurements and the
derived verdict are not done. `RUNTIME_IMPLEMENTATION_REGISTRY_ESTABLISHED` is
**not** claimed.
