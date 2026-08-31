# D-SUPER-2B.1b — analyzer v10. PASS. No supported surface widened.

Host only. The objective was **not** to make `super` work. It was to let the
analyzer describe `super` without creating even a temporary acceptance path
before the producer exists.

## State after this commit

    analyzer        describes a genuine super METHOD site structurally
    CLI             understands analysisVersion 10
    producer        REFUSES any reported super site, explicitly
    dart2bytecode   mechanism proven in a harness only (2B.1a); not wired

## What version 10 reports, and what it deliberately does not

    'origin': { library, class, member, memberKind }
    'superInvocations': [ { offset, member, kind } ]

`memberKind` travels with the name because a class may hold a method, a getter
and a setter of one name — name plus class is not an identity. Cheap now; an
implicit assumption later.

**Nothing transformed and nothing AOT-derived crosses the boundary**: no resolved
target, no declaring class, no signature, no argument count. Each was
disqualified by measurement — mixin deduplication renames the target's owner
(2A), and TFA rewrites `super.tag('a', 7)` to zero arguments *in this very
kernel* (2B.0). The entry's key set is asserted to be exactly
`{offset, member, kind}`, so a future field cannot be added without a test
failing.

## One construct, one report

Before v10 a single `super.dispose()` produced **two** refusals: the super one,
and a synthetic `uses this other than to read a member` from the `ThisExpression`
the CFE puts inside every super node. That double-reporting is what made `super`
show 0% marginal unlock in the first D0.2 reading while inflating the `this`
category with 43 methods that were really super calls.

v10 skips a `ThisExpression` whose parent is a `Super*` node — the super
operation's own receiver, already accounted for.

## Controls — 28 clauses, all passing

    t1  super.dispose()        one entry; NO super reason; NO synthetic
                               unconsumed-this; unsupported empty; entry keys
                               exactly {offset, member, kind}; origin correct
    t2  super.tag('a', 7)      one entry; claims NO arity
    t3  this.helper()          unchanged: one `invoke` access, nothing refused
    t4  sink.take(this)        unchanged: the escape is still refused
    t5  super.acc  (getter)    still `unsupported`; NOT a superInvocation
    t6  super._hidden()        private site reported like any other
        offsets                real source positions, not placeholders

## Regression

    coverage/parity.sh                       8 passed, 0 failed
    analysis document vs the v9 baseline     8/8 semantically identical, once
                                             `analysisVersion`, `origin` and
                                             `superInvocations` are normalised
    route_b_* CLI suites                     111 passed
    producer + coverage suites               78 passed (incl. the new gate test)
    census construct tables                  byte-identical to the banked D0.4
                                             numbers on all three corpora

The census keeps counting a reported super site as a blocker, because it measures
what the PRODUCT can lower, which is a different question from what the analyzer
can describe. Without that, D0.4's numbers would have moved with no change in
what a user can actually patch.

## TFA erased a control TWICE, and that is the finding worth carrying

The `this`-escape control (`t4`) reported that the refusal had disappeared. It
had not — the specimen had.

    v1  `Sink.take(Object o)` ignored `o`
        -> TFA specialised it to take no parameters and dropped the `this`
           argument from the call site
    v2  used `o is Child`
        -> TFA folded that to `true` (every call site passes a Child) and
           dropped the parameter again
    v3  stores `o` and reads `o.hashCode`
        -> neither foldable nor removable; the control finally measures

So the `unconsumed_this` refusal has the **same** exposure 2B.0 found for super
arguments: it is derived from the AOT kernel, and TFA can erase the construct it
is watching for.

**Measured, not assumed:** unlike the argument case, this one is loud downstream.
A bare `this` in a synthetic top-level replacement does not compile —
`Error: Expected identifier, but got 'this'`. So an erased escape fails at
compile time rather than shipping. Recorded because the next AOT-derived gate
someone adds may not have that backstop.

## What is NOT done — 2B.1c

* The producer emits no intrinsic. Nothing calls `routeBSuperCallArgs` in the
  patch path.
* The cross-gate mutation (force `routeBSuperCallArgs` to `zeroArguments`, then
  confirm the compiler still refuses) still cannot run — it needs the producer
  path. The compiler half stands from 2B.1a.
* Getters, setters, arguments and generic super invocations remain refused.

## Reproduce

    # v10 contract controls
    <analyzer> --base-dill base.dill --patched-dill patched.dill --out a.json
    python3 selfhost/engine/route_b/super0/s2b1b/check_v10.py a.json
