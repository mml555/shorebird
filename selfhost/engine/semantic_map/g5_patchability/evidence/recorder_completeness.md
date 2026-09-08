# SM1-G5 route 2 — recorder completeness

**Question this answers.** The reader may report `NOT_INLINED` only if absence
from the note is evidence. That requires: *every compiler operation capable of
materializing an inline copy necessarily called the recorder.* This document
enumerates those operations from source and states exactly which ones the
recorder covers.

Source tree: effective Dart tree `7b04b01bdc10ec990143257f0d28580571c2122f`
(revision `9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c`). All paths are relative to
`runtime/`, all line numbers from that tree.

## Where the recorder sits

`vm/compiler/backend/flow_graph_compiler.cc:154` — the `FlowGraphCompiler`
constructor. The recorder reads `flow_graph->inlining_info()` there and emits
one note record per entry after index 0.

## Claim A — every AOT code emission reaches the recorder

`FlowGraphCompiler` is constructed in exactly three places in the tree:

| site | build |
|---|---|
| `vm/compiler/aot/precompiler.cc:3647`, in `PrecompileParsedFunctionHelper::GenerateCode` (`:3609`) | **AOT** |
| `vm/compiler/jit/compiler.cc:487` | JIT — not this lane |
| `vm/compiler/backend/il_test_helper.cc:221` | unit tests |

So in AOT there is one code-generation site, it constructs `FlowGraphCompiler`
before `CompilerPass::GenerateCode`, and the constructor is where the recorder
runs. No AOT Dart function reaches machine code without passing through it.

Stubs and intrinsic assembly stubs are hand-written machine code, not
compilations of a Dart body, and have no `FlowGraph` — they cannot carry an
inline copy of a declaration.

**Direction of error.** The recorder runs in the constructor, i.e. before code
is finalized, and AOT may discard and recompile a graph (speculative-inlining
bailout). That can record an inline relation for code that was thrown away —
it **over**-records. Over-recording moves a declaration from `NOT_INLINED` to
`INLINED`, which withdraws a safety claim; it can never manufacture one.
Under-recording is the only dangerous direction, and Claim B is about that.

## Claim B — every inline copy of a body is registered

`InliningInfo` (`vm/compiler/backend/flow_graph.h:121-142`) holds
`inline_id_to_function`. Its own comment: *"Top scope function has inline_id 0.
The map is populated by the inliner."* There are exactly three writers in the
tree:

1. `flow_graph.h:132` — the `InliningInfo` constructor adds entry 0, the
   function being compiled. Not an inlinee.
2. `vm/compiler/backend/inliner.cc:2597`, inside
   `FlowGraphInliner::NextInlineId` (`:2588`) — the only append of an inlinee.
3. `vm/compiler/backend/il_serializer.cc:814` — IL deserialization
   reconstructs the array from the serialized graph, preserving it across a
   serialize/deserialize round trip (`:741-749` writes it).

`FlowGraphInliner::NextInlineId` has exactly **one** call site in the tree:
`vm/compiler/backend/inliner.cc:1555`, in `CallSiteInliner::TryInliningImpl`
(`:1159`), on the success path immediately after the callee graph is spliced in
(`SetInliningIdAndTryIndex`). Polymorphic inlining reaches the same path:
`PolymorphicInliner` delegates to its owning `CallSiteInliner`.

Therefore: **a callee's body IL cannot be copied into a caller's graph by the
inliner without being registered**, and the registration is what the recorder
reads.

## Claim C — the operations that bypass the registry, and their gates

A second family of operations materializes a callee's *semantics* into a caller
without producing an inline id. These do not go through `NextInlineId` (proven
above: it has one caller). They matter to this gate for the same reason real
inlining does — if a caller has the callee's behaviour built in, patching the
callee will not move that caller. Each is gated:

| operation | site | gate |
|---|---|---|
| `CallSpecializer::TryInlineInstanceGetter` | `call_specializer.cc:984` | `target.kind() != kImplicitGetter` → returns false |
| `CallSpecializer::TryInlineInstanceSetter` | `call_specializer.cc:818` | `target.kind() != kImplicitSetter` → returns false |
| `CallSpecializer::TryInlineImplicitInstanceGetter` | `call_specializer.cc:755` | reached only via the above; requires `accessor_field()` |
| `AotCallSpecializer::TryInlineFieldAccess` | `aot_call_specializer.cc:226,237` | field access only |
| `CallSpecializer::TryReplaceWithBinaryOp` and the equality/relational/unary variants | `call_specializer.cc:525` | every branch requires operand **class ids** from a fixed VM-primitive set (`kSmiCid`, `kMintCid`, `kDoubleCid`, `kFloat32x4Cid`, `kInt32x4Cid`, `kFloat64x2Cid`) |
| `CallSpecializer::TryInlineRecognizedMethod` | `call_specializer.cc:3184` | switches on `target.recognized_kind()` |

Two of those gates close entirely for application code:

* **Recognized methods.** `recognized_kind` is assigned in exactly one place,
  `MethodRecognizer::InitializeState` (`vm/compiler/method_recognizer.cc:185`),
  which expands the compile-time macro list `RECOGNIZED_LIST`
  (`vm/compiler/recognized_methods_list.h`). Each entry names its library as a
  `Library::<name>Library()` accessor; the closed set is: Async, CompactHash,
  Convert, Core, Developer, Ffi, Internal, Isolate, Math, NativeWrappers,
  TypedData, VM. There is no accessor for an application library, so no
  application declaration can carry a recognized kind. The `vm:recognized`
  pragma does **not** assign one — `Function::CheckSourceFingerprint`
  (`vm/object.cc:11890`) only uses it as a `DEBUG`-build consistency check.

* **Operators.** An application class's class id is never in the VM-primitive
  set the replacement branches require, so a user-declared `operator` is not
  replaceable by that path.

The accessor gates do **not** close for application code: any app-declared
field has VM-synthesized `kImplicitGetter`/`kImplicitSetter` accessors, and
those can be materialized into a caller with no inline id. The VM states the
boundary itself at `call_specializer.cc:988-992`: *"Non-implicit getters are
inlined like normal methods by conventional inlining in FlowGraphInliner"* —
so an explicitly declared getter or setter is covered by Claim B, and only the
implicit, field-backed accessor escapes.

## What the reader does with this

`lib/read_inlining.py` encodes the enumeration as its candidate-admission rule:

* `method`, `getter`, `setter`, `operator` — **admitted**; `NOT_INLINED` is
  available to them, justified by Claims A and B plus the two closed gates.
* `field`, `constructor`, `factory` — **candidates that refuse**. They have
  bodies, but their materialization is not covered, so every one is `UNKNOWN`
  with the mechanism named in the reason. They are not dropped: dropping them
  would let a later change admit them and inherit an unsound `NOT_INLINED`.
* `class` — reported in `no_body_rows`: it declares no body, so no inline copy
  of it can exist and the reader makes no claim.
* any other kind — `UNKNOWN`, fail-closed.

The reader emits the reconciliation as machine output — `total_g1_rows`,
`INLINED`, `NOT_INLINED`, `UNKNOWN`, `NO_BODY`, `accounted` — and exits non-zero
unless `accounted == total_g1_rows`, so no G1 row can silently disappear from
the inventory and no reader of the report has to add it up.

Each state also carries a stable `code` (`ABSENT_FROM_VALIDATED_NOTE`,
`KIND_NOT_COVERED_BY_PROOF`, `ONLY_SYNTHETIC_CHILD_INLINEE`, …) so the
falsification suite can assert which gate refused, not merely that something
did.

## Limits that remain

1. **Front-end materialization is out of scope.** Constant evaluation and
   inlining performed by the CFE/`gen_kernel` happen before the VM compiler
   and cannot appear in this note. A declaration whose value was folded into
   its callers at the kernel level would be absent from the note and reported
   `NOT_INLINED`. This bounds the claim to *VM-level* inlining, and it is why
   `field` refuses rather than relying on Claim B alone.
2. **JIT is unproven.** Claim A enumerates the AOT site only.
3. Claim B is a proof about *this tree*. It is a whole-tree enumeration of the
   writers of one array plus the callers of one function, so it must be
   re-derived rather than believed: `lib/verify_completeness.sh <dart-tree>`
   re-derives every count and gate in this document from source and exits
   non-zero if the tree disagrees. It found one error while being written --
   this document had transcribed the last recognized library as `M` rather
   than `VM` -- which is the reason it exists.
