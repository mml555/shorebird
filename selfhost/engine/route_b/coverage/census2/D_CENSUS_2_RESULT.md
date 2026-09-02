# D-CENSUS-2 — the census rerun after D-SUPER, with the two super numbers kept apart

Run 2026-09-02, host only. Same census executable, same taxonomy, same
denominator rule, same corpora, same reporter for the D0-comparable numbers.

## Provenance

    shorebird repo       6e52a55515e10fdb774ca9e9c42f5906ae04a898
                         + the D-CENSUS-2 instrumentation in this commit
    Wonderous revision   747b945a7e5239356bf2664261aa2f3b020b8898   (P1.5's pin)
    LocalSend revision   6279d3e30d1d1290caee3b81549f8128a8b01d9f
    analysis version     11        (D0.4 ran at 9)
    census version       2         (additive; every version-1 field unchanged)

**The census did NOT run at a clean `6e52a555`.** Measuring narrow-v1
admissibility needed instrumentation that did not exist, so it ran with the
changes committed here on top of that revision. Stated rather than implied,
because "the repo at X" would otherwise be false.

### Both corpora reproduce exactly

Neither was substituted, and neither was re-resolved.

    Wonderous  747b945a…  working tree carries a pubspec.lock drift (meta
               1.17.0->1.18.0, webview_flutter 4.13.0->4.14.1) last modified
               2026-08-25, SIX DAYS BEFORE the D0.4 run of 2026-08-31. So D0.4
               ran with exactly this lockfile. RESTORING the committed lock
               would have CHANGED the corpus relative to D0.4, not preserved
               it, so it was left alone.
    LocalSend  6279d3e3…  its pubspec.lock was written 2026-08-31 02:29, eight
               minutes before D0.4's own artifacts, i.e. by that run. Untouched
               since.

Reproduction was then verified against the banked numbers rather than assumed —
all three corpora came back identical:

    corpus       considered   D0 lowerable   reproduced
    airgap_app           19             18   19 / 18   EXACT
    Wonderous          1282           1179   1282 / 1179  EXACT
    localsend           584            539   584 / 539    EXACT
                                            (18 580 of 19 164 rows dropped as
                                             generated, as in D0.4)

The localsend construct table also came back element-for-element identical to
D0.4 (super 22 sole / 48.89%, this_escape 6 / 13.33%, tear-off 3 / 6.67%,
optional_positionals 3, named_parameters 2, compound 1). The "before" column
here is a re-measurement, not a quotation.

## The two measurements, and why they are not one

### 1 — mechanism lowerability

A `super.member()` METHOD call whose SOURCE argument list is empty.

**Read from the source, not the kernel, and that is forced.** The census kernel
is built `--aot --tfa`, as a release is, and TFA rewrites argument counts —
`super.tag('a', 7)` becomes zero arguments in that very kernel
(`super0/s2b0/`), which is why `analysisVersion` 10 and 11 refuse to report an
arity at all. So the classification calls the product's own fail-closed scanner,
`route_b_super_source.routeBSuperCallArgs`, via
`tool/census_super_shape.dart`. Restating that rule inside the census would
have created a second definition free to drift from the one that admits real
patches.

### 2 — narrow-v1 admissibility

Additionally: `releaseSuperTargets` was **measured** for that method, every
site's target **resolved**, and each resolved target **appears** in the measured
set. An omitted key is a missing measurement, not an empty result, and is not
admissible.

### What a census structurally cannot separate

A census has ONE kernel: the corpus is its own release, recorded as
`releaseIsSelf: true` in the header. Where a target resolves, the release
trivially direct-calls the target its own super site names — so **in a
self-census the target rule cannot bind more tightly than the shape rule, and
the two numbers coincide.** They are reported separately anyway, and the gap is
reported as its own line, because the equality is a property of this
measurement setup and not a property of the product. The sensitivity control
below shows the rule does separate them the moment target evidence diverges.

Measurement 2 therefore answers "does the release direct-call the target its own
super site names" — exactly the condition for a patch that PRESERVES that call.
It does not estimate whether a patch introducing a NEW super call is admissible.

## Wonderous

| Metric | D0 | D-CENSUS-2 |
| --- | --: | --: |
| Total instance procedures | 1282 | 1282 |
| Fully lowerable | 1179 | **1208** |
| Lowerability % | 91.97% | **94.23%** |
| Blocked | 103 | **74** |
| Super mechanism-capable | 0 | 34 |
| Super narrow-v1 admissible | 0 | 34 |

    super sites 43 -> zeroArguments 34, hasArguments 9
    admissible methods 34, of which 5 remain blocked by something else
    newly supported: +29

## localsend

| Metric | D0 | D-CENSUS-2 |
| --- | --: | --: |
| Total instance procedures | 584 | 584 |
| Fully lowerable | 539 | **560** |
| Lowerability % | 92.29% | **95.89%** |
| Blocked | 45 | **24** |
| Super mechanism-capable | 0 | 29 |
| Super narrow-v1 admissible | 0 | 29 |

    super sites 30 -> zeroArguments 29, hasArguments 1
    admissible methods 29, of which 8 remain blocked by something else
    newly supported: +21

## Improvement attributable to D-SUPER, cross-checked

The whole gain is super's: `lowerable` differs from D0 only for methods whose
sole blocker was a super site that narrow-v1 admits.

    corpus      D0 super SOLE   still super SOLE   difference   newly supported
    Wonderous              37                  8           29             29  AGREES
    localsend              22                  1           21             21  AGREES

D0.4's theoretical super sole-blocked figures minus what narrow-v1 still
refuses equals the measured improvement, on both corpora independently. That is
the difference between "theoretical super lowerability" and "real narrow-v1
admissibility", quantified: **8 of Wonderous's 37 and 1 of localsend's 22
super-sole methods are NOT admissible** — nine methods that a syntax-only recount
would have wrongly promoted.

## Remaining blockers, ranked AFTER narrow-v1 admissibility

Wonderous, 74 blocked:

    blocker                        occur  methods  % corpus   SOLE  % blocked
    construct.method_tearoff          89       53     4.13%     49    66.22%
    construct.super                   10       10     0.78%      8    10.81%
    abi.named_parameters               8        8     0.62%      7     9.46%
    abi.generic                        2        2     0.16%      2     2.70%
    receiver.compound_same_offset      6        2     0.16%      2     2.70%
    construct.this_escape              2        2     0.16%      1     1.35%
    abi.optional_positionals           1        1     0.08%      1     1.35%

localsend, 24 blocked:

    blocker                        occur  methods  % corpus   SOLE  % blocked
    construct.this_escape             12       12     2.05%     12    50.00%
    abi.optional_positionals           3        3     0.51%      3    12.50%
    construct.method_tearoff           4        3     0.51%      3    12.50%
    receiver.compound_same_offset      3        3     0.51%      3    12.50%
    abi.named_parameters               2        2     0.34%      2     8.33%
    construct.super                    1        1     0.17%      1     4.17%

`occur` counts over the STILL-BLOCKED population and excludes super sites in
admissible methods, so it shares a population with the columns beside it. A
first version counted it over every row and produced rows like `super occur=30,
methods=1`; that was wrong and is fixed.

### Replication

| Blocker | Wonderous sole | LocalSend sole | Replicated? |
| --- | --: | --: | --- |
| construct.method_tearoff | 49 | 3 | YES |
| construct.this_escape | 1 | 12 | YES |
| abi.named_parameters | 7 | 2 | YES |
| construct.super | 8 | 1 | YES |
| receiver.compound_same_offset | 2 | 3 | YES |
| abi.optional_positionals | 1 | 3 | YES |
| abi.generic | 2 | 0 | no |

"Replicated" means sole-blocked in both, and says nothing about magnitude.

**The ordering did not converge.** Tear-offs are first on Wonderous (49, 66%)
and joint-second on localsend (3, 12.5%); `this_escape` is first on localsend
(12, 50%) and next-to-last on Wonderous (1, 1.35%). Both remain small-count:
localsend now has 24 blocked methods, so one method is 4.2 percentage points.
Treat the ordering as the result and the percentages as coarse.

## Controls

### Mutation control — PASS

`RouteBThing.helper` in the airgap fixture, lowerable before, one construct
injected:

    before  lowerable=True   unsupported=[]                                    parents={}
    after   lowerable=False  unsupported=['uses `this` other than to read a member']  parents={'Arguments': 1}
    category identified     construct.this_escape
    corpus lowerable        18 -> 17
    methods that moved      exactly RouteBThing.helper

The fixture was mutated in place because a copied tree broke package
resolution, then restored and the restoration PROVEN: `lib/main.dart` hashes
`25a18bcd…` before and after, and `git status` is clean.

**The first attempt at this control failed, and the failure is the finding.**
Injecting an optional named parameter with a default moved nothing: no caller
passes it, so TFA erased it and the census — which reads the `--aot --tfa`
kernel — correctly saw no blocker. That is the same erasure the version-10 note
records for argument counts, observed independently. A construct TFA cannot
erase was used instead. Had the control been declared PASS on the first
attempt's "no regression", it would have certified nothing.

### Super sensitivity control — PASS

One admissible site (`_WondersAppState.didChangeDependencies` →
`framework.dart#65858 didChangeDependencies`), then the evidence perturbed:

    1  as measured, matching releaseSuperTargets      mech=T  admissible=T
    2  target evidence REMOVED                        mech=T  admissible=F  measurement_absent
    3  evidence present but EMPTY                     mech=T  admissible=F  target_disagreement
    4  target offset off by ONE                       mech=T  admissible=F  target_disagreement
    5  target name changed                            mech=T  admissible=F  target_disagreement
    6  site target UNRESOLVED                         mech=T  admissible=F  target_unresolved
    7  same target, source shape hasArguments         mech=F  admissible=F  shape:hasArguments
    8  same target, source shape unverifiable         mech=F  admissible=F  shape:unverifiable

Arms 2 and 3 return **different** reasons, which is the absent-vs-empty
distinction fixed in `6ffa93a0`. Arm 8 confirms the scanner's fail-closed
contract survives into the census: unverifiable is refused, never assumed.

So the census is measuring the product rule certified by D-SUPER-2C, not merely
recognising `super` syntax.

## Regression

    census_report.py `constructs()` hoisted to module level so both reporters
    share ONE definition of D0.3's attribution rules. Pure move; verified by
    running the reporter before and after on identical input — outputs
    BYTE-IDENTICAL.

    analysisVersion                     11, unchanged
    certified local analyzer AOT        18862acd…, byte-identical before and
                                        after the census build (the census
                                        analyzer was built to a scratch OUTDIR,
                                        never over the certified one)
    airgap fixture                      restored, digest proven

## What this licenses, and what it does not

* The supported surface moved on both corpora: **91.97% -> 94.23%** and
  **92.29% -> 95.89%**, entirely attributable to narrow-v1 super.
* Nine of the 59 theoretically-super-sole methods across both apps are NOT
  admissible. A recount that promoted all zero-argument super sites would have
  overstated the gain by that much.
* **Tear-offs did not become the clear next target.** They lead Wonderous
  decisively and are mid-pack on localsend, where `this_escape` now leads. The
  ranking changed shape rather than confirming the parked candidate.
* Two apps are still not a distribution, and the blocked populations are now
  smaller (74 and 24), which makes every percentage coarser than before, not
  finer.
