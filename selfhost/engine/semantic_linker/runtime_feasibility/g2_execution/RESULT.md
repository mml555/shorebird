<!-- cspell:words dartaotruntime dill semantic linker KBC dynmod -->
# SL1-G2 — AOT ↔ bytecode execution and shared heap identity

**Gate:** [#39](https://github.com/mml555/shorebird/issues/39) · **Tracker:** [#36](https://github.com/mml555/shorebird/issues/36)
**Run:** 2026-09-06 · **Verdict: PASS. No fatal substrate defect.**

Transcripts: [`evidence/g2_g2_on.txt`](evidence/g2_g2_on.txt) (subject),
[`evidence/g2_g2_off.txt`](evidence/g2_g2_off.txt) (control).
Instrument: [`banked_experiment/`](banked_experiment).

## The report, in the requested form

    INSTRUMENTATION NON-CAUSAL CONTROL
      G1 OFF:            reproduced line-for-line on the instrumented build
                         (attach=false, load threw UnsupportedError)
      G1 ON:             reproduced line-for-line, pool counts included
                         (attach=true, IsInterpreted 0->1, C++ invoke NEW,
                          load returned NEW, pool len=1685 / Code slots=117)
      known AOT:         knownHost -> AOT before AND after an attach (unchanged)
      known interpreted: attachTarget -> AOT before, INTERPRETED after
      nonexistent:       noSuchFunctionAnywhere -> NOT_FOUND (before and after);
                         a nonexistent LIBRARY also -> NOT_FOUND

    AOT_TO_BYTECODE:
      execution mode before:  callHandler -> AOT
      execution mode after:   PatchHandler.execute -> INTERPRETED,
                              callHandler -> AOT (still, after the round trip)
      return path:            AOT caller received 'FROM-BYTECODE' and continued

    BYTECODE_TO_AOT:
      caller:    module entry -> INTERPRETED
      multiply:  AOT (retained), and its own captured stack trace shows
                 #0 multiply (package:.../g2_host.dart:61)   <- AOT frame
                 #1 entry (file:///...m_callback.dart)        <- bytecode frame
                 no interpreted multiply frame anywhere
      result:    40, from seedA()*seedB() -- operands come from AOT functions,
                 so the module cannot constant-fold its way to a false pass

    OBJECT_IDENTITY:
      identical:          true -- identical(returned, sharedBox), not equality
      AOT retains patch:  sharedBox.held holds a patch-defined PatchPayload
      patch retains AOT:  true -- verified by identity from the module side,
                          which is the only side that can name both types
      mutation A->B:      AOT sets v=7, module's reference observes 7
      mutation B->A:      module sets v=99, AOT observes 99

    EXCEPTIONS:
      bytecode->AOT:  ModuleException(from-module) propagated OUT of bytecode
                      and was caught by AOT, carrying its patch-defined payload
      AOT->bytecode:  HostException(from-host) thrown by AOT, caught in bytecode
      finally:        host `finally` ran while a bytecode frame unwound through
                      it (HOST-FINALLY-RAN observed on both sides)
      unwinding:      after two unwindings the boundary still worked --
                      multiply(seedA(),16)=80 from bytecode, multiply(6,7)=42
                      from AOT, and multiply still reports AOT
      stack trace:    full trace across the boundary, module frames above AOT
                      frames, captured and recorded in the transcript

    FATAL SUBSTRATE DEFECT:
      NO

## The control arm says the substrate is genuinely absent, not merely quiet

On `sl1_g2_off` all six tests exit 3 with `ORACLE: callHandler -> UNSUPPORTED`.
The oracle returns its own `UNSUPPORTED` state rather than a plausible-looking
`AOT` or `NOT_FOUND`, so the ON arm's answers are attributable to the flag.

The runner asserts this **positively** — exit 3 *and* the UNSUPPORTED line. It
first scored both arms by one rule and reported the control as six failures;
"nonzero is fine" would have passed on any crash, so the expected control
outcome is now named exactly.

## What the instrument is, and why it is trustworthy here

`functionExecutionMode(libraryUri, target)` — a banked, experiment-only native
in `runtime/lib/object.cc` + `bootstrap_natives.h`. Neither is in
`VM_SNAPSHOT_FILES` (that list is `runtime/vm/` only), so the snapshot-hash
hazard `dart_route_b_trace.h` documents does not apply. It takes a **read** lock,
not a write lock: an observer that could mutate what it observes is a real
difference between an instrumented run and a plain one.

Five states that never collapse — `UNSUPPORTED`, `NOT_FOUND`, `AOT`,
`INTERPRETED`, `NO_CODE`. `NOT_FOUND` is what a typo in a library URI looks
like, and if it could satisfy "not interpreted" the bytecode→AOT test would pass
without measuring anything.

It is falsified **before** it scores anything, in a `sanity` arm that runs first:
one function whose mode is known to change, one that must not, and names that do
not exist. Without the last two, an instrument that answered `INTERPRETED` for
anything resolvable after a module load would have passed all five real tests.

Non-causality was established the same way: G1's probe re-run on the
instrumented builds reproduces G1's accepted results line-for-line, including
the object-pool counters. And G1's own artifacts were re-hashed against its
accepted manifest afterwards — all match, because G2 built into new out dirs.

## Three harness defects, none of them results

Recorded because each would have produced a false reading:

1. **The dynamic interface spelled a field as a getter.** `get:hostFinallyMark`
   fails; a getter is `get:name`, a **field** is its bare name. The CFE error
   lists the names that exist, which is how this was settled rather than guessed.
2. **`throw` never crossed the boundary.** The first module caught its own
   exception and returned a String, and the host's check "a patch-defined
   throwable reached AOT" was satisfied by a `String`. The module now throws
   uncaught and AOT does the catching.
3. **`identical` was not retained.** The identity module died at load with
   `bytecode_reader.cc:1172: Unable to find function identical in
   Library:'dart:core'` — the canonical failure killgate's Spike B
   characterised. Fixed by listing `dart:core identical` under `callable`, which
   is the **designed** retention mechanism (`dyn-module:callable` is treated
   identically to `vm:entry-point` in `FindEntryPointPragma`), not a workaround
   and not a substrate limitation.

## Boundaries — what this gate did NOT establish

- **GC safety is untested.** Forcing a collection needs
  `VMInternalsForTesting.collectAllGarbage`, which is not on the public
  `dart:_internal` surface in this lineage. Retention was proven in both
  directions by identity; it was **not** proven across a collection. That is
  #40's question and is left there rather than implied here.
- **Dart-side call sites are unchanged.** Every Dart-side shape still reaches
  the old AOT body after an attach; G2's AOT→bytecode direction works through
  the **additive** dynamic-module path (a new type at a dispatch point the
  interface declared open), which is dynmod's finding used as designed. The
  binder is not built and G2 does not claim it.
- **Host macOS/arm64 only.** No iOS, no device, no real application.

## Acceptance

- [x] AOT→bytecode→AOT proven with execution-mode evidence, not output
- [x] Bytecode→AOT proven, with a stack trace showing an AOT `multiply` frame beneath an interpreted module frame, and operands that cannot be constant-folded
- [x] Shared object identity exact (`identical`), not serialization or proxy equivalence
- [x] Cross-boundary retention and mutation, both directions
- [x] Exceptions, `finally`, unwinding, and continued use afterwards, both directions
- [x] Missing evidence fails closed — a test with no bytecode or no transcript is counted as failed, never skipped

## Routing

The substrate primitive G3 and G4 assume is **real**. Recommend `PROCEED` to
[#40](https://github.com/mml555/shorebird/issues/40), with GC interoperability
inheriting the untested boundary named above.
