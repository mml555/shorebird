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

Categories 1 and 2 are ~60 % of the count and cost no judgement. Category 4 is
mechanical. Category 3 is the only one needing a reviewer.

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
