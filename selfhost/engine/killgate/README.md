<!-- cspell:words dartaotruntime aotruntime killgate vmcode -->

# The iOS code-push kill gate

**One question, and nothing else:**

> In a **precompiled (AOT) runtime**, can we replace the body of a function the
> snapshot already contains with interpreted bytecode, and have callers run the
> new body?

If yes, the iOS execution model is proven and the remaining work is the *binder*
(see [`../../AOT_LINKER_FEASIBILITY.md`](../../AOT_LINKER_FEASIBILITY.md)). If no,
we learn which assumption in [`../../IOS_CODE_PUSH.md`](../../IOS_CODE_PUSH.md) is
wrong for the price of one build instead of months of linker work.

## RESULT — run 2026-08-04: the execution model works

```
ATTACH: before -> IsInterpreted=0 HasBytecode=0
ATTACH: after  -> IsInterpreted=1 HasBytecode=1
ATTACH: C++ invoke of target returned: NEW      <-- interpreter ran the new body
after  direct   : OLD
after  tear-off : OLD
after  dynamic  : OLD
after  apply    : OLD
```

**Answered: yes.** In a precompiled (AOT) runtime, on macOS arm64, a function the
snapshot already contained was repointed at interpreted bytecode
(`IsInterpreted` 0 → 1) and **executed the new body**, returning `NEW` when invoked
through `DartEntry::InvokeFunction`. No JIT, no new executable pages. That is the
iOS execution model, proven.

**What does not work yet, and it is the predicted thing:** every Dart-side call
site still reaches the old code. All four shapes — direct, tear-off, dynamic,
`Function.apply` — returned `OLD`. In AOT these are all statically bound: the
direct call's target was resolved at compile time, and the tear-off is a constant
closure whose code was baked in, so `Function.apply` on it never re-resolves the
function's current code and never reaches the `IsInterpreted()` branch.

So the remaining work is **call-site binding**, which is exactly what a linker
does — and exactly why Shorebird pins the object pool and reports a link
percentage. It is not a VM capability gap.

This splits the risk cleanly:

| Question | Status |
|---|---|
| Does an interpreter exist in an AOT runtime? | **Yes** — 48 `Interpreter` symbols + `_InterpretCall` in `dartaotruntime` |
| Can an AOT function's body be replaced at runtime? | **Yes** — `AttachBytecode`, `IsInterpreted` 0 → 1 |
| Does the interpreter execute the replacement? | **Yes** — returned `NEW` |
| Do existing call sites reach it? | **No** — needs call-site rewriting (the binder) |
| Does patch bytecode bind to the base snapshot? | **Not yet** — see the `print` finding below |

### Two findings worth keeping

**Binding is real and shows up immediately.** The first replacement body called
`print()`, and the run died in `bytecode_reader.cc:1172` with
`Unable to find function print in Library:'dart:core'`. A patch's bytecode
references do **not** resolve against the base snapshot for free. Keeping the
replacement self-contained is what let the execution question be answered
separately — the discipline paid for itself.

**AOT drops library dictionaries.** `Library::LookupFunctionAllowPrivate` could not
find `greet` until it was marked `@pragma('vm:entry-point')`. That is a *gate*
limitation, not a design constraint: a real linker identifies patch targets from
the snapshot's tables at build time, not by runtime name lookup.

### Reproducing

`0001-attach-bytecode-native.patch` (128 insertions across 4 files) carries the
SDK side: the native, its registration, and the `dart:_internal` declaration.
Apply it to `engine/src/flutter/third_party/dart`, rebuild
`dartaotruntime gen_snapshot dart dart_sdk vm_platform.dill`, then run `run.sh`.

## Why host macOS first, not iOS

A macOS release build is also a `DART_PRECOMPILED_RUNTIME`, so it exercises the same
`PRECOMPILED_RUNTIME` + `DYNAMIC_MODULES` combination as iOS, with no signing, no
device, and a fast loop. iOS is a port of a proven mechanism, not the place to
discover the mechanism doesn't work.

## Design, and what it deliberately does *not* test

The gate tests **one** thing: interpreted execution replacing AOT execution. Two
choices keep it that narrow:

1. **The replacement body is self-contained** — it returns a string literal and
   touches nothing outside itself. If it referenced other classes or constants, the
   test would also be exercising the object-pool binding problem, and a failure
   would not tell us which half broke. Binding is the *next* question, not this one.
2. **The target is `@pragma('vm:never-inline')`.** Without it, AOT inlines the callee
   into `main` and no amount of body replacement changes the output — the test would
   fail for a reason that has nothing to do with the interpreter. This is the
   inlining ceiling in miniature, and controlling it here is the point: in the real
   system, inlining is exactly what the link percentage measures.

## Mechanism

Upstream already has every piece; the gate wires them together:

| Piece | Where | Role |
|---|---|---|
| `bytecode::BytecodeLoader(thread, data).LoadBytecode()` | `runtime/lib/object.cc:588` (used by `loadDynamicModule`) | Turns bytes into a `Function` carrying a `Bytecode` |
| `Function::AttachBytecode(bc)` | `runtime/vm/object.cc:8413` | Points a function's entry at the `InterpretCall` stub |
| `Function::IsInterpreted()` | `runtime/vm/object.cc:8433` | Defined as "my Code *is* that stub" |
| `DartEntry::InvokeFunction` | `runtime/vm/dart_entry.cc:141` | Routes interpreted functions to `Interpreter::Call`, with no `PRECOMPILED_RUNTIME` exclusion |
| `Library::LookupFunctionAllowPrivate` | `runtime/vm/object.h:2257` | Finds the already-compiled target by name |

`loadDynamicModule` loads a module and invokes **its own** entry point — which is why
Phase 4 correctly found it cannot override existing code. The gate reuses its loader
but then does the one different thing: attaches the loaded bytecode onto a
**pre-existing** function instead of calling the module's entry.

## Files

| File | Purpose |
|---|---|
| `attach_bytecode_native.cc` | The native to add to `runtime/lib/object.cc` |
| `internal_patch_snippet.dart` | Dart-side `external` declaration for `sdk/lib/_internal/vm/lib/internal_patch.dart` |
| `bootstrap_natives_snippet.h` | The one line for `runtime/vm/bootstrap_natives.h` |
| `target.dart` | The program that gets AOT-compiled — contains the function to replace |
| `replacement.dart` | Compiled to bytecode; supplies the new body |
| `run.sh` | Builds both halves and runs the gate |

## Reading the result

| Output | Meaning |
|---|---|
| `OLD` then `NEW` | **PASS.** Interpreted body replaced AOT body in a precompiled runtime. Proceed to the binder. |
| `OLD` then `OLD`, attach returned true | Dispatch did not reroute. Most likely the call was inlined or direct-called — check the `never-inline` pragma took effect, then inspect whether the caller reaches the callee through its entry point. |
| attach returned false | Lookup or load failed — a naming problem in the harness, not a VM verdict. Fix and re-run. |
| Crash inside the interpreter | The mechanism engaged but the bytecode is not valid in this context. That is *informative*: dispatch works, binding does not. |
| `Unsupported` / no-op | `dart_dynamic_modules` did not reach this build. Check `args.gn`. |

The third and fourth rows are why the gate is worth running even if it fails: each
failure mode points at a different one of the four open questions.
