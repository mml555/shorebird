# D-SUPER-2A.2 — **PASS.** Local re-derivation works; B2 is the shape.

Host only. Nothing productised. The throwaway compiler change was applied to the
engine tree's `dart2bytecode` **source** and restored from a checksummed backup
by a trap: `git status pkg/dart2bytecode/` is empty and neither intrinsic name
occurs in the tree.

## Leg 1 — cross-kernel provenance fingerprint

    corpus              sites   fingerprint   fingerprint   canonical names
                                  match        mismatch      that DIFFER
    synthetic shapes       10       10            0              1
    Wonderous              44       44            0              8
    localsend              30       30            0              0

**84 real sites and 10 synthetic controls all converge, with zero
unavailable.** Nine of them have *different canonical names* across the two
kernels — the D-SUPER-2A finding — and that is precisely what the fingerprint is
built not to depend on.

The fingerprint is source provenance only: `fileUri | fileOffset | name | kind`.
It deliberately **excludes the enclosing class**, because including it would
reimport the transformed identity the design is trying to become independent of.
Dart has no overloading, so a file offset plus a name and kind identifies exactly
one declaration.

The mixin case is the one that matters, and it now reads:

    MixLoud.go
      AOT   fp : …/main.dart|2268|read|Method
      import fp: …/main.dart|2268|read|Method       <-- identical
      AOT   cn : dart:mixin_deduplication::_MixinApplication1&MixB&LoudMixin::read
      import cn: package:corpus/main.dart::_MixLoud&MixB&LoudMixin::read

**A mixin-application member is a clone, and the clone keeps the provenance of
what it was cloned from.** That was the hypothesis; it is now measured.

Two tool corrections, both of which had been silently excluding a case:

* **Private super targets were reported "not comparable".** A private `Name`
  carries a library *reference*, and the AOT component's reference does not match
  the import component's library object. Rebuilding the name against the
  component being queried makes `PrivChild.go` measurable — it now matches. It
  was not a finding about private members; it was the tool declining to look.
* **Arity was in the fingerprint and had to come out.** See leg 3.

## Leg 2 — execution, with NO identity transported

The intrinsic carries only origin class + member name. `dart2bytecode` resolves
the target with the import kernel's own `hierarchy.getDispatchTarget` — the same
machinery ordinary `super` compilation already uses.

    mixGo   MixLoud extends MixB with LoudMixin, BOTH declare `read`
              unpatched super call : MIXIN:APP-STATE
              virtual dispatch     : MIX-LOUD:APP-STATE
              patched replacement  : MIXIN:APP-STATE      PASS

    deepGo  DeepC extends DeepB extends DeepA, DeepB declares NOTHING
              unpatched super call : DEEP-A:APP-STATE
              virtual dispatch     : DEEP-C:APP-STATE
              patched replacement  : DEEP-A:APP-STATE     PASS

The baseline is **the unpatched program's own super call**, not an expectation.
Every competing implementation is stateful, so a right-value/wrong-object result
cannot pass — the failure mode that nearly passed in D-SUPER-0.

`deepGo` is the `_AnimatedCloudsState` control in miniature: the selected
implementation is **not** on the immediate syntactic superclass. The rule has to
be "the implementation the hierarchy selects", and it is.

**Mutation arms held.** Swapping only the emitted operation for a well-formed
virtual call returns `MIX-LOUD:APP-STATE` and `DEEP-C:APP-STATE` — the override,
in both cases. So the passes come from the direct call.

## Leg 3 — a NEW unsoundness in the planned v1 gate

Found while removing arity from the fingerprint. It is not about mixins, and it
matters more than the fingerprint question.

TFA **specialises a callee for its call sites**. Measured on `ArgParent.tag`:

    import kernel   method tag(String a, int b) → String    …"ARG-P:${a}:${b}"…
                    ArgChild.go: return super.{ArgParent::tag}("a", 7);

    AOT kernel      method tag() → String                   …"ARG-P:${#C4}:${#C5}"…
                    ArgChild.go: return super.{ArgParent::tag}();

The two arguments are frozen into the body as constants, the parameters are gone,
and **the super call site in the AOT kernel passes zero arguments while the
source passes two.**

> **The v1 slice is "zero positional arguments". Read from the AOT kernel — which
> is the kernel the analyzer reads — that gate would ACCEPT
> `super.tag('a', 7)`.** The replacement is then compiled from source against the
> import kernel, where `tag` takes two parameters.

So the zero-argument refusal must be established from the **source span** or the
import kernel, never from the AOT call site's argument count. D-SUPER-1B and
2A both missed this because neither had a super call with arguments in a shape
TFA chose to specialise.

Also recorded: the AOT dill's function *signature* is not the release's source
signature. Any future rule that compares arity across the boundary has the same
exposure.

## Where this leaves the design

* **B2 is the shape.** Transport a source-level site description; resolve locally.
  B1 would have required reconciling two differently transformed Kernel graphs,
  which is the problem 2A found.
* **Mixin deduplication no longer has to be solved or depended on.** Nothing
  crosses the boundary that it renames.
* **The arg0 receiver rule is unaffected** and still required.

## What is still NOT established

* Nothing on device.
* Only `SuperMethodInvocation` with zero arguments was executed. Getters, setters,
  arguments and generics remain refused and unexercised.
* The eight real Wonderous sites were not individually executed. Their equivalence
  rests on the fingerprint plus the two synthetic execution arms, which is the
  chain the ruling accepted — not on observing eight widget lifecycles.
* The v1 argument gate now needs a stated source of truth (source span or import
  kernel) and a control proving it refuses `super.tag('a', 7)`. That control does
  not exist yet.

## Artifacts

    s2a/target_equivalence.dart      census tool, spans both kernels
    s2a/{shapes,wonderous,localsend}.equiv.txt
    s2a2/target_2a2.dart             stateful mixin + deep-hierarchy specimen
    s2a2/replacement_{mixGo,deepGo}.dart
    s2a2/run_2a2.sh                  WHICH=mixGo|deepGo, MUTATE_VIRTUAL=1
