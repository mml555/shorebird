# The tree-wide cspell debt — baseline, and what would make it a gate

Recorded 2026-08-16 at commit `db08b48d`.

## The correction this record exists to make

`HANDOFF.md` presented this command as a verification gate:

```bash
npx cspell --no-progress --no-summary selfhost packages/code_push_server/lib
```

**CI has never run it.** `.github/workflows/main.yaml:30` calls VeryGoodOpenSource's
`spell_check.yml@v1`, which forwards to `streetsidesoftware/cspell-action@v8` with
`incremental_files_only: ${{ inputs.modified_files_only }}` — and that input
**defaults to `true`**, which `main.yaml` does not override. CI's spelling gate is
**incremental**: only the files a push or PR changed. Its last run was **green**
(`🔤 Check Spelling / build`, run `31824444226`).

The other cspell job — `shorebird_ci.yaml:235`, which *does* pass
`incremental_files_only: false` — is in a workflow **disabled in this fork**, per
its own header comment. It does not run.

So the tree-wide command was an approximation of CI's, in the one block that was
rewritten on 2026-08-13 specifically to stop carrying approximations. It is not a
gate that went red. It is a gate that never existed, whose red state signals
nothing about any particular change.

## The measured baseline

| | |
|---|---|
| findings | **1,770** |
| files | **153** |
| distinct unknown words | **440** |

Raw output: [`baseline-2026-08-16.txt`](baseline-2026-08-16.txt).

> **Drift since the measurement, recorded so the 1,770 stays interpretable.**
> `tpool` was added to the global dictionary on 2026-08-16 — a real identifier
> from patch `0012`'s target→pool scan, present in four tracked files, added under
> CLAUDE.md's two-file rule when the per-change gate caught it on a new line. That
> removes **35** findings, so a re-run now measures **1,735**. The raw file above
> is left as measured rather than regenerated: it is the record of a specific
> commit, and silently refreshing it would destroy the ability to tell cleanup
> from drift. **Any further dictionary additions should be appended here the same
> way.**

Where it concentrates:

| count | file |
|---|---|
| 348 | `selfhost/evidence/releases/39/obfuscation_map.json` |
| 123 | `selfhost/PARITY.md` |
| 46 | `selfhost/engine/route_b/0012-routeb-target-pool-identity.patch` |
| 45 | `selfhost/engine/route_b/0003-4b-lifecycle-delivery.patch` |
| 40 | `selfhost/engine/route_b/probes/assert_result_consumed.sh` |

Four categories, and they want different treatment:

1. **Generated or captured artifacts** — the obfuscation map, `.trace` files,
   `.snapshot` files, device receipts. These are not authored prose. Most of the
   count is here, and the fix is `ignorePaths`, not a dictionary.
2. **Vendored/derived C++ and Dart identifiers** inside `.patch` files —
   `constexpr`, `memcmp`, `uintptr`, `ostringstream`. Also not authored prose.
3. **Project jargon** — `precommitted`, `tombstoned`, `killswitch`, `tpool`,
   `runmain`, `twoengine`, `worktree`. These belong in the global dictionary.
4. **British spellings** — `authorised`, `behavioural`, `neighbour`, `optimised`,
   `organisation`, `recognise`, `synthesise`, `initialise`, `normalised`. The
   config already carries `analysed`, so the convention is to accept them; they
   are simply unlisted.

> **SUPERSEDED 2026-08-16 — the four categories above are kept as the original
> reading, and two of their claims were measured false.** This block used to end
> *"categories 1 and 2 are ~60 % of the count and cost no judgement."* Exclusion
> actually absorbs **29 %**; the other **71 %** is authored material. And category
> 2 cannot be handled by path exclusion at all: `.patch` files carry prose this
> repo wrote, including 1,775 authored comment lines inside diff bodies. Category
> 4's framing was wrong in a third way — it is not "the fork uses British
> spellings" but "both standard variants are accepted".
>
> The governing document is
> [`classification_precommit.md`](classification_precommit.md), written before any
> finding was reclassified precisely so these boundaries were not invented while
> watching the count fall.

## The three obligations, kept separate

**1. Per-change gate — LIVE, and enforceable today.**
`selfhost/scripts/cspell_touched.sh`: **your change adds no new findings.** Its
negative control is `--self-test`, **6/6**.

The rule is scoped to the **lines you added or changed**, not to whole touched
files, and that was a correction forced by measurement rather than a preference.
The stricter "touched files must be clean" was implemented first and is unusable
here: `PARITY.md` carries 123 inherited findings and every lane edits it in nearly
every commit, so the gate went red on arrival for the repo's most-edited file —
which is how the tree-wide command earned its own irrelevance. For a **new** file
every line is added, so new files must be fully clean; `--whole-file` asks for
that anywhere.

The gate proved itself on its author before anything else: run on the change set
that introduced it, it excluded 130 inherited findings and flagged **8 new ones on
this lane's own added lines**, which were then fixed.

One thing it deliberately does not do is trust an issue count alone. cspell 10.0.1
prints `Files checked: 0, Issues found: 0` for a path it cannot resolve, so every
requested path is accounted for by name as CHECKED or IGNORED-BY-CONFIG.

**2. Tree-wide debt — KNOWN RED, recorded here, NOT a gate.**

### Step 1 applied 2026-08-16 — attribution, including where a prediction was wrong

Each reduction was applied independently, with its paired control run through the
promoted command before and after. Counts are chained, not summed, because the
reductions **overlap** — a finding inside an excluded file is also removed by a
dictionary entry, and adding the two figures double-counts it.

| step | mechanism | from → to | removed | predicted |
|---|---|---|---|---|
| `tpool` | dictionary (§2) | 1,770 → 1,735 | 35 | — |
| three path exclusions | `ignorePaths` (§1) | 1,735 → 1,275 | **460** | 470 |
| patch code lines | comment-aware override (§4) | 1,275 → 1,150 | **125** | 124 |
| spelling variants | `language: "en,en-GB"` (§3) | 1,150 → 979 | **171** | 237 |
| `fulldiff` | dictionary (§2) | 979 → 972 | **7** | — |
| 19 vocabulary groups + git hunk headers | dictionary (§2) + override (§4) | 972 → **414** | **558** | — |

### The residue pass was led by frequency and decided by meaning

Frequency chose the reading order; **the admission test was always semantic** — *is
this stable project or domain vocabulary that should stay checked in context?* Two
findings decided by that question rather than by their count:

* **`Wonderous` — 17 findings, and cspell suggests "Wondrous".** The suggestion is
  wrong. The app is `gskinnerTeam/flutter-wonderous-app`; the spelling is that
  project's own pun. A count-driven pass would have "fixed" 17 references and
  renamed a real third-party application across the evidence citing it. It is in
  the dictionary with that warning attached.
* **`Shoul` — 1 finding, and it is a real misspelling that must stay.** It comes
  from upstream Flutter's own test name
  `ShoulDiscardLayerTreeIfFrameIsSizedIncorrectly`, quoted in a git hunk header.
  This fork cannot fix it without breaking the patch, and it recurs in every patch
  touching that file. Reading it is what produced the `^@@` rule — hunk headers
  need no heuristic, since git writes the entire line including the function
  context it extracts, so no part is authored here and no finding on one is ever
  actionable.

**Zero near-miss findings remain.** Every finding cspell offered a `fix:` for — its
own signal that a word is one edit from a real one, and therefore the population
most likely to contain genuine defects — has been dispositioned. That is the
signal-preservation claim, and it is stronger than the count.

### What the remaining 414 are, and why they are not all dictionary work

| class | count | disposition |
|---|---|---|
| obfuscated Dart symbols | ~46 → **6** | **boundary decided; 6 kept as explicit debt** — see below |
| further project/tool vocabulary (`PSDK`, `idevicedebug`, `CODEPATCH`, `runmain`, `symsrc`) | ~60 | §2, same semantic test, next pass |
| `PARITY.md` | 44 | **human review, deliberately not batch-processed.** It is a mixture of legitimate vocabulary and possible real errors, and it is the file a reader trusts most |
| probes and plans (`.sh`, `.py`, `.md`) | ~260 | mixed; needs reading, not rules |

### The obfuscated-symbol boundary — positional, and it stops short on purpose

Release-specific opaque Dart symbols (`hlclpqwxzq`, `hlclxeca3w`, …) appear in two
structurally different positions, and only one of them admits a rule:

| position | example | authorship |
|---|---|---|
| captured receipt field | `    dart hlclpqwxzq dart-main-entered` | mechanically sourced — a pasted device capture |
| authored prose quote | ``Launch 1 (`hlclpqwxzq`) — full chain through `first-frame`.`` | **argument**, not capture |

**Both shortcuts were rejected.** A dictionary entry would be permanent noise
wearing the costume of vocabulary, because the symbols are *random per release*.
Excluding the containing files would blind authored reasoning, because
`gate2_verdict.txt` quotes the symbols inside its own argument about which launch
was which.

**The instrument is positional**, aiming at the `^@@` standard: it suppresses the
token occupying the symbol field of a receipt line — `dart <token> ` — and nothing
else. It is deliberately **not** a lexical match on the `hlcl` prefix, which would
be a rule about today's symbols rather than about where machine values live.

**Negative control, in the strongest available form:**

```
    dart hlclpqwxzq dart-main-entered              <- symbol suppressed
    dart hlclqjttgm boot-probe-returnd:boot-ok     <- "returnd" CAUGHT, on the
                                                      SAME LINE, beside it
Launch 1 (`hlclpqwxzq`) had a delibrate typo …     <- both still visible
```

A typo immediately beside the suppressed token, on the same line, stays reported.

**Six findings remain and are kept as explicit debt.** They are the prose quotes —
sentences reasoning about which launch produced which chain. Suppressing them would
need a rule over inline code spans in evidence, which is broader than the value it
buys and would hide authored identifiers generally. Per the contract's §5 default,
they stay visible. **Tree-wide green is therefore not reachable without a further
decision on these six**, and that is the honest state rather than a reason to widen
the rule.

**The two gaps, reconciled rather than rounded:**

* **Exclusions removed exactly 470 findings across 13 files**, as predicted. The
  chained figure reads 460 because **10 of the 35 `tpool` findings lived inside
  files the exclusions then removed**. Overlap, not error.
* **§3 was over-predicted by ~66, and the error was mine.** The estimate came from
  a regex matching British *morphology* (`-ise`, `-isation`, `-our`), which swept
  in project coinages that are not standard variants at all: `precommitted` (111),
  `precommitment` (9), `disqualifier(s)` (3), `precommitting`, `precommits`. Those
  survive §3 correctly — they fail its admission test — and belong to §2 as
  project vocabulary. **A morphology match is not a dictionary-variant test**, and
  categorizing by the shape of a word rather than by the rule's actual criterion
  is the same species of error the contract exists to prevent.

**What the narrowing bought, concretely.** Withdrawing `*.fulldiff.patch` from
`ignorePaths` in favour of §4 leaves **6 findings still visible** in those files —
and all six are on authored comment lines this repo wrote (`-Werror,-Wunused-function`
notes, `idevicesyslog` capture notes, a `SnapshotsDataHandle` explanation). A path
exclusion would have hidden every one.
The number above is the baseline. It is not permission to add to it: the
per-change gate already prevents that, since any file you touch must come out
clean whatever it inherited.

**3. Restored tree-wide gate — NOT YET.**

The four conditions below are unchanged. What was missing was their ORDER, and
the fact that two of them are one proof rather than two steps:

| # | step | done when |
|---|---|---|
| 1 | **Reduce by CATEGORY, not by dictionary.** The four categories above are already measured; work them in that order. Categories 1–2 (~60 %) are generated artifacts and vendored C++ identifiers inside `.patch` files — `ignorePaths`, not words. **Dictionarying everything would reach zero while destroying the signal**, since the point of the gate is to notice a real misspelling in prose | each category is either excluded with a stated reason or genuinely cleaned |
| 2 | **Reach actual tree-wide green** | the command exits 0 |
| 3 | **Negative control against the EXACT promoted command**, wrappers and pipes included | an injected misspelling makes *that command line* exit nonzero |
| 4 | **Delete this baseline record in the same commit that promotes the gate** | a debt that outlives its debt is the stale-status failure this repo keeps paying for |

**3 and 4 are ONE proof, and must land together:** a green tree plus a
deliberately red mutation showing the final command itself exits nonzero. Green
alone proves the count reached zero, not that anything is watching it — and
§17's guard rule is the reason the control must run through the promoted
*shape* rather than through `cspell` directly. A gate promoted on a green count
and wired up behind a pipe is exactly the inert guard that shipped three red
commits on 2026-08-16.

**The conditions in their original form:**
When categories 1–4 are cleared, promote the same command back to a required
green gate. Promotion is not complete until all four hold:

- the tree-wide command exits **0**;
- CI runs it — either `modified_files_only: false` on the `main.yaml` job, or a
  second job that does, so the runbook and CI agree rather than merely resemble
  each other;
- a **negative control** proves it can fail: introduce a misspelling in a file
  the change set does not touch, and require the tree-wide gate to go red.
  Without it, promotion only proves the count reached zero, not that anything is
  watching it — and `cspell_touched.sh`'s own `--self-test` already shows what
  that control looks like;
- the baseline files here are **deleted in the same commit**, since a recorded
  debt that outlives its debt is the stale-status failure this project keeps
  paying for.

## What this record does not claim

It does not claim the debt is harmless — 123 findings in `PARITY.md` means real
misspellings are sitting in the status authority, invisible because nothing looks.
It claims only that the tree-wide command cannot presently distinguish one of them
from the inherited floor, and that a check which cannot fail informatively should
be named as such rather than run ceremonially.
