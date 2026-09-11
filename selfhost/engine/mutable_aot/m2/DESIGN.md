<!-- cspell:words MAOT precompiler dartaotruntime cipd Fuchsia untagged Untagged patchability -->

# MAOT-2 (#66) — the compiler → runtime binding

**Status: implemented.** This document describes what shipped, not what was
planned; where the plan and the implementation diverged, the divergence and its
cause are recorded rather than edited out. FINDINGS.md carries the measurements
and the defects.

Originally inspected at Dart fork `bc3d67971e59b4a596c11b6299c737a73a83595a`
(tree `2a721855e670b000b6b91e5732450a57ed214bb1`); implemented across
`38b31d7c`, `f74a637`, `c1a3f09a` and `d267e5f9`.

Two things in the original plan turned out to be wrong, and both are corrected
below rather than quietly dropped:

1. the registry was to be a **new heap class with its own serialization
   cluster**. It is a `GrowableObjectArray` rooted in the `ObjectStore`.
2. the descriptor was to hold **a direct `FunctionPtr`** as "the
   implementation". A `Function` is not an implementation —
   `Function::CurrentCode()` is mutable — so the descriptor pins the `Code`
   as well.

## The rule this design exists to obey

> `Kernel logical declaration → #65 DeclarationId → compiler-carried binding →
> exact runtime Function → registry slot`, with **no reconstruction step after
> AOT**.

Nothing here may scan finished code, match Functions by name, read addresses or
pool offsets, infer class ids, or pair a sidecar manifest with a runtime
guessing step. The compiler must know the correspondence *while Kernel identity
is still authoritative*, and hand it to the runtime.

## Finding 1 — the carrying mechanism already exists, and is first-class

`pkg/vm/lib/metadata/` holds nine `MetadataRepository<T>` implementations —
`closure_id`, `direct_call`, `inferred_type`, `procedure_attributes`,
`table_selector`, `unboxing_info`, `loading_units`,
`obfuscation_prohibitions`, `unreachable`. Each declares a `tag`, a
`Map<TreeNode, T>` and `writeToBinary`/`readFromBinary`; the payload is
serialized **into the dill**, and the VM reads it during kernel loading through
a matching `MetadataHelper` subclass in
`runtime/vm/compiler/frontend/kernel_translation_helper.h`.

That is precisely the shape #66 needs, and it is the mechanism the VM already
trusts for compiler-computed facts. `vm.closure-id` is the closest analogue: a
*persistent identity* assigned by the front end and consumed by the VM.

**Decision: the binding travels as a new metadata repository,
`vm.maot-declaration-id`, not as an out-of-band file.**

## Finding 2 — a `Function` field would not survive, and this is mechanical

The obvious representation is a new field on `Function`, alongside
`kernel_offset_`. It does not work:

```
runtime/vm/raw_object.h:1323   #if !defined(DART_PRECOMPILED_RUNTIME)
runtime/vm/raw_object.h:1324     uint32_t kernel_offset_;
```

`kernel_offset_` — the existing per-`Function` kernel-derived scalar, the
natural precedent — **is compiled out of the AOT runtime.** Kernel-associated
`Function` fields exist in the precompiler and are gone in the artifact that
actually runs. A DeclarationId stored that way would be present exactly where
it is not needed and absent exactly where it is.

This is why the design is a **dedicated table rather than a widened
`Function`**, and the reason is mechanical rather than aesthetic. It also
disposes of a tempting shortcut: "store the id on the Function and look it up
at runtime" cannot be made to work without reintroducing a reconstruction step.

Widening `Function` unconditionally would also cost a pointer on *every*
function in the program, when the registry needs an entry only for selected
declarations.

## The chosen representation

```
  pkg/kernel/lib/maot_identity.dart        #65: computes DeclarationId
            │
            ▼
  pkg/vm/lib/metadata/maot_declaration_id.dart
            │   MetadataRepository<MaotDeclarationIdMetadata>
            │   tag: vm.maot-declaration-id
            │   payload: declaration id, selection flag, ABI descriptor
            │             (Kernel/source-call shape only — see ABI below)
            ▼
  <dill>                                   binding is IN the kernel binary
            │
            ▼
  runtime/vm/compiler/frontend/kernel_translation_helper.{h,cc}
            │   MaotDeclarationIdMetadataHelper reads it during kernel load,
            │   inside gen_snapshot, while Kernel identity is authoritative
            ▼
  runtime/vm/kernel_loader.cc              BindMaotDeclaration() at TWO seams:
            │                              LoadProcedure and constructor
            │                              creation. Registers EVERY
            │                              declaration it sees — selected or
            │                              not — because the seam is the
            │                              loader, not a filter.
            ▼
  runtime/vm/maot_registry.{h,cc}          GrowableObjectArray of 13-slot
            │                              entries, rooted in the ObjectStore
            ▼
  runtime/vm/compiler/aot/precompiler.cc   SeedMutableAotRoots() makes
            │                              selection a retention root, then
            │                              MaterializeMutableAotRegistry()
            │                              reduces the table to selected +
            │                              retained + executable, and
            │                              RepinMutableAotImplementations()
            │                              re-pins Code after Dedup
            ▼
  dartaotruntime                           deserialized with the snapshot,
                                           zero reconstruction
```

### The descriptor

```
DeclarationId                the identity, always, and the only key
  └── descriptor
        ├── Function         the declaration/runtime-function relationship
        ├── pinned Code      the executable implementation actually shipped
        ├── ABI              Kernel/source-call shape, from the front end
        └── call convention  final AOT shape, from the precompiler
```

The original plan said "the registry holds a direct `FunctionPtr`" and called
that the implementation payload. That was the design error #66's own
falsification list exposed: `Function::CurrentCode()` is a mutable field, so a
descriptor holding only the `Function` follows whatever code is later attached
to it and can never report that it has been bypassed. The pinned `Code` is
what makes divergence observable; `CountDivergedImplementations()` compares
them.

Neither half uses an address as identity. The key is the DeclarationId string;
the `Code` is compared for object equality against what the `Function` points
at, never parsed for a location.

### Why a GrowableObjectArray and not a new heap class

The plan called for a new heap class, a class id, and a serialization cluster
in `app_snapshot.cc`. `Array`, `String`, `Function` and `Code` already
serialize, so the array costs nothing in serialization work and the entry
layout stays private behind accessors. **Storage is not the contract**: the
field offsets are private, and every consumer goes through the API, so #71 can
replace the storage and the transaction model without rewriting callers.

### Why the ObjectStore root

The registry must be reachable from a GC root that the snapshot serializer
traces, or it is dropped as garbage during precompilation. The `ObjectStore` is
how the VM roots per-isolate-group singletons and is what the existing clusters
in `app_snapshot.cc` (57 of them) expect.

### Files this actually touches

| file | change |
|---|---|
| `pkg/kernel/lib/maot_identity.dart` | #65, reused unchanged |
| `pkg/vm/lib/metadata/maot_declaration_id.dart` | the repository, ABI descriptor, type renderer |
| `pkg/vm/lib/transformations/type_flow/transformer.dart` | collect selection pre-shake, index post-transform |
| `pkg/vm/lib/transformations/pragma.dart` | `maot:mutable` parses to an entry-point pragma |
| `pkg/vm/lib/modular/target/vm.dart` | `isSupportedPragma` accepts exactly `maot:mutable` |
| `runtime/vm/compiler/frontend/kernel_translation_helper.{h,cc}` | the `MetadataHelper` |
| `runtime/vm/kernel_loader.{h,cc}` | `BindMaotDeclaration` at both seams |
| `runtime/vm/maot_registry.{h,cc}` | the registry, staging, self-test |
| `runtime/vm/object_store.h` | two roots, inside the Full-AOT cutoff |
| `runtime/vm/compiler/aot/precompiler.{h,cc}` | retention root, materialization, re-pin |
| `runtime/vm/dart.cc` | dump/self-test invocation |
| `runtime/vm/vm_sources.gni` | the new sources |

Never touched, and not a serialization cluster: `app_snapshot.cc`,
`class_id.h`, `object.h`, `raw_object.h`. The plan's table was wrong about all
four.

Deliberately **not** touched in #66: any call-site lowering, dispatch,
optimizer, or deoptimization path. Those are #67 and #68.

## Selection semantics

> "Do not use *whatever happened to survive AOT*. Selection must be
> compiler-owned before elimination/optimization."

Selection is computed on the **Kernel component**, before the precompiler's
tree-shaker runs, and recorded in the metadata payload as an explicit flag.
Consequences the contract must guarantee:

* a selected declaration is registered exactly once;
* a selected declaration **may not be eliminated** — selection is a retention
  root, so "it was tree-shaken" cannot silently reduce the registry;
* an unselected declaration never acquires a slot;
* a selected-but-unreached declaration is still registered, because #68 needs
  dead-but-mutable declarations to remain representable.

For #66 the selected set is an explicit, named subset driven by the fixture,
not "every declaration" — but the payload carries the flag per declaration, so
widening the selection later is a policy change and not a representation
change.

### How selection is spelled, and the gate it nearly died behind

`@pragma('maot:mutable')`. It reaches the parser only because `VmTarget`
accepts it by **exact match**:

```dart
bool isSupportedPragma(String pragmaName) =>
    pragmaName.startsWith("vm:") ||
    pragmaName.startsWith("dyn-module:") ||
    pragmaName == kMaotMutablePragmaName;
```

`ConstantPragmaAnnotationParser.parsePragma()` checks `isSupportedPragma`
*before* reaching its switch, so the `maot:mutable` case was unreachable dead
code until this line existed — and the only visible symptom was that a dead
selected declaration got tree-shaken. Exact match, not a `maot:` prefix: an
unknown `maot:*` pragma must not be silently accepted as selection.

It parses to `PragmaEntryPointType.Default`, which makes selection a root for
the **Dart** tree shaker. That is half the job.

### Retention is a decision this code makes, not one it inherits

The VM precompiler has its own reachability, and surviving the Dart tree shaker
says nothing about it. `SeedMutableAotRoots()` calls
`Precompiler::AddFunction(fn, RetainReasons::kMutableAotDeclaration)` for every
selected declaration before `Iterate()`, so selection is an explicit retention
and compilation root with a named reason that shows up in the retained-reasons
output.

No global suppression is used, and none is acceptable here:
`--retain-function-objects`, disabling tree shaking, disabling class dropping,
or serializing all Functions would each make the registry look correct by
making pruning stop working.

### The two binding seams

Both are authoritative, and both are the loader:

| seam | where |
|---|---|
| ordinary procedures | `KernelLoader::LoadProcedure`, offset `procedure_offset + library_kernel_offset_` |
| constructors | `FinishClassLoading`'s constructor creation, offset `constructor_offset + library_kernel_offset_` |

`library_kernel_offset_` and not `correction_offset_`: the two `KernelLoader`
constructors use different offset conventions, and the deferred per-library
path leaves `correction_offset_` at 0, which silently missed every application
procedure while the platform ones bound correctly.

`--maot_disable_constructor_seam` exists so the constructor seam can be shown
to be load-bearing rather than assumed: with it, 18 of 19 declarations bind and
the gate refuses the result.

## Where the registry is reduced, and why it is not a free choice

Kernel loading registers every declaration it sees, selected or not — the
metadata rides on all of them, and the seam is the loader, not a filter. So
between loading and materialization the registry is an `ObjectStore` root
holding a `Function` for every declaration in the program, including all the
ones the precompiler is about to drop.

Reduction therefore has to happen **before** the drop phase, and the earliest
point where all three inputs are final is immediately after
`TraceForRetainedFunctions()`:

| input | final at that point because |
|---|---|
| selection | it came from the kernel metadata at load time |
| retention | `functions_to_retain_` is what `DropFunctions()` will keep |
| executability | code attachment finished with the compilation loop above |

Running it later — the original choice, after `DropLibraries()` — leaves the
registry rooting the whole program across `DropClasses()`. That is not a
retention leak (`DropFunctions()` rebuilds each class's function array from
`functions_to_retain_`, so a stray reference does not make anything retained)
but it is a *reachability* leak, and reachability is all the serializer needs.
See FINDINGS for the abort it produced.

Reduction also has to actually release. `SetLength(0)` on a
`GrowableObjectArray` leaves the backing `Array` at full capacity with every
old pointer still in place, and both the GC and the serializer walk the
backing array. The registry replaces its storage instead.

## ABI compatibility — two components, because they are known at different times

Dart source type equality does not define machine-call compatibility. The
compatibility model has two halves, and the split is forced by the pipeline
rather than chosen for tidiness.

### 1. Kernel / source-call shape — `MaotAbiDescriptor`

Computed by the front end, rides in the metadata.

| field | why it is ABI |
|---|---|
| member kind | instance / static / getter / setter / operator / constructor / factory, taken from #65's id tag so it cannot disagree with identity |
| positional count, required positional count | separately: `f(a,[b])` and `f(a,b)` are different call contracts |
| named parameter names | the set, sorted |
| required named names | requiredness is part of the contract |
| type parameter count | `IsGeneric()` also forces the stack convention |
| receiver presence | a static and an instance member with one shape are not call-compatible |
| owner-is-generic | the callee expects type arguments |
| **type parameter bounds**, in declaration order | `BuildTypeArgumentTypeChecks` emits the callee's bound checks only when `!AllDynamicBounds()`; narrowing `<T extends num>` to `<T extends int>` leaves every caller compiled against the wider contract |

Bounds are rendered through **#65 class identity**, never a raw name: `num`
is a name, `lib:dart:core::cls:num` is an identity. A shape the renderer
cannot spell becomes an explicit `unrepresentable:` token and the runtime
refuses to stage against it — two "unrepresentable" tokens comparing equal
would mean the renderer failed twice, not that the shapes agree.

Owner identity is **not** repeated here: the DeclarationId already is
`lib:<importUri>::cls:<Name>::<kind>:<name>`. A second spelling of the same
fact is a second thing that can be wrong.

### 2. Final AOT calling convention — computed in the precompiler

This cannot be computed in the front end, because unboxing has not been
decided; and it cannot be recomputed in the deployed runtime, because
`unboxed_parameters_info_` is compiled out of `DART_PRECOMPILED_RUNTIME`
entirely and every accessor returns `false` there. It is captured at
materialization and travels as data.

The fields are derived from what `compiler::ComputeCallingConvention`
(`dart_calling_conventions.cc`) actually consumes for a target:

| field | source |
|---|---|
| `fixed<N>` | `num_fixed_parameters()`, the argc it is called with |
| `regs<N>` | `MaxNumberOfParametersInRegisters()`, the register/stack split |
| `factory` / `nofactory` | `ComputeLocationsOfFixedParameters` shifts the parameter index for a factory |
| `args<t\|i\|d>*` | `FlowGraph::ParameterRepresentationAt` — tagged, unboxed int64, unboxed double |
| `ret<t\|i\|d\|p>` | `FlowGraph::ReturnRepresentationOf`, `p` being `kPairOfTagged` |

`regs<N>` is recorded as the **output** of `MaxNumberOfParametersInRegisters`
rather than as its inputs, and that is sufficient rather than merely
convenient: `IsGeneric()`, the function kind,
`must_use_stack_calling_convention` and
`has_overrides_with_less_direct_parameters` are all inputs whose only effect is
that number. Two functions differing in those flags but agreeing on the number
cannot be distinguished by the calling convention; two disagreeing on it always
can.

Why the caller's code depends on the callee's representation, and why getting
this wrong is a memory-safety break rather than a type error:

```cpp
// FlowGraphBuilder::PushExplicitParameters, kernel_to_il.cc
if (!target.IsNull() && target.is_unboxed_parameter_at(i)) {
  ...UnboxInstr::Create(to, Pop(), ...)      // the CALLER unboxes
}
```

### The invariant selection accidentally creates

Every selected declaration measures the fully boxed, stack-based convention —
`regs0`, all parameters tagged, tagged return. That is not luck, and the chain
is checkable:

```
pragma.dart              maot:mutable -> ParsedEntryPointPragma
unboxing_info.dart       _cannotUnbox(): isMemberReferencedFromNativeCode(m)
                         -> unboxingInfo.setFullyBoxed()
metadata/unboxing_info   setFullyBoxed(): argsInfo.length = 0,
                         returnInfo = kBoxed,
                         mustUseStackCallingConvention = true
object.cc                MaxNumberOfParametersInRegisters(): 0 when
                         must_use_stack_calling_convention
```

So selection pins every selected declaration to the boxed stack convention —
which is exactly the calling-convention stability a patch system wants,
arrived at by accident. An accident that load-bearing is **checked on every
run** (`selected_calling_convention_is_boxed_stack`) with `F26` as its
falsification, rather than believed.

It also means the representation dimension cannot vary *within* the selected
population, so no fixture pair can discriminate it. The component is still
carried and still compared, and the register/stack split does vary
measurably: an unselected declaration measures `regs1` in the same run where
every selected one measures `regs0`.

### Not represented, and why

**Closure / context shape.** Closures are not in the MAOT-2 selected
population at all. Selection and indexing walk `library.members` and
`cls.members`; a local function is not a `Member`, cannot carry the pragma,
and never receives a DeclarationId. **#75 (MAOT-11)** owns closures,
async/generators and isolates. This is an explicit exclusion, not an omission.

### How it is proven

Not by "two different strings are refused", which proves nothing about
coverage. The self-test attempts a **real** `StageReplacement` for every
ordered pair of registry entries and records whether it was accepted; the gate
requires the matrix to be an *equivalence*:

```
accepted  <=>  (abi_equal AND call_convention_equal)
```

A missing dimension appears as a differing pair that is nevertheless accepted;
a spurious one appears as an identical pair that is refused. Named dimensions
each have a fixture pair differing in exactly that one dimension.

## Measured cost

From the run this document ships with — 19 selected
declarations, one of them dead code that only selection keeps alive. Diagnostic
only: no threshold is compared anywhere.

| | |
|---|---|
| AOT ELF, selected | 841,288 B |
| AOT ELF, no-pragma control | 840,232 B |
| delta | **1056 B** for 19 declarations |
| registry footprint | 1976 B (104 B/entry, 13 slots) |
| lookup | 154 µs / 10,000 linear-scan lookups |
| startup | 17.23 ms vs 16.68 ms control, median of 7 |

The control is the identical source with every `maot:mutable` removed, so the
delta includes keeping a dead selected declaration alive. Lookup is a linear
scan: correctness first, and the cost is recorded rather than optimised
around — #71 is expected to replace the storage.

## Build environment — resolved, with one open question

An earlier reading of this suggested the toolchain was gone. That was wrong and
worth recording so nobody re-derives it: `/Volumes/build/route-b/flutter/buildtools`
is a stub containing only `README.md`, but the DEPS-specified path is
`engine/src/flutter/buildtools/mac-arm64/clang`, which holds a working
**Fuchsia clang 23.0.0** matching the pinned `clang_version`
(`git_revision:80743bd43fd5b38fedc503308e7a652e23d3ec93`). `ninja` is on PATH;
`gn` is in depot_tools and needs a bootstrap.

**The open question is not whether we can build — it is where.** The Dart tree
the engine compiles is `engine/src/flutter/third_party/dart`, which is the
Route B checkout (`R3`), currently on branch `route-b` and holding **another
lane's uncommitted work**: 15 added lines in
`pkg/front_end/lib/src/source/source_loader.dart`, plus a stray `.DS_Store`.
`args.gn` additionally pins `dart_version` and `dart_sdk_verification_hash` to
`9e8c898a4d`, so pointing the build at a different Dart revision is a
deliberate configuration change, not a silent one.

Building #66 therefore requires either borrowing `R3` — recording its exact
state, switching the branch, building into a *new* out directory so Route B's
artifacts are untouched, and restoring it verifiably — or standing up a second
engine checkout. The house rule is to coordinate a shared rig rather than
guard-and-proceed, so that choice is surfaced rather than taken unilaterally.

**Resolved by borrowing.** Every borrow is recorded in
`rescued/R3_STATE_BEFORE_BORROW.txt` with the branch, HEAD, tree and a digest
of the other lane's uncommitted diff, and every hand-back restores all four
verifiably. Builds go to `out/maot_host`, an APFS clone; Route B's own
`out/host_release_arm64_nodm` has never been written to. `build_maot.sh`
records the sha256 of each MAOT source after a successful build and the gate
compares digests before measuring anything — mtimes are useless here, because
switching branches on a shared rig rewrites every one of them without changing
a byte.
