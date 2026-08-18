<!-- cspell:words dynmod dartaotruntime aot vmcode devirtualize devirtualization upstreamable inlines dyntest mendell -->

# Dynamic-modules harness — Phase 4 crux

Answers the question [`ENGINE_PARITY_PLAN.md`](../../ENGINE_PARITY_PLAN.md)
Phase 4 calls decisive:

> **Can a dynamic module replace a function the AOT snapshot already contains?**

It matters because it decides Phase 5's cost. If yes, iOS code push could ride
upstream's own mechanism and might even be upstreamable. If no, Phase 5 is the
pinned-layout `gen_snapshot` work — bigger, and ours to maintain forever.

Everything here runs on a stock Dart SDK. **No engine build, no iOS device, no
extra storage.**

## Answer: no

A dynamic module cannot replace code the AOT snapshot already contains. It is an
**extension** mechanism, not a patch mechanism.

The reasoning, in order of how much it rests on evidence versus inference:

1. **The loading contract is additive.** `dart:_internal`'s
   `loadDynamicModule({uri, bytes})` is documented as "Load a dynamic module and
   execute its entry point method", where the entry point is a no-argument
   method annotated `@pragma('dyn-module:entry-point')`, and it "returns a future
   containing the result". Load a module, run a function, get a value back.
   There is no replace or override entry point.
2. **The only override shape that compiles is a subclass.** `module.dart` here is
   the strongest override a module can express:
   `class PatchedGreeter extends Greeter { String greet() => 'PATCHED'; }`.
   It compiles to bytecode against the host's kernel. But a subclass cannot
   change what an **already-constructed** `Greeter` returns — that is Dart
   semantics, and no VM flag changes it.
3. **`dyn-module:can-be-overridden` is a devirtualization barrier, not a patch
   hook.** Read alongside `callable`, `extendable` and `can-be-used-as-type` in
   the dynamic interface, its job is to tell AOT's type-flow analysis *not* to
   devirtualize or inline a member, because a module may later introduce a
   subclass. It keeps a dispatch point open. It does not redirect one.

So a module can only supply new objects the host **chooses to use**, at dispatch
points the host **declared open at build time**. Patching a bug in code that
existing objects already run — the whole point of code push — is out of reach.
Worse for our purposes, the members you would most want to patch are exactly the
ones AOT resolves directly and inlines.

**Consequence:** Phase 5 is the pinned-layout route. Route 2 in
[`FORK_REBUILD.md`](../../FORK_REBUILD.md) is dead as a drop-in patch mechanism.

## What is proven by running, and what is not

Honest accounting, because the harness stops one call short of a runtime demo.

| Step | Status |
|---|---|
| Host compiles with a dynamic interface (`gen_kernel --dynamic-interface`) | ✅ accepted, incl. `can-be-overridden` on a real member |
| Host AOT-compiles and runs (`gen_snapshot` → `dartaotruntime`) | ✅ prints `ORIGINAL` |
| Module compiles to KBC bytecode against the host kernel (`dart2bytecode --import-dill`) | ✅ 572 bytes |
| Host **calls** `loadDynamicModule` at runtime | ❌ blocked — see below |

The block: `loadDynamicModule` lives in `dart:_internal`, which user code cannot
import ("Can't access platform private library"), and binding the native
directly with `@pragma("vm:external-name", "Internal_loadDynamicModule")`
compiles but fails at call time:

```
native_entry.cc: 260: error: Failed to resolve native function
'Internal_loadDynamicModule' in '::._loadDynamicModule@17180338'
```

VM-internal natives resolve by name only for `dart:` libraries. There is no
allowlist that admits a user library — `allowed_experiments.json` governs
language experiments, not private imports — and `dynamic-modules` is not a
registered experiment in Dart 3.12.2's CFE at all, even though the tooling and
the runtime both ship.

**To finish the runtime proof** you need the call to originate inside a `dart:`
library. Two ways: rewrite `vm_platform_product.dill` with `package:kernel` to
re-export `loadDynamicModule` from a public library, or do it inside a Flutter
engine build where `dart:ui` is a platform library. Both are hours of work to
confirm a conclusion that already follows from the language semantics in point 2
above, which is why this stopped here.

## Running it

**Not from the session scratchpad.** `gen_kernel` mangles paths containing a
component that starts with `-` (the scratchpad sits under
`-Users-mendell-shorebird/`) and reports `Error when reading '/host.dart'`,
which looks like a missing file rather than a path bug. Use a plain directory.

Two more traps, both of which present as compiler bugs rather than bad input:

- **`di.yaml` must name the library by the URI the CFE indexes it under** — the
  `package:` URI from `package_config.json`, not a `file:` URI. A `file:` URI
  fails as `The library ... has not been indexed` inside `LibraryIndex`.
- **`--import-dill` needs the pre-AOT kernel.** Handing `dart2bytecode` the
  AOT-transformed dill crashes the CFE with
  `Null check operator used on a null value` in `DillExtensionBuilder`. Step 4
  builds a separate `--no-aot --no-link-platform` kernel for this reason.

```bash
./build.sh /private/tmp/dyntest
```

`build.sh` takes the working directory, defaults the SDK to the CLI's vended
Dart 3.12.2, and prints each stage. The final stage is expected to fail with the
native-resolution error above.
