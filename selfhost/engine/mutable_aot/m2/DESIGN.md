<!-- cspell:words MAOT precompiler dartaotruntime cipd Fuchsia untagged Untagged patchability -->

# MAOT-2 (#66) — the compiler → runtime binding

**Status: design settled from source inspection; implementation not started.**
This is #66's stated first task — *"before implementing the registry, inspect
the Dart AOT pipeline and determine the smallest durable way to carry
`DeclarationId -> runtime declaration / Function` through compilation"* — and it
is written before any code because two findings below eliminate the obvious
representation.

Inspected at Dart fork `bc3d67971e59b4a596c11b6299c737a73a83595a`
(tree `2a721855e670b000b6b91e5732450a57ed214bb1`).

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
            ▼
  <dill>                                   binding is IN the kernel binary
            │
            ▼
  runtime/vm/compiler/frontend/kernel_translation_helper.{h,cc}
            │   MaotDeclarationIdMetadataHelper reads it during kernel load,
            │   inside gen_snapshot, while Kernel identity is authoritative
            ▼
  runtime/vm/maot_registry.{h,cc}          MaotRegistry: parallel arrays of
            │                              (declaration id, Function, descriptor)
            │                              rooted from the ObjectStore
            ▼
  runtime/vm/app_snapshot.cc               its own serialization cluster
            │
            ▼
  dartaotruntime                           deserialized at startup, populated,
                                           zero reconstruction
```

The registry holds a **direct `FunctionPtr`**, established by the loader that
saw both the Kernel node and the runtime object. The Function is never
re-found; it is carried.

### Why the ObjectStore root

The registry must be reachable from a GC root that the snapshot serializer
traces, or it is dropped as garbage during precompilation. The `ObjectStore` is
how the VM roots per-isolate-group singletons and is what the existing clusters
in `app_snapshot.cc` (57 of them) expect.

### Files this touches

| file | change |
|---|---|
| `pkg/vm/lib/metadata/maot_declaration_id.dart` | new repository |
| `pkg/vm/lib/kernel_front_end.dart` | register the repository |
| `runtime/vm/compiler/frontend/kernel_translation_helper.{h,cc}` | new `MetadataHelper` |
| `runtime/vm/maot_registry.{h,cc}` | new registry object + API |
| `runtime/vm/object.h`, `raw_object.h` | the registry's own object layout |
| `runtime/vm/object_store.h` | root the registry |
| `runtime/vm/app_snapshot.cc` | serialization cluster |
| `runtime/vm/class_id.h` | a class id for the registry |

Deliberately **not** touched in #66: any call-site lowering, dispatch,
optimizer, or deoptimization path. Those are #67.

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
change. The measurement section records what selecting everything would cost.

## ABI descriptor

Dart source type equality does not define machine-call compatibility, so the
descriptor records what the VM actually needs to decide whether a replacement
body can occupy an existing call contract:

* member kind — instance / static / getter / setter / operator / constructor /
  factory (from #65's id tag, so it cannot disagree with identity);
* receiver / owner class identity;
* positional parameter count, and the required-positional count separately;
* named parameter names, and which are required;
* type parameter count, and bound identity;
* return and parameter representation where the calling convention cares
  (unboxed / boxed) — `unboxing_info.dart` already carries this shape and is
  the precedent to follow;
* closure context shape where the declaration is a closure.

The descriptor is deterministic and digestible, so validation compares a digest
rather than walking structures — and the digest is over the *descriptor*, never
over machine code.

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
