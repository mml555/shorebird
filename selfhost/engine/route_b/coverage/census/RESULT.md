# D0.2 — structural body census. The roadmap's ranking is wrong.

Run 2026-08-31, host only. Engine tree `619fdad176ff4573…`. Both corpora
compiled `--target flutter --aot --tfa`, which is the dill the analyzer reads in
production, and measured through census mode of the SAME
`coverage/analyze_coverage.dart` the patch path calls — `_lowering` is the
product's refusal contract and a second implementation would drift from it
silently.

> **This is not patch demand.** Every method that exists counts once, whether it
> changes weekly or has never been touched. `CENSUS.txt` carries the full
> disclaimer in its own output, and it is reproduced there rather than here so
> the numbers cannot travel without it. Only the LOWERING stage was run:
> reachability, retention, the producer's source-text refusals and the bytecode
> compiler are separate stages and were not evaluated.

## Headline

    corpus       considered   lowerable now      blocked
    airgap_app           19    18   94.74%     1   5.26%   synthetic fixture
    Wonderous          1282  1179   91.97%   103   8.03%   real application

Reported separately, never pooled. `airgap_app` is a regression fixture written
to exercise this mechanism; Wonderous was written by people who had never heard
of it. Only the second is evidence about real code.

## Wonderous, by CONSTRUCT — the table to plan from

    construct                       methods  % of all   SOLE  % unlock
    construct.method_tearoff             53     4.13%     44   42.72%
    construct.super                      44     3.43%     37   35.92%
    abi.named_parameters                  8     0.62%      7    6.80%
    abi.generic                           2     0.16%      2    1.94%
    receiver.compound_same_offset         2     0.16%      2    1.94%
    construct.this_escape                 2     0.16%      1    0.97%
    abi.optional_positionals              1     0.08%      1    0.97%

`SOLE` is methods for which this is the only blocker; `% unlock` is that over
the 103 blocked. **Tear-offs and `super` are 78.6% of the marginal unlock
between them.**

## Two corrections that changed the answer, both found by D0.3

The first reading of this census ranked one category top by a wide margin:

    receiver.unconsumed_this   91 methods   46 sole   44.66% unlock
    receiver.super_call        43 methods    0 sole    0.00% unlock

Both lines are artifacts, and each points a roadmap the wrong way.

**1 — `unconsumed_this` was three mechanisms wearing one reason string.**
Sampling the sole-blocked methods found `bgBuilder: _buildBg` and
`onPointerSignal: _handleTrackpadEvent` — implicit **method tear-offs**, where
`this` is the receiver of an `InstanceTearOff`. That is not a receiver escaping;
`_buildBg` → `self._buildBg` is the same textual edit as a read. Classifying
each unconsumed `this` by its Kernel parent splits the category:

    InstanceTearOff          89 occurrences   45 sole-blocked
    SuperMethodInvocation    43                0
    Arguments                 2                2
    SuperPropertyGet          1                0

Genuine escape — the shape `this`-capture work would target — is **2
occurrences in 1282 methods.**

**2 — `super` double-reports, so its 0% unlock was false.** `super.go()` emits
`calls `super.go()`` *and* `uses `this` other than to read a member`, because the
CFE puts a `ThisExpression` inside `SuperMethodInvocation`. Proven on a probe
whose source contains no `this` at all (`super_double_report_probe.dart`):

    Child.go          unsupported: [calls `super.go()`, uses `this` …]
                      thisParents: {SuperMethodInvocation: 1}
    Child.tearoffOnly unsupported: [uses `this` …]
                      thisParents: {InstanceTearOff: 1}

So `super` never appeared as a sole blocker — it always "co-occurred" with a
refusal it generates itself — while simultaneously inflating the `this` category
with 43 methods that are really super calls. Attributing constructs once each
moves `super` from **0% to 35.92%** marginal unlock.

Neither correction was visible in the raw histogram. Both were visible the
moment a sample of real methods was read, which is what D0.3 is for.

## What this says about D1

**Compound same-offset operations are 2 methods and 1.94% of marginal unlock.**
The roadmap estimated 11.3% and put structured lowering first on the strength of
it. On this corpus that is wrong by a factor of ~6, and it is second-to-last.

Applying the selection rule as frozen:

    1  correctness defects first        none open (D-HYGIENE closed)
    2  largest marginal unlock          method tear-offs 42.72%, super 35.92%
    3  mechanism cost                   see below
    4  one mechanism, several blockers  neither is a multi-category unlock

**D1 does not earn itself here.** Structured lexical lowering was the candidate
for compound writes and receiver-in-closure work; the census puts those at 1.94%
and 0.97%. Nothing in the top of this table needs a scope model:

* **Method tear-offs** look like the cheapest large unlock available. The
  analyzer has no `visitInstanceTearOff`, so `this` falls through to the
  unconsumed rule; the producer's edit kinds are `{get, set, invoke}` and a
  tear-off's lowered spelling is the same prefix insertion as a `get`. That is a
  claim about mechanism read off the code, **not a measured result** — it needs
  its own controls, including the private case (`_buildBg` is private, so it
  routes through the existing capability/retention path rather than around it).
* **`super`** is unchanged in difficulty and remains what `ROUTE_B.md` says it
  is: no textual equivalent once the method becomes a synthetic top-level
  function, needing the Kernel-resolved superclass target. Second in unlock,
  first in cost.

## Limits of this measurement, stated rather than implied

* **One real app.** Wonderous is a Flutter UI app, and `build`/`_buildX` methods
  are exactly where tear-offs live. An app with more logic and less widget tree
  would likely shift the mix. One corpus is not a distribution.
* **Existence, not change.** The P1.5 corpus question is still open and was not
  reopened; this measures reachability of refusals over methods that exist.
* **Lowering only.** A method counted `lowerable` here may still be refused for
  reachability, retention, a producer source-text rule, or by the compiler.
* **The alpha-rename count is informational.** 9 of 1282 declarations spell
  `self`, 7 of them lowerable. They lower correctly and cost a capture-avoiding
  rename; counting them as unsupported would put a solved problem back into the
  ranking. The test is the producer's own conservative substring scan, so it
  over-triggers on comments and on names like `selfTest`.

## Provenance

    corpus      gskinnerTeam/flutter-wonderous-app
                747b945a7e5239356bf2664261aa2f3b020b8898   (P1.5's pin)
    fixture     selfhost/fixtures/airgap_app
    rows        airgap.census.jsonl, wonderous.census.jsonl  (one JSON per line)
    report      CENSUS.txt

## Reproduce

    WORK=/tmp/census bash selfhost/engine/route_b/coverage/run_census.sh
