# D-SUPER-2B.1d — patched-import → release-AOT binding WORKS, with one new limit.

Host only. `0015` stays **UNSOUND AS DESIGNED**; this probe does not repair it.
Its lookup *code* is unchanged here — only which dill it reads — which is exactly
why the new import relationship had to be proven rather than declared.

    arm                                              obs1-4   obs5 bind   obs6 execute
    A  ordinary hierarchy                              PASS      PASS      PARENT:APP-STATE
    B  mixin lifecycle (release HAS the super site)     PASS      PASS      TICKER:APP-STATE
    C  mixin lifecycle, site INTRODUCED by the patch    PASS      FAIL      —
    D  ordinary hierarchy, site INTRODUCED by the patch PASS      PASS      PARENT:APP-STATE

Virtual mutation, direct call swapped for instance dispatch, all four arms:
`CHILD` / `LEAF` / `LEAF` / `CHILD` — the override, as required. So every pass
above comes from the direct call.

## The architecture is viable

Compiling the replacement against a **patched no-AOT import kernel** and
re-deriving the super target there produces a `DirectCall` that binds against the
already-built release AOT and executes the exact implementation on the app's own
stateful receiver. Arm B is the load-bearing one — the mixin lifecycle shape, and
the place AOT and no-AOT identities diverged in 2A.

`obs1` holds on every arm: the offset the analyzer reads from the patched AOT
kernel is the same offset in the patched no-AOT kernel (682 / 988 / 988 / 682).
That is the property the corrected design needs, and it is the one 2B.1c-SITE
showed does *not* hold across source versions.

**Canonical-name equality was not required and was not obtained.** The compiler
selected a target whose owner is `_Leaf&Base&Ticker` — the patched import
kernel's own synthetic mixin-application name — and it bound to the release AOT
regardless:

    selected …/target.dart|672|close|Method owner=_Leaf&Base&Ticker

So no canonical-string bridge is needed. The loader maps the reference by
something other than that name.

## The new limit — and it corrects a claim I made in 2B.1c-SITE

    ../s2b1site/RESULT.md said the correction "also removes a limitation nobody
    had noticed: a patch may legitimately INTRODUCE a super.foo() call where the
    release body had none."

**That is half wrong, and arm C is the half.**

    arm D  ordinary superclass, introduced site   BINDS
    arm C  mixin-application copy, introduced     DOES NOT BIND

Arm C's failure is not a refusal. It is a runtime abort inside the release:

    compiler.cc: 1152: error: Attempt to compile function
      package:dynamic_modules/target.dart__Leaf&Base&Ticker@…_close

The mixin-application copy of `Ticker.close` is **retained by name and has no
compiled code**. In arm C's release the only call to `close` is virtual and
always dispatches to `Leaf.close`, the override — so nothing ever reached the
mixin's copy and AOT emitted no code for it. A `DirectCall` to it then asks an
AOT runtime to JIT-compile a function, which it cannot do.

Arm B passes precisely because its release body *does* contain
`super.close()`, which forced that copy to be compiled.

Arm D passes because `AParent.read` is an ordinary virtual dispatch target and is
compiled regardless.

So the constraint is not about source versions at all:

> **The exact super target must have COMPILED CODE in the release AOT.**
> Retention as "dynamically callable" does not imply that. For an ordinary
> superclass method it is usually satisfied; for a mixin-application copy that
> the release only ever shadowed, it is not.

The virtual mutation makes the mechanism unambiguous: with instance dispatch,
arm C runs fine and returns `LEAF:APP-STATE`. Only the direct call needs code for
the exact target.

## What this means for the product

* The corrected import relationship is proven for the shapes that matter, so B2
  can proceed on it — after the wiring is actually changed, which this probe did
  not do.
* **A new admission condition exists and is not yet implemented anywhere:** a
  patch that introduces a super call must be refused when the release has no
  compiled code for the exact target. Nothing in the analyzer, producer or
  compiler currently detects this; today it is an abort inside the user's app.
* Whether that condition can be turned into a *positive* capability — forcing the
  release to compile such targets, e.g. by widening retention or an entry-point
  pragma on mixin-application members — is unprobed. It would be a release-side
  change, not a patch-side one, and it is the natural next question.

## What is still open

* No product wiring changed. `0015` still reads the release import kernel.
* The cross-gate mutation stays invalid until the wiring is corrected.
* The four-member TFA contamination in `s2b1c/` is untouched.
* Nothing on device.

## Reproduce

    WORK=/tmp/1d                  bash super0/s2b1d/run_2b1d.sh   # arms A-D
    MUTATE_VIRTUAL=1 WORK=/tmp/1m bash super0/s2b1d/run_2b1d.sh   # override control

The first exits non-zero on arm C, which is the finding.
