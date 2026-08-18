# TARGET KIND — paired control, PRECOMMIT

2026-08-17, **before the fixture is edited and before any build.**

**Hypothesis: top-level function vs instance/class member.** Not "dotted vs
undotted selector" — the dot is how the trace serialises a member's name, and
naming the evidence instead of the distinction would let a display artifact stand
in for a mechanism.

## Why a pair, and why inside `airgap_probe`

`routeb_behavioral_evidence_audit.md` found that every PROVEN iOS patched-value
success is an instance/class member, and the only target that has never rendered
its patched value is a top-level function. But the working and failing corpora sit
in **different fixtures**, so target kind is confounded with everything else about
those fixtures.

`airgap_probe` is the fixture with four proven successes. Putting both kinds in it,
patched in the same cycle and rendered on the same screen, removes every variable
except the one under test.

## A SECOND UNCONTROLLED DIFFERENCE, named now so it cannot be discovered later

The failing target's body is a **foldable constant**:

    killswitch_app   String routeBValue() => 'OLD-kill';

Every proven target uses `airgap_probe`'s deliberate anti-fold idiom — a
`DateTime.now()` guard the compiler cannot resolve:

    String value() => DateTime.now().millisecondsSinceEpoch >= 0
        ? 'OLD-rel' : '<complex>';

So the historical corpora differ in **two** ways: target kind AND body
foldability. **This experiment controls foldability by making BOTH new bodies
opaque**, isolating target kind. If target kind is refuted, body foldability
becomes the leading remaining difference and earns its own paired control —
holding kind fixed and varying only the body.

*(Note: the earlier `TPOOL_ABSENT` comparison of releases 91 vs 96 could never
have separated these — both are the same killswitch fixture with the same constant
body. It varied neither.)*

## THE FIXTURE CHANGE — bodies matched to the character

Two new targets, whose ONLY intentional difference is declaration context.
Deliberately: the member does **not** reference `this`, so the two bodies are
textually identical apart from their string literals. A member that used `self`
would reintroduce the receiver-lowering difference the producer applies, and a
failure could then be blamed on lowering rather than on kind.

    // inside class RouteBThing
    @pragma('vm:never-inline')
    String kindMember() => DateTime.now().millisecondsSinceEpoch >= 0
        ? 'OLD-MEMBER'
        : 'UNREACHABLE-MEMBER';

    // at file scope
    @pragma('vm:never-inline')
    String kindTopLevel() => DateTime.now().millisecondsSinceEpoch >= 0
        ? 'OLD-TOP'
        : 'UNREACHABLE-TOP';

Patch bodies, identically shaped:

    kindMember()   -> 'NEW-MEMBER'
    kindTopLevel() -> 'NEW-TOP'

Both carry `@pragma('vm:never-inline')`, matching the proven targets. Neither body
is foldable. The `UNREACHABLE-*` arm exists so a body that executed but took the
wrong branch is visibly distinct from one that never executed.

**Consumption:** both called from `_routeBRead()` in `initState`, exactly where
the four proven targets are called, and both results stored in state and
**DISPLAYED**. A value that is computed but not displayed is not observed — the
fixture's own comment on `_rbParam` records that lesson.

**Layout:** the fixture warns the screen already carries seven rows on a 1334 px
device. Both new rows MUST be simultaneously visible in one screenshot; a value
scrolled off-screen is not evidence.

The `param` and `two params` rows are **PRESENTATION-RETIRED for this specimen,
NOT EVIDENCE-RETRACTED.** Their proof stands where it was earned and is
unaffected by this release: `evidence/releases/38/r38_two_PARAM.png`
(`two params: PARAM-a-7`, `code patch: 1`) and release 38's verdict. Nothing here
re-tests them, and nothing here may be read as weakening them.

**The layout is NOT compressed to fit nine rows.** Shrinking text to keep proven
rows on screen would add clipping and legibility risk to the one screenshot this
experiment depends on, in exchange for re-displaying values that are not controls
for target kind. The screen is deliberately sparse, and carries exactly:

    member kind    : OLD-MEMBER / NEW-MEMBER      <- the variable
    top-level kind : OLD-TOP    / NEW-TOP         <- the variable
    route B value  : OLD-rel                      <- unchanged control
    private class  : OLD-pc                       <- unchanged control
    release / asset / assets patch / code patch   <- identity for admissibility

The calls to `paramValue` and `two` are LEFT IN PLACE and still assign their
state fields; only their two display rows are removed. That keeps the diff
presentational and avoids perturbing codegen on paths that are not under test.

**Internal control, per the audit:** `route B value` and `private class` remain
UNPATCHED and must still read `OLD-rel` / `OLD-pc` on the same screen. That is
what stops rebuilt or native patch bytes from masquerading as Route B execution —
the failure mode release 37 caught and discarded.

## THE OUTCOME TABLE, precommitted

| screen | what it licenses |
|---|---|
| **`NEW-MEMBER` + `NEW-TOP`** | **target kind is REFUTED as the cause.** Top-level functions execute their replacement on iOS. Attention moves to the second uncontrolled difference — body foldability — and to whatever else distinguishes `killswitch_probe` |
| **`NEW-MEMBER` + `OLD-TOP`**, both replacements accepted and attached | **strong evidence that top-level execution is the distinguishing failure.** The first structural property to separate the working corpus from the failing target, measured under one build with one variable |
| **both `OLD`** | **cycle INVALID for this discriminator** — Route B execution did not reproduce at all here, and nothing about target kind may be read from it. Reported as unrun, not as a negative |
| **top-level REFUSED before attach** (`target-missing`, `wrong-release`, or any non-`Ok` rc) | a DIFFERENT finding: a support boundary in the producer/binder, not the current "attaches but the old value executes" phenomenon. Would mean top-level targets never reach the runtime at all |

## Admissibility

1. both new rows visible in ONE screenshot, with `code patch: N` on the same
   screen;
2. `route B value: OLD-rel` and `private class: OLD-pc` unchanged on that same
   screen;
3. the trace/report shows BOTH targets attached — ideally `applied 2/2 targets` in
   one container. **If the producer supports only one target per container**, fall
   back to two patches on the SAME release (as release 31 did with patch 1 / patch
   2) and record that the two observations are sequential rather than simultaneous;
4. `rc=0` with `bc_post=1` and `uep_post_is_interpret_call=1` for each target —
   attachment must be established independently of the screen, so that
   `OLD-TOP` can be distinguished from "never attached";
5. release/patch identity bracketed as in every prior run: preserved bytes,
   LC_UUID asserted, patch state `Installed`.

**Attachment evidence does NOT substitute for the screen.** That is the whole
lesson of release 91: `applied 1/1`, bytecode attached, entry point moved, payload
carrying `NEW-kill`, and the app still rendered `OLD-kill`.

## Historical claims — unchanged by this precommit

* **Route B iOS end-to-end execution: PROVEN** (four independent specimens).
* **release-91 `NEW-kill`: PARTIAL** historical evidence, contradicted by stronger
  current evidence.
* **Arm A: INCONCLUSIVE.**
* **Claim 1: instrument established; positive locator not yet proven.**
