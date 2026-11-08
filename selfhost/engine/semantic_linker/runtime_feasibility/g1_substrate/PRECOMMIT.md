<!-- cspell:words dartaotruntime dill semantic linker nodm -->
# SL1-G1 — what the OFF/ON pair must do, written before it was run

**Committed 2026-09-06, while the two builds were still compiling.**

The point of writing this first is that "the control behaved as expected" is
worth nothing if the expectation was chosen after seeing the output. Each
prediction below is read out of the frozen Dart source in the staged lane tree,
so it is falsifiable by the run and attributable to a line of code if it fails.

## Where the predictions come from

`runtime/lib/object.cc` in the frozen lineage guards all three module natives on
`#if defined(DART_DYNAMIC_MODULES)`, and each `#else` branch is explicit — the
comment on one of them says "report it rather than pretending":

| native | `DART_DYNAMIC_MODULES` undefined → |
|---|---|
| `Internal_attachBytecodeToFunction` | returns `Bool::False()` — a **refusal**, no throw |
| `Internal_detachBytecodeFromFunction` | `ThrowUnsupportedError("Detaching bytecode is not supported.")` |
| `Internal_loadDynamicModule` | `ThrowUnsupportedError("Loading of dynamic modules is not supported.")` |

Note the asymmetry, because it is a real prediction and not a detail: **attach
refuses by return value, the other two throw.** A probe that expected a throw
from all three would report a false failure on the arm that matters most.

## Predictions

**OFF (control), `out/sl1_dm_off`**

1. Normal AOT works: the host program compiles with `gen_snapshot
   --snapshot_kind=app-aot-elf` and runs under `dartaotruntime`, printing its
   baseline line.
2. `attachBytecodeToFunction(...)` returns **`false`**. Not a crash, not a
   silent `true`.
3. No `ATTACH:` diagnostic is printed, because the native returns before
   reaching any of them.
4. `loadDynamicModule(...)` throws `UnsupportedError` carrying
   `Loading of dynamic modules is not supported.`

**ON (experiment), `out/sl1_dm_on`**

1. Normal AOT works, identically, and prints the same baseline line.
2. `attachBytecodeToFunction(...)` returns **`true`**, and the native's own
   `DartEntry::InvokeFunction` prints `ATTACH: C++ invoke of target returned:
   NEW`.
3. Every Dart-side call shape still returns `OLD`. This is **expected** and is
   the 2026-08-04 call-emission gap, not a regression: in AOT those sites are
   statically bound. G1 does not close it, and a run that reported `NEW` from a
   Dart-side call would mean the harness, not the VM, had changed.
4. `loadDynamicModule(...)` does not throw `UnsupportedError`.

## What would falsify the pair

- OFF returning `true` from attach, or executing replaced code → the flag is not
  actually controlling the substrate, and every later gate's OFF arm is void.
- ON and OFF producing byte-identical `dartaotruntime` → the flag did not reach
  the compile, and the "matched pair" is one build measured twice.
- Either arm failing normal AOT → the substrate is broken independently of the
  question, and G2 must not proceed on it.

## What this gate deliberately does NOT claim

Nothing here is evidence about *patching real applications*, about iOS, or
about the semantic-linker design. G1 establishes only that two comparable
substrates exist and that the experiment flag is the only thing separating them.
