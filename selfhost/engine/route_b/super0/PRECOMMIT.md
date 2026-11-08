# D-SUPER-0 — exact superclass dispatch: feasibility and design only

**No implementation commitment. No certified-runtime change. No cell mint.**
The deliverable is a classification, not a mechanism.

## The question

    @override
    void dispose() {
      controller.dispose();
      super.dispose();
    }

must NOT become

    void replacement(dynamic self) {
      self.controller.dispose();
      self.dispose();          // WRONG — virtual dispatch re-enters the override
    }

The required semantics are *invoke the specific superclass implementation the
release's `super` expression selected*, not normal virtual dispatch. That is a
different problem from receiver prefixing, which is why `ROUTE_B.md` refuses it
as its own kind of thing rather than as a missing case.

## Order of investigation, fixed in advance

Each step is answered before the next is taken, so a later "it works" cannot be
credited to an assumption made earlier.

1. **Kernel representation.** What does the RELEASE kernel actually retain for
   `SuperMethodInvocation` / `SuperPropertyGet` after `--aot --tfa`? Is the
   selected declaration named explicitly, and does it survive?
2. **dart2bytecode capability.** Build the smallest specimen that attempts exact
   super dispatch and hand it to the compiler *before modifying anything*. Does a
   non-virtual invocation route already exist?
3. **Replacement context.** Must a replacement stay a synthetic top-level
   function? Kernel being able to represent a super call does NOT imply the
   dyn-module entry-point contract can carry one. These are separate facts and
   are established separately.
4. **Only then, cost.**

## Classification, precommitted

    A  existing compiler mechanism — producer/analyzer only
    B  small dyn-module extension — new compiler-cell patch, no VM change
    C  requires changing the replacement ABI or bytecode loader — engine lane
    D  requires runtime/VM dispatch changes — touches certified assumptions
    E  cannot preserve exact Dart semantics safely — stays refused

## The negative control, and why it is the whole experiment

    class Parent {
      String value() => 'PARENT';
    }

    class Child extends Parent {
      @override
      String value() => 'CHILD';

      String target() => super.value();
    }

    target() must observably yield  PARENT
    a mechanism that yields         CHILD   is a HARD FAILURE

`CHILD` is what accidental virtual dispatch returns, and it compiles, links and
executes. A specimen that only checks "did it run" would pass. So the control is
the value, not the exit code.

A second control makes the wrong answer impossible to survive: an override whose
body calls the target, so a mistaken `self.foo()` **recurses** rather than
returning a plausible string. A mechanism cannot look acceptable by accident when
the wrong answer is a stack overflow.

## The frozen rule, applied here

    ACTION       request exact super dispatch
    OBSERVABLE   the specific PARENT implementation executes and its value is read
    FAIL-CLOSED  anything that cannot prove exact target selection publishes no patch

## Out of scope, stated so it cannot drift in

* No implementation of super support.
* No change to the certified engine `619fdad176ff4573…`, no cell mint, no device.
* P1.5's demand question stays closed. D0 answered the structural question; this
  lane asks only whether the mechanism is tractable and at which layer.
