# D0.1 — `self` hygiene: adversarial controls

> **OUTCOME: UNSAFE, and then repaired.** This precommit stands as written; the
> first run's verdict is in the D0.1 section of the git history (`5d02d468`) and
> the repair that followed is in `RESULT.md`. Cases F–K were added with the
> repair and are *not* covered by the precommitted expectations below — that is
> stated here rather than backfilled into the table.

**Written before any control was compiled or run. No fix is attempted in this
step; the only deliverable is a verdict.**

## What is being tested

`RouteBProducer` lowers an instance method into a synthetic top-level function
by inserting a receiver parameter it names `self`:

    route_b_producer.dart:640   edits.add((open + 1, 0, '$receiverType self$separator'));

and then rewriting every receiver access reported by the analyzer as a text
insertion at that access's source offset:

    route_b_producer.dart:726   edits.add((access.offset, 0, 'self.'));

`self` is a hardcoded identifier and no hygiene mechanism was found in either
the producer or the analyzer: no shadowing check, no collision check against
the method's own parameters, no scope model at all. `_ReceiverUses`
(`analyze_coverage.dart:654`) is a plain `RecursiveVisitor` and does not track
lexical scope.

So the question is what happens when the **user's own source already contains
an identifier named `self`** in a scope that encloses a receiver access.

## Why this runs ahead of the census

If the producer can emit an accepted, compiling replacement in which an
inserted `self.` binds to a user-authored `self` rather than to the receiver,
that is a **silent wrong-code defect** — the class of failure this project
exists to prevent. Ranking coverage blockers would then be ranking which
feature to add to a producer that can already emit wrong code.

## Precommitted verdict definition

    SAFE    the case is REFUSED before publication
            OR the emitted replacement demonstrably preserves the original
            receiver semantics

    UNSAFE  the pipeline ACCEPTS, and the emitted replacement binds an inserted
            receiver reference to a user-authored `self`, so it can compile
            into different semantics than the source it stands in for

    LOUD    the pipeline accepts but the emitted replacement FAILS TO COMPILE
            on a name collision

`LOUD` is recorded but is **not** the dangerous outcome. A build failure names
itself. The dangerous outcome is accepted + plausible + wrong.

## Escalation rule, precommitted

**If any case returns UNSAFE, D0.2 (the census) is not the next priority.**
The lane becomes `D-HYGIENE — correctness defect` and it precedes all coverage
expansion. This is written down now so the result cannot be re-read later as
"a known limitation".

## The five controls

Each is a `base.dart` / `patched.dart` pair in the parity corpus shape. The
target is an instance method whose patched body contains a receiver access
**and** a user-authored `self` in an enclosing scope. Two distinguishable
values are in play so a mis-binding is visible rather than merely different:

    receiver  Shadow.label  -> 'RIGHT-RECEIVER'
    impostor  Other.label   -> 'WRONG-OTHER'

Both classes carry a `label` getter, so a mis-binding **compiles**. That is
deliberate: a case where the wrong binding failed to resolve would prove
nothing about the dangerous direction.

| case | shape | where the impostor `self` is bound |
|---|---|---|
| A `local_self_body` | `final self = other; return label;` | local in the method's own top-level block |
| B `closure_param_self` | `items.map((self) => label)` | closure parameter |
| C `closure_param_self_used` | `items.map((self) => self.foo + label)` | closure parameter, also used by the author |
| D `target_param_self` | `String tagged(String self) => … label` | the target method's own required positional (G3.7) |
| E `closure_local_self` | `() { final self = other; return label; }` | local inside a nested closure |

A and D are expected to collide in the same scope as the inserted parameter and
so are expected `LOUD`. B, C and E open a **new** scope, where a shadow is
legal Dart — those are where `UNSAFE` is possible. That expectation is recorded
so that a surprise in either direction is visible as a surprise.

## What this does NOT establish

* Nothing runs on a device. The verdict is read off the **emitted replacement
  source** the producer preserves, plus a host execution of that source where
  it compiles. No claim is made about interpreter binding on hardware.
* Nothing is claimed about how often real code names a variable `self`. This is
  a correctness question, not a frequency question, and D0.2 does not answer it
  either.
