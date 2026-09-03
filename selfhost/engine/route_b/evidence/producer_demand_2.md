# D-PRODUCER-DEMAND-2 — the same corpus through today's product rules

Replay of the EXACT D-PRODUCER-DEMAND-1 corpus after the private-construction
work. Nothing about the corpus was re-selected: same windows, same pairs, same
frozen dills, same generated-code exclusion, same method/commit weighting.

What changed between the two runs, and only this:

| | D-PRODUCER-DEMAND-1 | D-PRODUCER-DEMAND-2 |
|---|---|---|
| analyzer | v11 | v13, the certified `route_b_analyze.aot` from cell `cd848320…` (digest `67741a08…`) that release 142 consumed |
| release manifest | policy p2 | policy p2 **plus automatic constructor retention** |
| producer | pre-`6b4f6c42` | CLI at `efd18b89` |

Constructor grants were derived exactly as `_deriveConstructorGrants` does in the
product: run the analyzer in `--census` mode over the release's own prepass
kernel, union every `privateConstructions[].key`, sort. Nothing hand-picked,
nothing taken from the candidate. Wonderous releases granted 104–108
constructors; LocalSend releases granted 65.

## Controls

**The corpus is intact.** The v13 analyzer's `changed` sets are IDENTICAL to the
v11 ones, member for member:

    Wonderous   v11 20 entries / 8 pairs   v13 20 entries / 8 pairs   identical: True
    LocalSend   v11 253 entries / 11 pairs  v13 253 entries / 11 pairs  identical: True

(253 raw, 232 after the same generated-code exclusion.)

**The accounting is unmodified.** `producer_report.py` and `demand_report.py`
were not edited. The D2 results were fed to them through shadow work dirs whose
`pairs` and `producer` are symlinks to `pairs13` and `producer13`; every other
entry symlinks to the D1 dir.

**The D1 numbers reproduce.** Re-running the same report over the original dirs
returns 45.00% and 92.67% exactly, so a difference below is a real difference and
not a harness drift.

**A discarded first attempt.** The initial replay passed `--cell`, which D1 did
not, turning on real bytecode compilation — against release 142's platform dill
rather than each app's own frozen Flutter. It produced mass `exit 254` (135
refusals in one 137-method pair). Those numbers measure the mismatch, not the
product, and were discarded and re-run like-for-like. They are not reported.

## Result

| Metric | Before | After |
|---|---:|---:|
| Wonderous producer compatibility | 45.00% | **50.00%** |
| LocalSend producer compatibility | 92.67% | **92.67%** |
| private-construction refusals removed | — | **1 method** (Wonderous), 0 (LocalSend) |
| remaining refusal leader | fragmented | **private non-construction references** |

Analyzer-level compatibility is unchanged in both corpora (70.00% / 94.83%), so
v13 changed no analyzer verdict — the movement is entirely producer-side.

## Method-level accounting, Wonderous

D1's five producer refusals and what each became:

| method | D1 | D2 |
|---|---|---|
| `_InfoColumn.build` | refused: names `_InfoRow` | **ACCEPTED** |
| `AppBtn.build` (pair A) | refused: names `_ButtonHoverEffect` | refused — candidate-introduced construction |
| `AppBtn.build` (pair B) | refused: names `_ButtonHoverEffect` | refused — candidate-introduced construction |
| `_BottomTextContent.build` | refused: names `_handleArtifactTap` | unchanged |
| `_MapsThumbnailState.build` | capability_not_granted | unchanged |

One method was genuinely unblocked. `_InfoColumn.build` constructs `_InfoRow`, a
private class the released version of that same method already constructed and
the release now retains — the feature working on real history rather than on a
fixture.

Two were NOT unblocked, and correctly so. `AppBtn.build` constructs
`_ButtonHoverEffect`, which the released version of that method never
constructed. Under D1 it was refused for an imprecise reason (an unresolved
private identifier); it is now refused by the same-method rule, with an accurate
one. Candidate-introduced private construction remains outside the closed claim,
so this is the rule holding, not a regression.

The frozen taxonomy classifies these two as `other` because its `CAUSES` list
predates the rule and has no pattern for its text. That is a labelling gap in the
report, not an unexplained refusal.

## LocalSend moved nothing

232 observations, same five producer refusals, same causes:
`private_type_reference` 3, `capability_not_granted` 1, `receiver_rewrite` 1.
Not one LocalSend refusal involved a private construction.

## The remaining leader

Both corpora's surviving private-reference refusals are private NON-construction
references:

    Wonderous   _BottomTextContent.build   names `_handleArtifactTap`            (private method)
    LocalSend   _ProgressPageState.build    names `_advancedProgressPanelExtraPadding`  (private top-level)

It replicates across both corpora, but thinly: **one distinct method in each**.
LocalSend's three refused observations are that single method changing in three
different pairs — the frozen methodology counts a target refused in any pair as
refused in every pair it appears in, in D1 and D2 alike.

## What this does not support

The Wonderous gain is one method out of twenty. On a 20-observation corpus that
is 5.00 percentage points from a single change, and it should not be read as a
5-point capability improvement. The honest statement is: **automatic constructor
retention unblocked exactly one method across 252 observations, and both corpora
agree that private construction was never a major blocker in real history.**
