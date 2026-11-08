# D-SUPER-2A — **STOP.** The two derivations of "the super target" disagree.

Host only. Nothing implemented. Per `../PRECOMMIT.md`'s gate and the standing
ruling, a mismatch is a stop, not something to normalise.

    corpus                sites   mismatch WITHIN the AOT dill   mismatch ACROSS dills
    synthetic shapes         10          0                         1
    Wonderous                44          0                         8   (18%)
    localsend                30          0                         0

**Within one kernel the two agree everywhere — 84/84.** The divergence is
entirely *across* the two kernels, and the product pipeline uses both:

    interfaceTarget      read by the analyzer from the RELEASE's --aot --tfa dill
    getDispatchTarget    computed by dart2bytecode while compiling the
                         replacement against the --no-aot --import-dill kernel

Comparing only inside one dill would have reported a clean 84/84 pass. That is
why the tool was built to span both.

## The mechanism: AOT mixin deduplication renames the target's owner

    _HomeScreenState.dispose
      superclass : _MixinApplication279&State&SingleTickerProviderStateMixin
      AOT        : dart:mixin_deduplication::_MixinApplication279&State&
                     SingleTickerProviderStateMixin::Method::dispose
      import     : package:wonders/…/wonders_home_screen.dart::
                     __HomeScreenState&State&SingleTickerProviderStateMixin::Method::dispose

The AOT pipeline hoists mixin-application classes into a synthetic
`dart:mixin_deduplication` library under renumbered names; the import kernel
keeps them in the declaring library under a different synthetic name. **The
canonical identity of a mixin-application member is not stable between the two
kernels.**

And in one case it is not only a rename:

    _AnimatedCloudsState.dispose
      superclass : _MixinApplication361&State&SingleTickerProviderStateMixin&GetItStateMixin
      AOT        : _MixinApplication360&State&SingleTickerProviderStateMixin::dispose

The retained target lives in a **different, shorter** mixin application than the
enclosing class's own superclass — deduplication collapsing chains onto the
nearest application that declares the member.

Two mismatches are not `State` at all but Flutter's own render tree
(`RenderBlendMask.paint`, `MeasureSizeRenderObject.performLayout` →
`_RenderProxyBox&RenderBox&RenderObjectWithChildMixin&RenderProxyBoxMixin`), so
this is not specific to app code.

## Why this hits exactly the slice that was about to be built

Every Wonderous mismatch is `super.dispose()` on a `State` subclass using
`SingleTickerProviderStateMixin`, or the render-object equivalent. D0.4's whole
argument for `super` was the `initState`/`dispose` lifecycle idiom. **A v1 that
carried the AOT-side canonical identity into the intrinsic and asked
`dart2bytecode` to resolve it in the import kernel would fail on 8 of 44
Wonderous super sites — and specifically on the ones that motivated the lane.**

D-SUPER-1B did not catch this because its specimen was plain class inheritance:
`class Child extends Parent`, no mixin. The intrinsic resolved a name that
happens to be stable for that shape.

## Which Procedure actually executes — answered for the synthetic case only

The gate requires running the original unpatched program rather than reasoning.
For the synthetic mixin-with-override shape:

    MixLoud().go()   ->   MIXIN

so the executing target is the mixin's `read` as installed into the mixin
application — not `MixB.read`. Both candidate identities name a `read` declared
in an application of `MixB` with `LoudMixin`, so on this shape the divergence
**looks like** an identity/naming divergence rather than a different executing
target.

**That is a reading, not a result, and it is not established for the eight real
sites.** Establishing it there needs the unpatched app observed per site, which
this lane did not do.

## Design implication — stated as implication, not as a fix

The mismatch is not evidence that `interfaceTarget` is wrong. It is evidence
that **a canonical string derived from one kernel is not a valid key in the
other.** Which points away from the shape D-SUPER-2B was going to take:

* carrying the AOT canonical target name in the intrinsic is unsound across the
  mixin surface;
* the analyzer could instead report a **structural** description — enclosing
  class, member name, shape — and let `dart2bytecode` re-derive the target in the
  kernel it is actually compiling against, which is what its existing
  `hierarchy.getDispatchTarget` already does;
* that would make the intrinsic's job "confirm the site is a real
  `SuperMethodInvocation` with an exact target, and supply the receiver",
  leaving target selection where it already works.

None of that is proven. It is the next question, not the answer.

## What must be settled before D-SUPER-2B

1. Whether the two identities name the same executing Procedure on the **real**
   mixin sites, observed rather than inferred.
2. Whether a structural (re-derive locally) rule agrees with `interfaceTarget` on
   all 84 sites — the same census, inverted.
3. Whether mixin deduplication is stable enough to be relied on at all, or
   whether the product rule must be independent of it.

## Corpus sensitivity, worth noting for scoping

localsend: **0 of 30**. Wonderous: **8 of 44**. The same divergence that would
have broken v1 is invisible in one of the two real corpora — which is the same
lesson D0.4 taught about tear-offs, arriving from a different direction.

## Artifacts

    s2a/target_equivalence.dart   the census tool (spans both kernels)
    s2a/shapes.dart               nine inheritance shapes + recorded ground truth
    s2a/shapes.equiv.txt          synthetic result
    s2a/wonderous.equiv.txt       44 sites, 8 cross-dill mismatches
    s2a/localsend.equiv.txt       30 sites, clean

## Reproduce

    dart --packages=<engine>/third_party/dart/.dart_tool/package_config.json \
      s2a/target_equivalence.dart --aot-dill <release.dill> \
      --import-dill <import.dill> --platform <platform.dill> --include <prefix>

Exits non-zero on any mismatch.
