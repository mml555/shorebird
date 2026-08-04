# iOS code push without their fork — the execution engine is already in vanilla Dart

**Investigated 2026-08-03** against `dart-sdk` at `d684a576` (Dart 3.12.2, the
revision vanilla Flutter 3.44.8 pins) — our own checkout at
`/Volumes/build/ios-engine/dart-sdk`. All line numbers are from that tree.

## The reframing

We cannot read Shorebird's Dart VM fork (private) and we are not going to
reconstruct it from their binaries. We do not need to. **Vanilla Dart already
contains an interpreter, a bytecode compiler, and — critically — a supported
primitive for replacing an AOT-compiled function's implementation with bytecode
at runtime.** What Shorebird built in 2022 on a Dart fork is, in 2026, largely
upstream.

What we take from Shorebird is the *interface contract*, established by observing
their public toolchain: six `gen_snapshot` options
(`--base_{ct,dt,ft,op}_link_data`, `--patch_{ct,op}_link_data`) and the `.vmcode`
artifact. Not their source.

## The primitive that changes the picture

`runtime/vm/object.cc:8413`:

```cpp
void Function::AttachBytecode(const Bytecode& value) const {
  ...
  untag()->set_ic_data_array_or_bytecode(value.ptr());
  // Set the code entry_point to InterpretCall stub.
  SetInstructions(StubCode::InterpretCall());
}

void Function::ClearBytecode() const { ...; ClearCode(); }        // :8427 — rollback

bool Function::IsInterpreted(FunctionPtr function) {              // :8433
  return function->untag()->code() == StubCode::InterpretCall().ptr();
}
```

Three things follow, and each was a question we thought needed their fork:

- **Where does patch bytecode live?** In AOT there are no inline caches, so
  `Function` reuses that slot: `ic_data_array_or_bytecode()`
  (`object.h:13458`, `HasBytecode` at `:13466`). No new field, no format change.
- **How does a call reach interpreted code?** `Function::IsInterpreted()` is
  *defined as* "my Code is the `InterpretCall` stub". `AttachBytecode` points the
  function's entry point at that stub, so any caller dispatching through the entry
  point lands in the interpreter. The stub exists upstream:
  `stub_code_list.h:83`, runtime entry `runtime_entry.cc:4833`, and it is cached
  per-thread at `thread.h:268`.
- **Does this work without a JIT?** `DartEntry::InvokeFunction`
  (`dart_entry.cc:141`) routes interpreted functions to
  `Interpreter::Current()->Call(...)`, and that branch is **not** excluded from
  `DART_PRECOMPILED_RUNTIME` — only the JIT-compile path below it is. The
  interpreter itself (`runtime/vm/interpreter.cc`, 4,567 lines) carries explicit
  `#if defined(DART_PRECOMPILED_RUNTIME)` branches. It is built to run inside an
  AOT runtime, which is the iOS situation exactly.

All of it is behind `#if defined(DART_DYNAMIC_MODULES)`, whose GN flag
`dart_dynamic_modules` defaults to `false` (`runtime/runtime_args.gni:79`). A
build-config flip, not new VM code.

`pkg/dart2bytecode` — the bytecode compiler — is also present in-tree.

## This refines Phase 4 rather than contradicting it

[`ENGINE_PARITY_PLAN.md`](ENGINE_PARITY_PLAN.md) Phase 4 asked whether a **dynamic
module** could replace code the AOT snapshot already contains, and answered **no**.
That result stands: `loadDynamicModule` runs a module's entry point and returns its
result, and the only override a module can express is a subclass.

But that was a test of the **Dart-level module API**. `Function::AttachBytecode` is
a **VM primitive reachable from C++** — the layer our engine patch-installer already
lives in ([`shorebird.cc`](../vendor/flutter/engine/src/flutter/shell/common/shorebird)).
So the route is not "call `loadDynamicModule` from Dart"; it is "attach bytecode to
the patched functions from the engine's installer". Phase 4 closed the wrong door,
not the only door.

## What is therefore still unsolved — and this is the real work

The interpreter and dispatch come free. The **binder** does not:

1. **Inlining is the hard ceiling.** AOT inlines aggressively. If a caller inlined
   the callee's body, replacing the callee changes nothing — the caller must also be
   patched, transitively. This is not a bug to fix; it is *why Shorebird reports a
   link percentage*. Our linker must compute the same closure and decide what is
   patchable.
2. **Static direct calls bake their target.** Swapping `Function.code_` redirects
   dispatch that goes *through* the entry point. A static call compiled to a direct
   branch does not. Rewriting those call sites is precisely what a pinned object pool
   buys — and explains why `op` is one of only two spaces with a `--patch_*` flag as
   well as a `--base_*`.
3. **Bytecode must bind to the base snapshot.** The patch's bytecode references
   classes, fields, selectors and constants that must resolve to the base's
   identifiers. This is the layout-pinning work already specified in
   [`AOT_LINKER_FEASIBILITY.md`](AOT_LINKER_FEASIBILITY.md) — class table and field
   table have pinning entry points upstream, the dispatch table has `AllocateAt`, and
   **the object pool's cross-build identity key remains the item that can cost months.**
4. **`dart_dynamic_modules=true` must survive an iOS release AOT build.** Never
   tested. This was Phase 4's experiment #2, skipped when experiment #3 ended the
   question.

## Kill gate — run this before building any linker

Cheap, and it can end the question either way:

> Build the engine for iOS with `dart_dynamic_modules=true`. Take a function the
> AOT snapshot already contains, compile a changed body with `dart2bytecode`, call
> `Function::AttachBytecode` from the engine at runtime, and observe whether the
> new behavior takes effect on a physical device.

Pass → the execution model is proven and the remaining work is the binder, which is
specified. Fail → we learn exactly which of (1)–(4) blocks it, at the cost of one
build rather than months of linker work.

**Do not build the linker first.** A perfect patch that cannot execute is worth
nothing, and this gate is days, not months.

## Status — the gate has been run, and it passed on execution

**2026-08-04, macOS arm64, release AOT build with `dart_dynamic_modules=true`:**
a function the snapshot already contained was repointed at interpreted bytecode
(`IsInterpreted` 0 → 1) and **executed the new body** — `NEW` instead of `OLD` —
via `DartEntry::InvokeFunction`. No JIT, no new executable pages. Full evidence in
[`engine/killgate/README.md`](engine/killgate).

This also settles Phase 4's never-run experiment #2: the interpreter survives a
release AOT build. `dartaotruntime` carries 48 `Interpreter` symbols and the
`_InterpretCall` stub.

**What is now proven vs. what remains:**

| Question | Answer |
|---|---|
| Interpreter present in an AOT runtime | **Yes** |
| An AOT function's body replaceable at runtime | **Yes**, `AttachBytecode` |
| Interpreter executes the replacement | **Yes** |
| Existing call sites reach it | **No** — all four shapes (direct, tear-off, dynamic, `Function.apply`) still ran the old code |
| Patch bytecode binds to the base snapshot | **No** — a body calling `print()` failed with `Unable to find function print in Library:'dart:core'` |

The two "no" rows are items (2) and (3) above, and they are precisely what a linker
does. Nothing in the VM is missing; the missing piece is the **binder**. That is a
much better position than the one this document started from, where writing an
interpreter was on the table.

## Where the binder has to act — measured 2026-08-04

AOT emits static calls in **two forms**, and the difference decides whether a
patch is possible on iOS at all
(`runtime/vm/compiler/backend/flow_graph_compiler_arm64.cc:397`):

```cpp
if (CanPcRelativeCall(target)) {
  __ GenerateUnRelocatedPcRelativeCall();   // a `bl` immediate, in the instruction stream
} else {
  // "Call sites to the same target can share object pool entries."
  __ BranchLinkWithEquivalence(StubCode::CallStaticFunction(), target, entry_kind);
}
```

- **PC-relative** lives in **code**. iOS will not let us write code pages, so a
  call site of this form can never be redirected at runtime.
- **Pool-mediated** goes through an object pool entry, which is **data**, and data
  is writable on iOS.

`CanPcRelativeCall` (`flow_graph_compiler.cc:3535`) is `precompiled_mode &&
!FLAG_force_indirect_calls && same_loading_unit`. So there are exactly two ways to
force every static call onto the patchable path: the **`--force_indirect_calls`**
flag, or putting patchable code in a **separate loading unit**.

**Both halves tested.** `--force_indirect_calls` is honored — the same program's
snapshot grows 838,560 → 871,520 bytes (+4%), which is the expected cost of
replacing `bl` immediates with pool loads. But the gate's result did **not**
change: all four call shapes still ran the old body.

That isolates the remaining work exactly:

> Making calls indirect is **necessary but not sufficient**. A pool entry is baked
> with the target resolved at snapshot time, and `Function::AttachBytecode` updates
> `Function.code_` and the entry point — **not** the pool entries that already
> point at the old `Code`.

So the binder's core operation is now concrete and small: **after attaching, rewrite
every object-pool entry that references a patched function's old `Code`** so it
resolves to the interpreted version instead. Nothing needs to be discovered about
the VM to do that; it is a walk over data.

This is also, finally, a satisfying explanation of the fork's flag set. The object
pool is the *redirection surface*, which is why `op` is one of only two spaces
carrying both `--base_op_link_data` **and** `--patch_op_link_data`: the patch has to
know the base's pool layout to rewrite the right slots, and hand its own forward for
the next patch.

**Consequence worth deciding early:** shipping with `--force_indirect_calls` (or a
loading-unit split) is a *release-time* choice — a patch cannot retrofit it onto an
app that was built without it. Whatever we adopt has to be baked into how releases
are built, exactly as Shorebird's layout pinning is.

### The pool rewrite works. The stub it lands on does not (yet).

Implemented the rewrite in the gate's native: capture the target's `Code` before
attaching, then walk the single global object pool
(`ObjectStore::global_object_pool()`) and repoint every slot holding that `Code`.

```
ATTACH: pool len=2237, rewrote 1 slot(s) (other Code slots=836)
ATTACH: C++ invoke of target returned: NEW
===== CRASH =====  si_signo=Segmentation fault, si_code=SEGV_ACCERR
```

It found **exactly the one slot** for the call site, out of 2,237 entries — the
redirection surface is real and precisely addressable. Then the call through it
crashed, and the cause is in the stub
(`runtime/vm/compiler/stub_code_compiler.cc:230`):

```cpp
if (!FLAG_precompiled_mode) {
  __ LoadCompressedFieldFromOffset(CODE_REG, FUNCTION_REG, ...);
#if defined(DART_DYNAMIC_MODULES)
  // InterpretCall stub needs arguments descriptor for all function calls.
  __ LoadObject(ARGS_DESC_REG, ArgumentsDescriptorBoxed(...));
#endif
}
```

**The arguments-descriptor setup is guarded by `!FLAG_precompiled_mode`.** In AOT
nothing populates `ARGS_DESC_REG`, so entering `InterpretCall` from an AOT call site
reads a garbage descriptor and faults. That is why the C++ path succeeds and the
Dart path does not: `DartEntry::InvokeFunction` builds a real descriptor and calls
`Interpreter::Call` directly, bypassing the stub.

So the remaining gap is **one specific, well-scoped VM modification**: make the
`InterpretCall` path viable in precompiled mode by deriving the arguments descriptor
from the callee `Function` (its parameter counts are right there in `FUNCTION_REG`)
instead of expecting a caller-provided register. Upstream never needed this because
dynamic modules are only entered through the generic invoke path.

Status after this: **execution proven, redirection proven, entry convention is the
open item.** None of it requires their fork — it requires a patch to vanilla Dart of
the kind we already maintain (the existing shim is 57 lines).

The remaining honest caveat: this is macOS arm64, not iOS. iOS adds code signing
and a stricter W^X posture, but it is the same precompiled runtime and the same
interpreter — a port of a proven mechanism rather than an open question.

What it does change is the estimate's shape: we are no longer contemplating writing
an interpreter and a dispatch mechanism, which is the part that would genuinely have
meant reproducing their fork. We are contemplating a **binder** on top of machinery
Google maintains.
