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

## Honest status

This is a **source read, not a result**. Nothing here has been built or run. It
establishes that the pieces exist upstream and that the design is coherent; it does
**not** establish that a patched function executes on an iPhone. The gate above is
what would.

What it does change is the estimate's shape: we are no longer contemplating writing
an interpreter and a dispatch mechanism, which is the part that would genuinely have
meant reproducing their fork. We are contemplating a **binder** on top of machinery
Google maintains.
