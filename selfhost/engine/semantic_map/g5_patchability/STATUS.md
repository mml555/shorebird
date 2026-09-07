# SM1-G5 — work in progress, NOT a gate submission

**Gate:** [#54](https://github.com/mml555/shorebird/issues/54) · updated 2026-09-07

Step 1 closeout: three further predictor defects fixed after PM review. Step 2, the
shipping `.sbrb` demonstrator, is next and nothing is scored until it has a
trustworthy positive control.

## Step 1 — predictor corrections (done)

All five defects were the same mistake in different places: asking a question
about the TARGET when the fact lives somewhere else.

**A. Exact-release retention proof.** Round 1 used
`enforced_at_load.containsKey(c)`, which only means "G4 measured this retention
class". The predictor now takes `--release-pragmas`, the annotations read off
the BUILT RELEASE KERNEL by G4's `dump_pragmas.dart`, and checks the specific
entry for each required class on that declaration. `RETENTION_UNPROVEN` now
fires 10 times on the frozen corpus, where before it could not fire at all.
Missing `--release-pragmas` is refused outright rather than defaulted.

**B. `MISSING_CAN_BE_OVERRIDDEN` reads the release, not the requirement list.**
It asked whether G4's *required* list contained the entry — which it always
does by construction, so the reason was unreachable. It now asks whether the
release kernel carries `dyn-module:can-be-overridden` on that member. It fires
on `Shape.+`, whose contract genuinely omits it.

**C/D. Body facts come from the body.** New `lib/body_references.dart` walks the
Kernel body and reports private type references, private writes and private
reads per declaration, failing closed (`refused:<Kind>`) on anything it cannot
traverse. Validated on both corpora:

    Shape.scale   private write -> _scaled          (the SETTER's body, not the field)
    useHidden     private type  -> _Hidden          (a body naming a private type)
    helperUsesHidden  private type -> _Hidden

Members *of* `_Hidden` are correctly NOT flagged — owning a private class is not
the same fact as naming a private type in a body, which is what round 1
conflated.

**E. Call-site shape is unproven, so it refuses.** `DEVIRTUALIZED_CALL_SITE` and
`INLINED_BODY` had no code able to emit them, so two of #54's named arms
silently defaulted every declaration to patchable. Deciding them needs the
release's machine code, the way SL1-G4 read dispatch-table calls out of the AOT
with llvm-objdump. Until that exists the fact is UNKNOWN and every replaceable
declaration is refused `CALL_SITE_SHAPE_UNPROVEN`.

**Owner ABI propagates.** `Box.unwrap` is no longer predicted patchable on the
strength of its own signature while `Box` is `refused:type_parameters`; it now
refuses `OWNER_ABI_SHAPE_UNSUPPORTED`.

### Result

    predicted patchable   0 of 23      coverage_diagnostic_only 0.0%

    CALL_SITE_SHAPE_UNPROVEN      14
    RETENTION_UNPROVEN            10
    ABI_SHAPE_UNSUPPORTED          9
    OWNER_ABI_SHAPE_UNSUPPORTED    3
    MISSING_CAN_BE_OVERRIDDEN      1
    PRIVATE_WRITE                  1

Zero is the correct answer while call-site shape is undecidable here: under-claim
is safe degradation, and the alternative is defaulting two of #54's arms to
patchable. It also makes the subset check trivially true, which is exactly why
it must not be scored yet — a vacuous subset proves nothing.

## Step 1 closeout — three further defects (done)

**1. The body walker was not actually fail-closed.** It extended
`RecursiveVisitor` and overrode selected node types, so any construct it did not
recognise traversed silently and the body read as clean — the exact false
negative SM1 prohibits. It now has an explicit node allowlist with everything
else landing in `defaultNode` and marking the body unsupported, and the
allowlist is **grounded by census** over both corpora rather than guessed.
Types no longer fall through at all: `defaultDartType` routes every type into
one exhaustive switch that refuses anything it does not model, and named
parameter types — previously skipped — are walked.

**2. Private reads were discovered and then ignored.** The predictor consumed
only writes and private types, and built a G3 index it never used. Every private
reference is now resolved and asked of G3 by mode:

    body reference -> exact referenced declaration -> read/write/construct
                   -> G3 grant decision -> allowed or refused

Reads that G3 grants are ALLOWED, not blanket-refused: `Shape.scaled` reads
`_scaled` and passes, while `Shape.scale` writes it and refuses `PRIVATE_WRITE`,
because for a mutable field the manifest key cannot express which mode it
authorised. An unresolvable reference fails closed.

**3. Release identity was too loose.** The predictor rekeyed G4's pragma dump as
`library#owner#name` and unioned the pragmas, so an entry on `get:x` could stand
as proof for `set:x`. New `lib/release_contract.dart` carries full identity —
library, owner, **kind**, name, vm_name — and marks any key answered by more
than one declaration `ambiguous`, which the predictor refuses rather than
merging. G4's banked tool is untouched, since that gate is closed.

Falsified in `evidence/step1_falsification.txt`: removing one node kind from the
allowlist refuses 14 of 21 bodies; making interface types fall to the default
branch refuses 16 of 21; and the release contract shows `get:perimeter`,
`set:scale` and `get:scaled` holding distinct keys, so one cannot prove
retention for another.

## Step 2 — the demonstrator (next, not started)

Rebuild on the shipping path, with success meaning THE PATCHED VALUE WAS
OBSERVED — not exit 0, not "attached":

    release source -> exact release AOT/Kernel -> changed source -> bytecode
    -> pack_patch.dart -> .sbrb -> dartaotruntime release.aot patch.sbrb
    -> program observes a deliberately changed result

The existing direct-attach probe stays recorded only as:

    DEMONSTRATOR_FIDELITY=NOT_ESTABLISHED
    SILENT_NO_EFFECT=HARNESS_OBSERVATION_ONLY

## Then, in order

3. one positive arm: release says OLD, patch must visibly produce PATCHED;
4. paired negatives on the SAME target — open/virtual, direct/devirtualizable,
   inlineable caller, and a `can-be-overridden` contract control — to ask
   whether observed patchability differs by call-site shape alone;
5. only then compute `predicted ⊆ observed`;
6. only then Wonderous + LocalSend.

Whether the call-site distinction implies `REDUCE_SCOPE` (detectable and
conservatively excludable) or `MODIFY_MAP_DESIGN` (required for soundness but
not representable per declaration) is deliberately NOT classified from the
direct-attach nulls.
