# D-SUPER-2B.1a — compiler backstop. PASS, and it is independent.

Host only. `0015` is applied to the engine tree's `dart2bytecode` **source** by
`apply_0015.py` and restored from a checksummed backup by a trap:
`git status pkg/dart2bytecode/` is empty and `_shorebirdDirectSuper` occurs 0
times in the tree. No cell, no device, no certified-runtime change.

**This is half of 2B.1.** The analyzer v10 contract and the producer wiring are
NOT done — see the end. Nothing in the shipping CLI emits this intrinsic yet, and
`analysisVersion` is still 9.

## The intrinsic carries site identity, never an argument count

    routeBSuper(receiver, originLibrary, originClass, originMethod,
                siteOffset, member)

An `argumentCount: 0` field would have been the producer asserting its own
correctness for the compiler to check against itself: a producer bug that turns
`super.tag('a', 7)` into an argument-free intrinsic writes 0 into that field too.
So the intrinsic carries enough origin/site identity for `dart2bytecode` to
**rediscover the original `SuperMethodInvocation` in its own import kernel** and
establish the shape itself.

Recognised by **pragma** (`shorebird:direct-super`), not by an identifier, so the
producer's chosen spelling is not the contract.

Nothing transformed crosses the boundary: no AOT canonical target, no AOT arity,
no `dart:mixin_deduplication` name.

## The eight conditions, all refusing rather than falling back

    1  enclosing member carries `dyn-module:entry-point`
    2  the intrinsic is directly in the entry point body, not in a closure
    3  receiver is EXACTLY positional parameter 0
    4  origin library / class / method resolve in the import kernel
    5  exactly ONE super site at the given offset
    6  that site's member matches the one named
    7  zero positional, named and type arguments — read from the IMPORT kernel
    8  the local hierarchy has a dispatch target

There is no virtual fallback on any path. Every failure throws.

## Host matrix

    arm      origin                     result
    lifeGo   LifeState.original         TICKER:APP-STATE      PASS
             (extends LifeBase with TickerLike; both declare `close`)
               unpatched super : TICKER:APP-STATE
               virtual         : STATE:APP-STATE
    deepGo   DeepLeaf.original          DEEP-BASE:APP-STATE   PASS
             (DeepMid declares nothing)
               unpatched super : DEEP-BASE:APP-STATE
               virtual         : DEEP-LEAF:APP-STATE
    argGo    ArgLeaf.original           REFUSED               PASS
               "super.tag takes arguments (2 positional, 0 named, 0 type)"

`lifeGo` is the Wonderous `super.dispose()` shape — a mixin application where AOT
deduplication renames the owner — and the baseline is the unpatched program's own
super call, not an expectation. Every competing implementation is stateful.

`argGo` is the specimen from 2B.0: the AOT kernel reports **zero** arguments for
that site. The refusal message names two, because it is read from the import
kernel, which holds the unspecialised body. **This is the compiler establishing
the shape independently of both the producer and the AOT kernel.**

## Adversarial arm — the shape check is what refuses

Disabling condition 7 and nothing else:

    compiler ACCEPTED the argument case
    consequence: the replacement compiled and then ABORTED at run time

The emitted direct call passes only the receiver while `tag` expects two more.
So the backstop is not decoration: without it, a producer bug yields a patch that
compiles, publishes, and kills the process.

The observable is compiler **acceptance**, not a return value. An earlier version
of this arm reported "became reachable ()" with an empty value, which was the
right conclusion stated uninformatively.

## Two harness faults found, both of which had produced a wrong reading

* **A hardcoded library prefix.** `dump_sites.dart` only scanned
  `package:corpus/`, so the specimen in `package:dynamic_modules/` yielded zero
  sites and the caller read that as a missing offset. Now a parameter.
* **The entry-point check refused everything.** Comparing `enclosingMember`
  against `dynModuleEntryPoint` is order-dependent: that field is populated on
  the DECLARATION path, which does not necessarily run before a body is
  generated. All three arms refused with "used outside the dynamic-module entry
  point" — **including `argGo`, which therefore looked like a PASS for the wrong
  reason.** Had the two positive arms not been in the same run, that false pass
  would have been banked. The check now asks the enclosing member for its own
  pragma, which is the property actually wanted and is order-independent.

## What is NOT done, and is the rest of 2B.1

* **Analyzer v10.** The analyzer still refuses every super site;
  `analysisVersion` stays 9. It does not yet report
  `kind: superInvoke` with origin library / class / method / site offset.
* **Producer wiring.** Nothing calls `routeBSuperCallArgs` in the patch path, and
  nothing emits the intrinsic. The replacement sources in this matrix are written
  by the harness, which is what isolates the compiler gate — and also means the
  end-to-end path does not exist yet.
* **The required cross-gate mutation** (force `routeBSuperCallArgs` to return
  `zeroArguments`, then confirm the compiler still refuses) cannot run until the
  producer path exists. The compiler half of that claim is established here: the
  backstop refuses `argGo` on evidence it derives itself.
* Getters, setters, arguments and generic super invocations remain refused and
  unexercised. Private super targets are handled in the code (the `Name` carries
  the library for a private member) but are not in this matrix.

## Artifacts

    ../0015-dyn-module-direct-super-intrinsic.patch.dart   reviewable record
    s2b1/apply_0015.py        applies/verifies anchors, hard-errors on drift
    s2b1/target_2b1.dart      three shapes, all stateful
    s2b1/run_2b1.sh           NO_BACKSTOP=1 for the adversarial arm
