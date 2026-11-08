# D-SUPER-0 — verdict: **B, conditional on one unproven fact**

Feasibility only. Nothing was implemented, no cell was minted, the certified
engine `619fdad176ff4573…` was not touched, and no device was used.

The short answer: **exact super dispatch is not expressible in anything the
Route B pipeline currently consumes, and the missing piece is in
`dart2bytecode`, not in the VM** — with one binding question that decides
between `B` and `C`/`D` and that this lane did **not** settle. It is named
below as the next probe rather than guessed at.

## Step 1 — the release kernel retains the exact target. MEASURED.

    Child.target
      SuperMethodInvocation name=value  interfaceTarget=Parent.value
      ref=root::package:corpus/main.dart::Parent::@methods::value
      printed: return super.{#lib1::Parent::value}();

    Child.targetGetter
      SuperPropertyGet     name=tag    interfaceTarget=Parent.tag
      ref=root::package:corpus/main.dart::Parent::@getters::tag

After `--aot`. The selected declaration is named explicitly, as a canonical
reference, and survives. **The information a replacement would need is present
and nameable.** Step 1 is a clean positive, and it is the only one.

## Step 2 — the compiler already has the opcode, behind a door the replacement cannot reach

`dart2bytecode`'s `visitSuperMethodInvocation`
(`pkg/dart2bytecode/lib/bytecode_generator.dart:3829`) ends in exactly the
instruction this lane wants:

    _genArguments(new ThisExpression(), args);
    _genDirectCallWithArgs(target, args, hasReceiver: true, isUnchecked: true);

So a non-virtual call to a specific `Procedure` with an explicit receiver is
**already an emitted bytecode** — `DirectCall` / `UncheckedDirectCall`. Nothing
new is needed at the instruction level.

Three facts block reaching it from a replacement, each read from the source:

1. **It requires class context.** The target is re-resolved as
   `hierarchy.getDispatchTarget(enclosingClass!.superclass!, node.name)` — a null
   assertion on `enclosingClass`, and a re-resolution that *ignores* the
   `interfaceTarget` step 1 just proved is retained. A `SuperMethodInvocation`
   in a top-level function has neither an enclosing class nor a `this` slot for
   `_genArguments(new ThisExpression(), …)` to push.
2. **No Kernel node expresses it generally.** This tree's `package:kernel` has no
   `DirectMethodInvocation` (`grep -c 'class DirectMethodInvocation' → 0`). Every
   other receiver-taking direct call — `ConstructorInvocation`,
   `RedirectingInitializer`, `SuperInitializer` — is likewise class-bound.
   `InstanceInvocation` routes to `_genInstanceCall`, which is virtual dispatch.
3. **`dart2bytecode` consumes SOURCE, not a dill.** Its input is
   `options.rest.singleOrNull` — `input.dart` — and it runs the CFE itself. There
   is no point in the current pipeline where a producer could hand it a
   transformed Kernel graph.

## Step 3 — no source-level route exists, and one of the near-misses is dangerous

Five spellings, run against the specimen. Ground truth for the target is
`PARENT`; `CHILD` is what accidental virtual dispatch yields.

    r1  super.value() in a top-level fn        REFUSED  "Expected identifier, but got 'super'"
    r2  Parent.value(self)                     REFUSED  "Member not found: 'Parent.value'"
    r3  (self as Parent).value()               RAN  ->  CHILD      <-- WRONG, and silent
    r4  extension E on Child { super.value() } REFUSED  "Expected identifier, but got 'super'"
    r5  class _Shim extends Parent { … }       RAN  ->  PARENT     <-- right value, wrong receiver

**`r3` is the finding of this step.** A cast compiles, links, executes, and
returns the override. It is the shape a naive implementation reaches for first,
and no exit code, no compiler diagnostic and no "did it run" check catches it.
This is precisely why the precommit made the *value* the observable.

**`r5` is the subtler trap**: it returns `PARENT`, which looks correct. It is
not — `super` there dispatches on a `_Shim` instance, not the app's object. With
state attached:

    shim route says : P:UNSET
    correct answer  : P:APP-STATE

Right implementation, wrong receiver. A specimen whose parent method ignored
instance state would have reported this route as working.

## Step 4 — classification

    A  existing compiler mechanism, producer/analyzer only        RULED OUT
       No source form exists (step 3) and dart2bytecode takes no dill (step 2.3).

    B  small dyn-module extension, compiler cell, no VM change    MOST LIKELY
       The instruction exists and is already emitted for ordinary super calls.
       What is missing is a way to ASK for it from a static top-level function
       with an explicit receiver. Two shapes, both confined to the cell:
         B1  give dart2bytecode a dill input path, and add a Kernel transform
             stage to the producer that rewrites the retained SuperMethodInvocation
             into a direct call carrying the receiver parameter;
         B2  a source-level marker the generator recognises, carrying the
             canonical target name from step 1, lowered to the same DirectCall.
       Both need `visitSuperMethodInvocation`'s two assumptions relaxed: use the
       retained `interfaceTarget` rather than re-resolving, and take the receiver
       from a parameter rather than from `ThisExpression`.

    C  changes the replacement ABI or bytecode loader                NOT EXCLUDED
    D  runtime/VM dispatch changes                                   NOT EXCLUDED
    E  cannot preserve exact semantics                               RULED OUT
       Step 1 proves the target is nameable, so the semantics are representable.

## The one fact that decides B against C/D — NOT established here

> **Can a dynamic module's constant pool hold a `DirectCall` to an app
> `Procedure`, and will the loader bind it at patch-activation time?**

Everything Route B binds today goes by NAME through instance dispatch, or is
carried inside the payload. A `DirectCall` entry is a reference to a specific
function, resolved through the object table. If the dyn-module loader resolves
such a reference against the already-AOT-compiled app, this is `B`. If it
cannot, the loader or the ABI has to change and this is `C`, or `D` if
dispatch itself must move.

**This lane did not test it, and the classification above is conditional on it.**
Saying `B` without that would be exactly the "compiles, therefore works"
inference `r3` and `r5` exist to punish.

The next probe is small and host-only: emit a replacement whose body makes a
static call into an app top-level function — the ordinary `StaticInvocation`
route to `_genDirectCall` — and establish whether that binds. If a plain
DirectCall into app code already works, `B` stands and the remaining work is
expressing the receiver. If it does not, super is `C` at best.

## Practical note for whoever prices this

The shape that matters in real code is not exotic. D0.4 found `super` blocking
30 methods in localsend and 43 in Wonderous, and sampling showed both are almost
entirely `initState` / `dispose` overrides — the two-line Flutter lifecycle
idiom. That is what a `B`-shaped fix would buy: 22 and 37 sole-blocked methods
respectively, 48.89% and 35.92% of each corpus's blocked population.

## Artifacts

    specimen/super_specimen.dart        Parent/Child/Loop, incl. the recursion control
    specimen/state_specimen.dart        the receiver-identity refutation for r5
    specimen/routes/*.dart              the five source routes, as run
    specimen/dump_super_targets.dart    the step-1 kernel dump
