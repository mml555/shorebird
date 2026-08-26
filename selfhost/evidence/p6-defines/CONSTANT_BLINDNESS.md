<!-- cspell:words canonicalised ALPHA precommitted -->

# A patch confined to a canonicalised constant is invisible to coverage

Found 2026-08-26 while building the P6 define arm, on an ordinary source edit.

## What happened

The precommitted target body was exactly this shape:

    String defineState() {
      const value = String.fromEnvironment('P6_DEFINE', defaultValue: 'MISSING');
      return DateTime.now().millisecondsSinceEpoch >= 0 ? 'V1/$value' : 'V1/$value!';
    }

Editing `V1` → `V2` and running the real `shorebird patch`:

    Nothing in this patch differs from the release, so it would install and
    change nothing. Nothing was uploaded.

Zero patches were created. **But the source definitely differed**, so the claim
was tested rather than believed:

    release kernel   33ad0bd362c64657
    patch kernel     d7e9ec164de0993d      <- DIFFERENT bytes
    route_b_analyze  verdict: inert, changed: [], added: []

So the kernels differ and the analyzer sees no changed member.

## Why

`value` is `const`, so `'V1/$value'` is a **compile-time constant**. The analyzer
compares members by `_text(p)` — the PRINTED procedure AST — and a canonicalised
constant prints by reference rather than by value. Both sides print identically,
so no member is `changed`.

This is the same blindness `g41d` recorded for a define-only difference
(*"`-DFLUTTER_VERSION=zzz` vs the real value reports NONE while the `.dill`s
differ by 24 bytes"*). What is new is that it is reached here by a **plain source
edit a user would make**, not by changing a define.

## The direction it fails in

**Closed.** The patch is REFUSED as inert rather than shipped as a no-op, which
is the safe direction and exactly what a patch changing nothing observable
deserves. Nothing about this is a correctness hole.

It is a **capability boundary**: a patch whose only difference lives inside a
canonicalised constant cannot be shipped, and the message says "nothing differs"
rather than "the analyzer cannot see constant-only differences". An author of
such a patch has no way to tell those apart from the message.

## Consequence for the arm, stated rather than hidden

The precommitted body shape **cannot test the REPLACEMENT link**, because a patch
of that shape never publishes. The arm's target was reshaped so the marker sits
OUTSIDE the constant:

    final live = DateTime.now().millisecondsSinceEpoch >= 0;
    return '${live ? 'V1' : 'X'}/$value';

The concatenation is now non-constant, so the marker survives as a plain
`StringLiteral` the printer shows, and `V1`→`V2` is visible as a changed member.

Every substantive property of the precommit is preserved: the define is still
read **inside the replacement** via `String.fromEnvironment`, `defaultValue:
'MISSING'` still makes a dropped define visibly different, and the load-bearing
observation is still `V2/ALPHA73`.

What changed is only the expression shape needed to make the edit *visible to the
instrument* — recorded here because adapting a precommit silently is how a
weakened arm passes.

## Debt

Two items, neither blocking:

1. The refusal message should distinguish "your patch changes nothing" from "the
   change is inside a constant this analysis cannot compare". The second is
   actionable; the first is not.
2. Whether a constant-only body change is worth supporting at all is a separate
   question. It would need the analyzer to compare constant VALUES rather than
   printed references, and nothing so far shows a real patch needs it.
