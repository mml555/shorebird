# D-DEMAND-1 — what developers actually changed, and whether Route B could carry it

Run 2026-09-02, host only. Rules fixed in `D_DEMAND_1_PRECOMMIT.md` (`43b66ac0`)
before any pair was measured; the one design change is recorded there
addition-only, as a supersession by measurement.

## Provenance

    shorebird repo       6e52a555 + the D-DEMAND-1 harness (0ddba200) and this row
    Wonderous            747b945a7e5239356bf2664261aa2f3b020b8898   (D-CENSUS-2's pin)
    LocalSend            6279d3e30d1d1290caee3b81549f8128a8b01d9f   (D-CENSUS-2's pin)
    analysis version     11
    instrument           analyze_coverage --base-dill <N> --patched-dill <N+1>,
                         the shipping release-vs-candidate path

LocalSend was a **depth-1 shallow clone with no history**; it was deepened with
`git fetch --unshallow` (1983 mainline commits). HEAD did not move, the pin is
still checked out, and its `pubspec.lock` drift is untouched, so D-CENSUS-2
remains reproducible. Deepening is not the corpus substitution the ruling
forbids; swapping in a third app would have been.

## Headline

| Metric | Wonderous | LocalSend |
| --- | --: | --: |
| changed Dart instance methods | 20 | 253 |
| Route B admissible | 14 | 233 |
| refused | 6 | 20 |
| patch-demand compatibility % | **70.00%** | **92.09%** |

273 real changed methods, against the pre-committed target of "several hundred
if available". Both windows are structurally capped — see EXCLUSIONS — so the
extension rule ran to its stop condition rather than to 300.

**These are ANALYZER-level numbers and are an upper bound.** Control 1 found the
producer refusing changes the analyzer admits; see CONTROLS.

## Refusal ranking, method-weighted

Wonderous, 6 refused:

    refusal reason                   methods  SOLE  % refused
    construct.method_tearoff               6     4     66.67%
    abi.named_parameters                   1     0      0.00%
    construct.this_escape                  1     0      0.00%

LocalSend, 20 refused:

    refusal reason                   methods  SOLE  % refused
    abi.named_parameters                   8     5     25.00%
    construct.this_escape                  7     4     20.00%
    construct.method_tearoff               4     3     15.00%
    receiver.compound_same_offset          2     2     10.00%
    reach.unreachable                      2     1      5.00%
    abi.optional_positionals               1     1      5.00%

## Commit-weighted, and the largest contributors

Wonderous, 8 pairs with a changed method:

    construct.method_tearoff      5 pairs  62.50%
    pair.member_set_changed       4 pairs  50.00%
    abi.named_parameters          1 pair   12.50%
    construct.this_escape         1 pair   12.50%

LocalSend, 11 pairs with a changed method:

    pair.member_set_changed       6 pairs  54.55%
    abi.named_parameters          4 pairs  36.36%
    construct.this_escape         4 pairs  36.36%
    construct.method_tearoff      2 pairs  18.18%
    receiver.compound_same_offset 2 pairs  18.18%
    abi.optional_positionals      1 pair    9.09%
    reach.unreachable             1 pair    9.09%

**One commit dominates LocalSend's method-weighted view.** `af0416be_224ef8b1`
contributes **137 of 253** changed methods — 54.15% — and 23 of the refusals.
The second, `4b5236ce_63efbe6b`, contributes 83 more. So two mechanical commits
account for 87% of LocalSend's observations, which is exactly the distortion the
commit-weighted table exists to expose: `pair.member_set_changed` leads
commit-weighted while not appearing in the method-weighted table at all.

## THE FINDING: developers almost never introduce the blocking construct

    construct                     introduced  pre-existing  unknown
    Wonderous
      construct.method_tearoff             1             5        0
      abi.named_parameters                 0             1        0
      construct.this_escape                0             1        0
    LocalSend
      abi.named_parameters                 0             7        1
      construct.this_escape                0             7        0
      construct.method_tearoff             0             4        0
      receiver.compound_same_offset        0             2        0
      abi.optional_positionals             0             1        0

Across both corpora, **one** refused method introduced its blocker. Every other
refusal is a method that ALREADY contained the construct, which the developer
did not touch — they edited something else in the same body and Route B refuses
the whole method.

That reframes the roadmap question. "Developers write tear-offs, so implement
tear-offs" is not what the data says. What it says is that the **method is the
unit of refusal**, and any long-lived widget `build` accumulates one blocker
eventually. Implementing tear-offs would unblock those bodies; so would any
mechanism that narrows the refusal unit below a whole method. The census could
not distinguish these two readings, and this measurement can.

## SUPER — control 4 reports ABSENT, as pre-committed

    changed methods containing a super site   Wonderous 1   LocalSend 6
    narrow-v1 admissible                                1             6
    TARGET-EVIDENCE divergences                         0             0

This experiment finally had two worlds, so `releaseSuperTargets` COULD have
diverged. In 273 real changed methods it never did: every super site a developer
touched still named a target the release direct-called. The precommit said a
divergence would be used only if one existed and never manufactured, so none is
reported.

## Exclusions — both windows are structurally capped

    Wonderous   40 commits, 36 kernels, 31 pairs, 4 cross-lockfile
                4 kernels FAILED: commits 3821b0c6 and 3 successors set
                `InternetConnectionChecker.instance` in source while their own
                committed pubspec.lock still pins internet_connection_checker
                1.0.0+1, which has no `.instance` (the pin has 3.0.1). Those
                commits do not compile against their own lockfile. A real
                property of the history, not a harness artifact.

    LocalSend   40 commits, 30 kernels, 27 pairs, 3 cross-lockfile
                10 kernels FAILED, all the same cause: those commits predate the
                pub WORKSPACE restructure and have no root pubspec.yaml or
                pubspec.lock at all (their group hash is e3b0c442…, the
                empty-input digest).

Extending backwards therefore adds only failures in both corpora: Wonderous hits
the API migration, LocalSend the workspace boundary. The pre-committed extension
rule stopped for that reason, not because 300 was reached.

**The extension was ATTEMPTED rather than argued.** LocalSend was re-run at
K=80, as the rule requires. It added **zero** usable commits: 22 consecutive
kernel failures with 0 new kernels and 0 new pairs, because commits older than
the window depend on packages the project later removed —

    Error: Couldn't resolve the package 'open_filex' …
    Error: Couldn't resolve the package 'open_dir' …

matching the recent `refactor: replace open_filex with open_file` and
`refactor: drop open_dir dependency` commits. The run was stopped once the block
had demonstrably added nothing; the pre-committed condition "a block adds fewer
than 20 changed methods" was met with a margin of 20.

## Controls

### Control 1 — a supported historical change classifies supported: **FAILED, and the failure is the finding**

`AppBtn.build` (pair `56086308_002e1272`, one changed method, verdict accept) is
census-ADMISSIBLE: `unsupported` empty, no super site. Replayed through the
shipping `RouteBCoverage.fromJson` and `RouteBProducer.produce`, against the
candidate commit's own source, with a capability manifest granting exactly the
private members the document itself reports:

    PRODUCER REFUSED
      target: …/buttons.dart#AppBtn.build
      reason: its body names `_CustomFocusBuilder`, a private identifier this
              analysis did not resolve to a member the release granted.

Repeated across Wonderous's pairs that contain admissible methods:

    pair                  producer verdict     refused target        census said
    002e1272_7b55750f     past admission        --                    --
    e6b9a28a_397d9504     past admission        --                    --
    397d9504_56086308     REFUSED               _ArtifactScreenState.build   refused (AGREES)
    56086308_002e1272     REFUSED               AppBtn.build                 ADMISSIBLE
    b45e16fc_e6b9a28a     REFUSED               AppBtn.build                 ADMISSIBLE
    e1a8ba4a_8e5d737a     REFUSED               _InfoColumn.build            ADMISSIBLE

**Three of six pairs contain a method the census admits and the producer
refuses, and all three are the same class of cause: the body names a private
TYPE** (`_CustomFocusBuilder`, `_InfoRow`). The analyzer models private MEMBER
accesses and reports the key a release would have had to grant; it does not
model a private type named in the body. The producer scans the source for
private identifiers and refuses.

So the 70% and 92.09% above are analyzer-level UPPER BOUNDS. The producer-level
rate was not measured for every method — the producer refuses on the first
problem in a document, so a per-method rate would need one run per method — and
is deliberately not estimated from six pairs.

### Control 2 — mutation flip: **PASS**

Same method, one real unsupported construct injected into the candidate commit's
source (`identityHashCode(this)`, which TFA cannot erase), candidate kernel
rebuilt, pair re-analysed:

    before  unsupported=[]                                        admissible
    after   unsupported=['uses `this` other than to read a member']  refused
    category identified   construct.this_escape
    changed methods       1 before, 1 after

The worktree was restored afterwards and `lib/` verified clean; the frozen
corpus checkout is a different directory and was never touched.

### Control 3 — census reason agrees with production refusal: **PASS**

Pair `22feb00e_540cca24`, one changed method, verdict accept so nothing
pair-level preempts:

    census lowering.unsupported : ['uses `this` other than to read a member']
    PRODUCER REFUSED
      target: …#_FullscreenVideoViewerState.initState
      reason: uses `this` other than to read a member

Same target, same reason string. The census's category for it,
`construct.method_tearoff`, is that same refusal attributed to its parent node
(`InstanceTearOff`) — D0.3's refinement, which the producer never claimed to
make. They agree on the target and the cause; the category is strictly finer.

A first attempt at this control refused for a DIFFERENT reason — "this release
published no capability manifest" — which was an artifact of the harness
supplying none, not the census's reason. It is recorded rather than discarded,
because reporting it as agreement would have certified nothing.

### Control 4 — super divergence: **ABSENT** (see SUPER above)

## Two measurement errors, recorded

**A wrong search instrument.** `git log -S'InternetConnectionChecker'` found
nothing, and that silence was briefly read as "the source never changed". `-S`
counts OCCURRENCES, and the migration `InternetConnectionChecker()` →
`.instance` kept the count identical. `-G` found it immediately.

**A wrong key in this row's own reporter.** The document key is `patchable`;
`representable` is what the parsed Dart field is called. Reading the field name
made every static-shaped change look unreachable, and `reach.not_offered` came
out as LocalSend's top refusal at 54.55% — an implausible result that is what
exposed it. Corrected before any conclusion: LocalSend's compatibility moved
from 82.61% to 92.09%.

## What this licenses, and what it does not

* Real patch-demand compatibility is **70% and 92%** at analyzer level, on 273
  real changed methods — well below the 97-99% at which the ruling said to stop
  language expansion, and the producer-level number is lower still.
* **The ranking did not converge on tear-offs.** They lead Wonderous (4 sole of
  6 refused) and are third on LocalSend (3 sole of 20). `abi.named_parameters`
  leads LocalSend. Neither dominates both.
* **Almost nothing is introduced.** One refused method in 273 introduced its
  blocker. A feature-by-feature roadmap answers a question the data is not
  asking.
* Two apps are not a distribution; two mechanical commits supply 87% of
  LocalSend's observations; and both windows are capped by structural boundaries
  rather than by choice.
