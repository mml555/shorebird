# D-PRIVATE-CONSTRUCTION-1 — can a release pre-authorise the exact private constructors its patchable methods depend on?

Answer: **yes, and the mechanism already exists.** The narrow rule carries 7 of
9 construction-bearing methods measured, and correctly refuses the 2 the
candidate introduced.

## Gate A — policy, not availability

Settled from the generator's own source rather than inferred from source use.
`gen_dynamic_interface.dart` already accepts, repeatably:

    --grant-constructor 'package:app/main.dart#_Dead.new'

and its own comment states the reason nothing is granted by default:

> Granting every constructor instead would cost **+8.35% at 200 classes**, which
> is the second reason **construction is opt-in one constructor at a time**.

Member-only retention is measured at -0.01% / +0.00% / +0.00% on three fixtures.
So `constructionWithheld` means **dynamic-module capability intentionally
withheld by policy**, not "constructor code unavailable" — and the per-constructor
opt-in Gate B needs was already designed in, not invented here.

The generator records the withheld set "so the absence is auditable and so a
regression shows up as a non-empty set rather than as silence."

## Gate B — the narrow grant, end to end

Specimen: `AppBtn.build`, Wonderous pair `56086308_002e1272`. Release evidence
is that release's own kernels; capabilities are its own generated manifest.

    1  baseline manifest
       privateClassesConstructible 0, constructionWithheld 119
       -> PRODUCER REFUSE: body constructs `_CustomFocusBuilder`, whose
          constructor this release did not retain

    2  + ONE grant: …#_CustomFocusBuilder.new
       privateClassesConstructible 0 -> 1, withheld 119 -> 118
       -> PRODUCER REFUSE, and the refusal MOVES to `_ButtonPressEffect`

    3  + the method's EXACT three: _CustomFocusBuilder.new,
       _ButtonPressEffect.new, _ButtonHoverEffect.new
       privateClassesConstructible 3, withheld 116
       -> ADMISSION PASSES
       -> the bytecode compiler SUCCEEDS

Step 2 is what proves the grant is exact rather than a class-wide unlock: one
grant moves the refusal to the next constructor by name.

**The replacement really compiles.** Not "got farther":

    replacement_0.dart      3033 bytes
    replacement_0.bytecode  5568 bytes, magic 3CBD

and the emitted source is a correct lowering —
`Widget build(AppBtn self, BuildContext context)` with `self.` prefixes and all
three private constructions intact. Run with a real cell
(`h2work/certcell`, 8/8 files) and the project's own `package_config.json`.

Two harness faults were found and fixed on the way, and neither is a product
fact: a temp `projectRoot` with no `package_config.json` made the compiler exit
254, and a missing scoped logger threw after compilation. Both were diagnosed by
teeing the compiler's own output rather than reading "exit 254" as a language
limit.

## Gate C — negative controls

| control | result |
| --- | --- |
| a different private constructor stays refused | **PASS** — step 2: refusal moves to `_ButtonPressEffect` by name |
| removing a grant refuses again | **PASS** — the baseline manifest is exactly that state |
| a class-MEMBER grant alone is insufficient | **PASS** — the baseline grants `_CustomFocusBuilder#createState`, `#builder`, `#onFocusChanged` and still refuses; also a unit test |
| a candidate-INTRODUCED construction is refused | **PASS, found in real history** — see Gate D |

The last one is the one that matters, and it did not have to be manufactured:
two real historical changes introduce a construction their release version did
not have.

## Gate D — the payoff, quantified

For every changed method carrying a private construction, the release's own
version of that same method was measured by running the v12 analyzer REVERSED
(base and patched swapped), so "what the release method depended on" is measured
rather than assumed.

    PRE-EXISTING (exact deps already in the release method)   7
    CANDIDATE-INTRODUCED                                      2
    unverifiable                                              0

    _ArtifactScreenState.build          4 needed, 4 in release   PRE-EXISTING
    AppBtn.build (56086308_002e1272)    3 needed, 3 in release   PRE-EXISTING
    _CollapsingCarouselItem.build       1 needed, 1 in release   PRE-EXISTING
    _InfoColumn.build                   1 needed, 1 in release   PRE-EXISTING
    CollectibleFoundScreen._buildDetail 1 needed, 1 in release   PRE-EXISTING
    _IntroScreenState.build             4 needed, 4 in release   PRE-EXISTING
    _WonderEventsState._buildTwoColumn  3 needed, 3 in release   PRE-EXISTING
    AppBtn.build (b45e16fc_e6b9a28a)    3 needed, 2 in release   INTRODUCED _ButtonHoverEffect.new
    _HomeMenuState._buildIconGrid       1 needed, 0 in release   INTRODUCED _GridBtn.new

So the narrow rule — *a patch may reuse an exact private construction dependency
the released method already had evidence for* — would carry **7 of 9** and refuse
**2**, and the 2 it refuses are exactly the ones that would otherwise let "the
release has this class, so any future construction is allowed" creep in.

## An honest bound on the headline

D-PRODUCER-DEMAND-1 reported `private_type_reference` as 7 of 10 disagreements.
**That category is not all constructions**, and the construction rule addresses
only part of it:

    _CustomFocusBuilder  x2   private CLASS      -> construction, covered
    _InfoRow             x1   private CLASS      -> construction, covered
    _handleArtifactTap   x1   private METHOD     -> NOT a construction
    _advancedProgressPanelExtraPadding (LocalSend)
                              private TOP-LEVEL  -> NOT a construction

So roughly 3 of the 7 are the shape this milestone can fix, plus the wider Gate D
population of 9 construction-bearing changed methods. The remaining private
references are a different problem — a private method name and a private
top-level constant — and would need their own evidence, not this grant.

Reporting the 7 as if the construction rule solved it would be the "chase the
headline 7" the ruling warned against.

## What this licenses

* Gate A, B, C and D all pass. The mechanism exists, the grant is exact, the
  replacement compiles, and the negative control appears in real history.
* The rule should be **per-constructor and evidence-bound**: granted only for
  constructions the released method itself performed. Not "all private
  constructors", and not "any constructor of a class the release retained".
* It needs no new Dart support, which is why it was classed B.
* Its measured reach is 7 of 9 construction-bearing methods — real, but smaller
  than the raw `private_type_reference` count suggests.
