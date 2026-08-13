<!-- cspell:words obfuscation xcconfigs xcconfig gclient dSYM -->

# Build plans — take one piece, execute it alone

**What this directory is.** One file per piece of work, written so a fresh agent can
execute it **without reading three long documents first**. Each file is a *work order*:
preconditions with commands, steps with real paths and line anchors, precommitted
outcomes, exit criteria, the evidence to record, and the commit to make.

**How it relates to the documents above it.** They answer different questions, and
mixing them is what made the work hard to pick up:

| document | answers |
|---|---|
| [`../PARITY.md`](../PARITY.md) | **what** parity means, **where we stand**, and **why** — the status ledger and the priority queue. The authority on any status |
| [`../ROUTE_B.md`](../ROUTE_B.md) | **how** iOS Dart code push works — the plan of record for the mechanism |
| [`../HANDOFF.md`](../HANDOFF.md) | the dated working log: evidence chains and debugging traps |
| **this directory** | **how to do one specific thing next**, start to finish, alone |

`PARITY.md` stays the authority on status. A work order that disagrees with it about a
status is wrong, and the fix goes in the work order. But a work order may be *ahead* of
`PARITY.md` on state — it is written against a commit, and it says which one.

---

## The situation these orders were written into

The batch mint landed as **`ba4e1c02`** (cell
`4df8f9b6139b67d2cfe9f6aa8212372cade36278`), and then **`c0619d13`** established
something that reshapes the whole queue:

> **All four device gates are blocked by harness prerequisites, not by defects in the
> thing under test.** Releases 33–36 were cut against the cell; 33 and 34 were
> discarded, 35 and 36 are preserved specimens.

That is a good problem — the mechanism work is not what is missing. But it means the
next actionable pieces are **four prerequisites**, three of which are fixture or host
gaps needing no device and no mint:

| block | prerequisite | order | unblocks | needs |
|---|---|---|---|---|
| **H1** | the fixture has no parameterised target on a **live** path — `tagged(String x)` is called only inside `value()`'s dead branch, so a patch to it would execute never | [`H1-live-parameterised-target.md`](H1-live-parameterised-target.md) | `G3.7` | `R6`, one release, one launch |
| **H2** | no flavored iOS fixture — one scheme, no flavor xcconfigs, so `--flavor` cannot build and there is nothing to mismatch against | [`H2-flavored-ios-fixture.md`](H2-flavored-ios-fixture.md) | `G4.2` arms 1/3/5 | a **new** fixture, so no `R6` contention |
| **H3** | no host creates two `FlutterEngine`s in one process | [`H3-two-engine-harness.md`](H3-two-engine-harness.md) | `G15` | `R3`, host only |
| **H4** | our `gen_snapshot` has no `--load-obfuscation-map`, and the patcher mirrors the release's obfuscation itself — so an obfuscated release cannot be patched on this engine at all | [`H4-gen-snapshot-obfuscation-map.md`](H4-gen-snapshot-obfuscation-map.md) | `G4.3` arm 4 | Dart-VM work + a mint |

> **`H` for harness, deliberately not `P`.** In this project `P1`/`P2`/`P3` already mean the
> **retention policies** — `P2` is the one that was chosen, `P3` is the one that collapsed. When
> `G3.6b` says "P2 is decided" it is talking about a policy, not about a flavored fixture.

**The lesson `c0619d13` paid for, and the one most worth carrying into the next order:
consumption is necessary but not sufficient.** `assert_result_consumed.sh` correctly
reports the dead call site as CONSUMED, because its result feeds a string
interpolation — and a patch there would still never run. **Reachability is a separate
property, and no byte-level gate can see it.**

---

## Pick a piece

Ordered so the things that *unblock other things* come first. "device" means a gate is
owed real hardware; three of the top four need none.

| order | what taking it gets you | status | owns | device | mint |
|---|---|---|---|---|---|
| [`H1`](H1-live-parameterised-target.md) | a parameterised target the app actually calls, observable in the beacon — unblocks `G3.7`'s device arm | **PARTIAL** — the target went live at `08a2f3cc`; the READOUT is the gap (`_rbParam` is beaconed, never displayed, and the beacon carries no query string on this rig) | `R6` `R8` `R1` | R1, one launch | no |
| [`H2`](H2-flavored-ios-fixture.md) | a flavored iOS fixture — unblocks three of `G4.2`'s five arms | **PARTIAL** — sources + iOS overlay landed at `41758dd3`, `xcodebuild -list` resolves all six flavored configurations; `prepare_flavored_fixture.sh` and step 7's host arms remain | new fixture | no | no |
| [`H3`](H3-two-engine-harness.md) | two engines in one process + patch `0007`'s tests actually running — makes `G15`'s device row runnable instead of NOT RUNNABLE | NOT BUILT | `R3` `R5` | no | no |
| [`H4`](H4-gen-snapshot-obfuscation-map.md) | decides whether obfuscated iOS patching is reachable at all, or a documented gap | NOT RUNNABLE | `R3` `R4` | later | yes |
| [`G3.7`](G3.7-param-abi-device-gate.md) | the parameter-ABI device verdict — the last clause of the architectural question, 33.2 % of structural reach | BUILT, device owed | `R1` `R6` `R8` | **R1** | no |
| [`G4.2`/`G4.3`](G4.2-G4.3-config-device-gate.md) | the configuration arms, each annotated for constructibility, plus the independent Android lane | BUILT, device owed | `R2` `R9` `R12` | **R2** | no |
| [`G3.6b`](G3.6b-app-private-holes.md) | the two accepted-then-failed private holes turned into refusals with named evidence | PARTIAL | `R7` `R3` | no | yes |
| [`G6`/`G7`/`G8`/`G10.2`](G6-G7-G8-G10.2-no-hardware-lanes.md) | four small orders under one roof — the whole set an agent can take with **zero** contended hardware | PARTIAL | `R10` | no | no |
| [`L1`](L1-leverage-lane.md) | fixture clones (raises the §16 parallelism ceiling), then Android add-to-app, the `G5` remainder, and the sealed `G13` run **last and alone** | NOT BUILT | many | both | no |
| [`M0`](M0-cell-mint-and-identity.md) | how to mint a cell and close its identity — plus cell `4df8f9b6`'s worked example and the repair its audit still owes | BUILT | `R11` `R3` | no | — |

**Zero-hardware lanes, if you want to start right now and take nothing scarce:**
[`G6`/`G7`/`G8`/`G10.2`](G6-G7-G8-G10.2-no-hardware-lanes.md) (`R10` only),
[`H2`](H2-flavored-ios-fixture.md) (a new fixture contends on nothing), and
[`H3`](H3-two-engine-harness.md) (host work in `R3`).

---

## Before you touch anything

These are not this directory's rules; they are the project's, and every one of them has
already cost somebody real work. The full statements live in
[`../PARITY.md`](../PARITY.md) §16, §17 and *Rule for updating this file*.

1. **Read the tree first.** `git log --oneline -5` and `git status`. This is a **shared
   working tree** on one branch. Stage explicit paths — `git add <path>`. Never `-A`,
   never `commit -a`, never `stash`/`restore`/`checkout`/branch-switch: another worker's
   in-flight edits sit unstaged beside yours. Two commits landed *while these orders
   were being written*, which is exactly how ordinary this is.
2. **Claim what you take**, in §17's claims table, **in the same commit as the work** —
   and clear your row when you stop, **even mid-goal**, saying what state you left the
   resource in. `R1` (the phone) and `R3` (the engine checkout) cannot be shared and
   **cannot be detected**: an unclaimed resource looks exactly like a free one.
3. **A write claim reports TREE HEALTH, not just ownership.** GREEN (verified, safe to
   build against) versus RED/mid-edit. "Someone owns this" and "this does not currently
   compile" are different facts, and the second one cost another session a mint.
4. **Status discipline.** **PROVEN** means the real product workflow completed and the
   observable result was verified, on device where applicable. A host probe earns
   **BUILT**. Passing tests, a compiler accepting something, or a container being
   generated earn **nothing**. Never upgrade a status because it feels close.
5. **NOT RUNNABLE is not the same as unrun.** If the harness does not exist, say so
   rather than booking a device.
6. **The classification rule.** If source already determines the behavior, it is a
   **KNOWN GAP** — a decision to make — not an unvalidated question to test. Check
   whether reading the code closes a row before adding it to the device queue.
7. **The precommitment rule.** Before a run whose favourable-looking outcome would be
   ambiguous, write down what each result will **mean**. Favourable results are the
   dangerous ones: a red result gets interrogated, a green one gets banked. This has
   prevented two false greens already.
8. **The CLI under test must be the CLI you changed.** `~/.shorebird` is its own
   checkout with a `fork` remote and does **not** move when you commit. Release 34 was
   discarded for exactly this, and its failure looks precisely like a `G3.7` failure.
9. **Claim the PATH, before the first file exists — not just an `R-id`.** Every
   protection in §17 is keyed to the claims table, and the table is keyed to
   `R-ids`, so **a resource that does not exist yet cannot be claimed.** An order
   that creates something new — `H2`'s whole value is that it is a *second*
   fixture, owning no `R6` — has no row to hold, and `git status` then shows one
   untracked directory that two workers each correctly read as their own. **This
   cost real duplicated work on 2026-08-13:** two sessions took `H2` four minutes
   apart, one committed the other's unstaged transform while describing it as not
   done, and the other clobbered that commit's `xcconfig`s sixty seconds later.
   Nothing was lost, by ordering rather than by design — the third such escape.
   A claims row naming the path, with no `R-id` at all, would have prevented it: a
   claim is a statement of intent, not a property of an existing artifact.
10. **A commit message is not evidence of its own contents — `git show --stat`
    is.** When two workers are live, read the diffstat of any commit you build on.
    The worker whose broad stage swallowed your files does not know it happened,
    and will tell you in good faith that the work is still owed.
11. **Never run a negative control by editing in place in the shared tree.** Copy the
   subject into a scratch worktree, or land the fix first and revert in a throwaway.
   **This cost real attribution on 2026-08-13:** a fix to `ios_patcher.dart` was
   deliberately commented out for sixty seconds to prove its tests fail without it,
   and in that window another worker committed the tree — capturing the *disabled*
   state plus four tests, three of which failed against it (`de11eecf`), which a
   third commit then had to repair (`4fb03725`). Nothing was lost, and only because
   the window was short. The generalisable part is the same as §17's: **an unstaged
   file looks exactly like yours, and a deliberately-broken file looks exactly like a
   mistake.**

---

## Writing a new work order

Copy the skeleton below. Keep the heading order — agents and greps both depend on it.

<details>
<summary>Work-order skeleton</summary>

```markdown
# <ID> — <short title>

> One sentence: what is true at the end that is not true now.

| field | value |
|---|---|
| status | <exact PARITY.md label + one clause of justification> |
| owns | <R-ids, or none> |
| excludes | <what cannot run concurrently, and why> |
| blocked by | <goal / artifact / prerequisite, or nothing> |
| unblocks | <what this releases> |
| device needed | <R1 iPhone / R2 Android / none> |
| mint needed | <yes + why / no> |
| est. shape | <shape, not a promise> |

**Provenance.** <authored against which commit; verified or not>

## Why this is the piece it is
What makes it standalone, and what it deliberately does NOT include.

## Preconditions — check these before claiming anything
Numbered. Each a command AND its expected result. Include the §17 claims check and
tree health where a contended resource is involved.

## Steps
Numbered. Each: what changes, WHERE (path or file:line), HOW (exact command or edit
shape), HOW YOU KNOW IT WORKED. Mark shared-state mutations **[MUTATES <what>]**.
If something needed does not exist, say so and make building it a step.

## Precommitted outcomes
Every observation the decisive step can produce and what each MEANS — including the
favourable-looking ones — and which are producer/host findings vs device findings.
Reuse an existing precommitted table verbatim; never edit one to match reality.

## Exit criteria
What earns BUILT, what earns PROVEN, what would make this NOT RUNNABLE.

## Evidence to record
Exact paths, what each file must contain, and the identity facts: cell/engine hash,
release version, patch number, platform/device, probe name, commit.

## Commit shape
Explicit per-path `git add` lists (never `-A`), semantic commit titles, and the
PARITY.md edits that must land in the SAME commit (status row, claims row).

## Do not
Traps specific to this goal, drawn from recorded failures.

## Open questions
What the next worker must decide, with the tradeoff.
```

</details>

**Three rules for the order itself**, each earned:

* **Cite what you verified, not what you assume.** Every path, flag and command in a
  work order should have been run or read. An invented path is worse than a missing
  one, because it reads as authority.
* **Line anchors decay.** `PARITY.md:NNNN` shifts every time that file is edited. Say
  which commit an anchor was verified at, and quote the heading so the next reader can
  re-grep it.
* **When state overtakes an order, correct it where it sits** rather than editing it
  silently. A reader who acted on the old text needs to know it changed.
