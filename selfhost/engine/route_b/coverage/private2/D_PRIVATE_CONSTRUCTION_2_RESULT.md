# D-PRIVATE-CONSTRUCTION-2 — v13 contract, narrow retention policy, and its cost

Gates 1-5 are closed at host level. **Gate 6, real artifact and device
qualification, is NOT done** and is the remaining work; see the end.

## The v13 contract

    v11   privateConstructions          unavailable
    v12   privateConstructions          measured (candidate only)
          releasePrivateConstructions   unavailable
    v13   privateConstructions          measured (candidate)
          releasePrivateConstructions   measured (the RELEASE's version of the
                                        SAME method)

`releasePrivateConstructions` keeps three states apart, as ruled:

    ABSENT     the base could not be examined -> nothing measured -> REFUSE
    EMPTY      measured: the release version of this method constructed none
    POPULATED  measured positive evidence, per constructor

The candidate side and the release side are measured by ONE function
(`_privateConstructions`), because measuring the two sides with different code
is how an evidence rule quietly stops comparing like with like.

### Validated without the experiment's crutch

D-PRIVATE-CONSTRUCTION-1 obtained release-side evidence by running the analyzer
REVERSED. That was valid for an experiment and could not become a prerequisite
for normal patches. A single FORWARD v13 run now reproduces that classification
exactly:

    AppBtn.build (56086308_002e1272)   cand 3, release 3   PRE-EXISTING
    AppBtn.build (b45e16fc_e6b9a28a)   cand 3, release 2   INTRODUCED _ButtonHoverEffect.new
    _CollapsingCarouselItem.build      cand 1, release 1   PRE-EXISTING
    _HomeMenuState._buildIconGrid      cand 1, release 0   INTRODUCED _GridBtn.new

## Gate 2 — patch admission, two conditions

Implemented in `route_b_producer.dart`. A construction is carried only when
BOTH hold:

1. the RELEASE's version of THIS SAME METHOD already constructed exact `C`;
2. the release manifest retained exact `C`.

Either absent refuses. The manifest alone is not enough precisely because it is
release-WIDE: it contains `_Private.new` whenever ANY released method built it.

The CLI knows `{11, 12, 13}`. A v12 document is still decodable but CANNOT use
the construction path — it measures the candidate and carries no same-method
evidence, so it refuses with "did not measure".

## Gate 3 — cross-method leakage, PROVEN ON REAL HISTORY

Not a synthetic example. Release `b45e16fc`'s manifest was widened to grant
`_ButtonHoverEffect.new` and `_GridBtn.new` — simulating exactly the situation
the ruling warned about, where some OTHER released method's use puts the
constructor in a release-wide manifest. The real producer, on the real
historical pair:

    REFUSE  AppBtn.build
      its body constructs `_ButtonHoverEffect`, which the RELEASE version of
      this same method never constructed.

    REFUSE  _HomeMenuState._buildIconGrid
      its body constructs `_GridBtn`, which the RELEASE version of this same
      method never constructed.

Both refused **while the manifest granted them**, which is what makes the
same-method condition independently load-bearing rather than redundant.

A unit test covers the same shape directly: manifest grants `_Helper.new`, the
release method constructed `_Other.new`, patch introduces `_Helper.new` ->
refused.

## Gate 4 — the real-history negative specimens

`_ButtonHoverEffect.new` and `_GridBtn.new` are kept as the negative specimens
and were not replaced. Note that under the NARROW policy their release manifest
does not grant them at all — no release method constructed them — so in normal
operation both conditions refuse. Gate 3's widened manifest is what isolates the
same-method condition on its own.

## Gate 1 — release-time policy

The release derives its grants from its OWN methods: run the analyzer in census
mode over the release kernel, take the union of every method's
`privateConstructions`, and pass exactly those as `--grant-constructor`.

**No new measurement code.** The generator does not visit bodies at all, and
teaching it to would have created a second definition free to drift from the one
that admits patches. Census rows now carry `privateConstructions`, which the
analyzer already computed — one definition, two readers.

    Wonderous  80 methods construct privately -> 108 unique constructors, 107 granted
    LocalSend  56 methods (hand-written)      ->  65 unique constructors,  64 granted

## Gate 5 — what the narrow policy actually costs

Measured the way this project measures retention: same source, same compiler,
two arms differing only in the interface yaml, `--deterministic` snapshots.

| | Wonderous | LocalSend |
| --- | --: | --: |
| exact constructor grants | 107 | 64 |
| constructionWithheld before | 119 | 3905 |
| constructionWithheld after | 12 | 3841 |
| AOT baseline | 13,871,760 B | 28,463,224 B |
| AOT with narrow policy | 13,922,720 B | 28,460,608 B |
| **delta** | **+50,960 B (+0.367%)** | **−2,616 B (−0.009%)** |

Both are negligible, and far from the **+8.35% at 200 classes** the generator
records for granting every constructor. The reason is causal rather than lucky:
these constructors are ones the release's own methods already construct, so
their code is already retained and reachable — the narrow policy adds
entry-point metadata, not code.

**"Narrow" means very different things per app, and that is worth stating.** On
Wonderous it grants 107 of 119 withheld constructors (90%): a small showcase app
where most private classes are widgets some `build` constructs. On LocalSend it
grants 64 of 3905 (1.6%). A policy that looks broad on one app is tiny on
another, so the size result should be read from the DELTAS, not from the ratio.

LocalSend's delta is slightly negative, which is snapshot noise at this
magnitude, not a saving.

## What is NOT done

**Gate 6 — real artifact and runtime qualification.** Host compilation is not
certification. Still required, as one candidate lineage:

    v13 analyzer + narrow retention policy + CLI v13 admission
      -> qualify the compiler
      -> mint ONE new candidate cell
      -> cut a release under the new retention rule
      -> positive patch: a method with a PRE-EXISTING private-construction
         dependency is admitted, publishes, activates on device, and executes
         through that constructor correctly
      -> negative control: the candidate-introduced case refuses BEFORE
         publication

Until that runs, what is proven is that the constructor is named in a manifest
and that a replacement compiles against an import kernel — not that it is
callable from the installed AOT release. H3 and release 141 remain untouched.

## Regression

    full shorebird_cli suite      2719 pass, 2 skipped
    new tests                     7 producer (incl. cross-method leakage),
                                  5 decoder (absent/empty/populated, v11/v12/v13)
    certified local analyzer      18862acd… byte-identical; every v12/v13 build
                                  went to a scratch OUTDIR
