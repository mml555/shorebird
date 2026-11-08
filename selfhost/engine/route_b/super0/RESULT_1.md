# D-SUPER-1 — **B PROVEN FEASIBLE.** Both stages pass, both controls hold.

Host only. No device, no cell mint, no certified-engine change, no compatibility
pin movement, no production producer widening. The throwaway compiler
experiment was applied to the engine tree's `dart2bytecode` **source** and
removed from a checksummed backup by a trap; `git status pkg/dart2bytecode/` is
empty, `shorebirdDirectCall` occurs 0 times in the tree, and the published cell
zip is byte-unchanged.

## 1A — a dynamic module CAN reference an app `Procedure`

    warm1: APP:WARM:1        release's own code, before any patch exists
    warm2: APP:WARM:2
    after  direct   : APP:PROBE:4
    after  tear-off : APP:PROBE:5
    after  apply    : APP:PROBE:6
    C++ invoke      : APP:PROBE:3

**The observable is shared state, not the string.** `releaseTopLevel` increments
a library-private counter that `main` warms to 2 before attaching. The patch's
calls continued that count — 3, 4, 5, 6 — so the replacement reached the
release's own `Procedure` and the release's own library state. A copy carried in
the payload would have printed `APP:PROBE:1`, with an identical return shape.
A probe that only asserted `APP:PROBE` could not have told those apart.

**Negative control HELD.** With retention withheld for that one function and
nothing else:

    bytecode_reader.cc: 1172: error: Unable to find function releaseTopLevel
      in Library:'package:dynamic_modules/target_1b.dart'

the canonical retention failure. So the positive arm measures retention-backed
binding, not a reference that would have resolved regardless.

**The control took two attempts, and both failures are recorded because either
would have been reported as a result.** First, retention for app code is granted
whole-library, so there was no per-symbol line to delete — the script dropped
nothing and its own assertion stopped it before it could print a vacuous PASS.
Second, once the grant was rewritten as explicit per-member grants, it still
bound: `releaseTopLevel` carried `@pragma('vm:entry-point')`, which pins a
function independently of the dynamic interface. **The control was measuring my
own annotation.** Removing the pragma is what made it a control.

## 1B — that reference CAN carry the app object as receiver, to an EXACT target

The decisive B/C boundary.

    control virtual : C:APP-STATE     the app's own dispatch, before any patch
    after  direct   : P:APP-STATE     <-- PASS
    after  tear-off : P:APP-STATE
    after  apply    : P:APP-STATE

`P:APP-STATE` is the only outcome that is both the exact `Parent.read` **and**
the app's own `Child` instance:

    P:APP-STATE   PASS
    C:APP-STATE   virtual dispatch — the override ran
    P:UNSET       right target, WRONG receiver (D-SUPER-0's shim route)
    load error    receiver-taking external DirectCall does not bind

**Mutation arm HELD.** Replacing only the emitted operation at that one site —
`_genDirectCallWithArgs(exact, hasReceiver: true, isUnchecked: true)` swapped for
a well-formed `_genInstanceCall` — returns exactly `C:APP-STATE`. Same specimen,
same receiver, same everything else. So the `P:` result comes from the direct
call and from nothing else.

The first mutation was malformed (no receiver pushed, two arguments declared) and
segfaulted. That discriminates, but it only shows the direct call is load-bearing;
it does not demonstrate the alternative. Recorded, then fixed, because "it
crashed without my change" is a weaker claim than "it returns the override".

## What was actually added to the compiler

Fifteen lines in `visitStaticInvocation`, kept verbatim in
`s1b/direct_call_intrinsic.patch.dart`. It resolves the named library/class/member
out of `allLibraries`, pushes argument 0 as the receiver, and calls the SAME
helper an ordinary `super` call already reaches. It deliberately does **not**
resolve through the class hierarchy — the point is exact target selection — and
has **no virtual fallback**, because a fallback would turn a failed experiment
into a plausible pass.

## Verdict

> **B PROVEN FEASIBLE.** Exact super dispatch can be represented entirely inside
> the compiler-cell / tooling boundary. No replacement ABI change, no bytecode
> loader change, no VM change and no certified-runtime change is required.

`C` and `D` are now ruled out for this mechanism, on evidence rather than by
elimination: the loader already binds an external `Procedure` reference (1A) and
already accepts one that takes a receiver (1B), and the instruction was already
being emitted for ordinary `super` before this lane started.

## What is still NOT established

* **Nothing on device.** Both stages are `dartaotruntime` on macOS/arm64 against
  an AOT snapshot. The iOS arm is unrun.
* **One specimen shape.** A zero-argument instance method on a direct
  superclass. Arguments, getters (`SuperPropertyGet`), setters, deeper
  hierarchies, mixin application order and `noSuchMethod` on an absent super
  target are all unexercised. `dart2bytecode`'s own super path re-resolves
  through `hierarchy.getDispatchTarget`, and a product implementation using the
  retained `interfaceTarget` instead must be shown to agree with it — mixins are
  where those two would most plausibly differ.
* **B1 vs B2 is still open**, as ruled. The experiment used a source marker
  because it was the cheaper probe, which is evidence about probe cost and not
  about product design.
* **An oddity worth not glossing.** The harness's C++ invoke line printed
  `P:0` — it calls `probe` with no real receiver, so the direct call ran against
  a non-object and returned rather than trapping. Outside this probe's claim, but
  a product implementation would need to say what guarantees the receiver's type,
  since `isUnchecked: true` asks the runtime not to.

## Artifacts

    s1a/target_1a.dart, s1a/replacement_1a.dart, s1a/run_1a.sh   (NEGATIVE=1 for the control)
    s1b/target_1b.dart, s1b/replacement_1b.dart, s1b/run_1b.sh   (MUTATE_VIRTUAL=1 for the mutation)
    s1b/direct_call_intrinsic.patch.dart                          the throwaway change, verbatim
