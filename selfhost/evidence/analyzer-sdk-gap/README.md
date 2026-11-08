# The local analyzer is weaker than CI's, and by how much

Recorded 2026-08-16, from the investigation of CI's red `Build shorebird_cli` job.

## What happened

CI's `🎯 Build shorebird_cli (ubuntu-latest)` failed on
`dart analyze --fatal-warnings lib test` with **87 issues**: 86 infos and **one
warning**.

```
warning - lib/src/commands/patch/patch_command.dart:666:7 -
  Returning a 'Future' without 'await' inside a try block. - unawaited_return_in_try_block
```

`--fatal-warnings` acts on exactly that one line. The 86 infos are the inherited
floor and are not the gate — which is the distinction `HANDOFF.md` already draws,
working here as intended.

The same construct was live on this branch at `patch_command.dart:1171` and is
fixed in `198e38c2` (cherry-picked as `58d8cdd2`). It was a real defect: the
un-awaited return handed the Future to the caller before completion, so neither
`on UserCancelledException` nor `on UnpatchableChangeException` could fire.

## The gap this record exists for

**The local runbook command cannot see that warning at all.**

| | version |
|---|---|
| local Dart | **3.12.2** |
| CI Dart (`setup-dart@v1`, latest stable) | **3.13.0** |

Verified rather than inferred. A scratch package enabling the rule explicitly on
the local SDK answers:

```
warning - analysis_options.yaml:3:7 - 'unawaited_return_in_try_block' isn't a
  recognized lint rule. Try using the name of a recognized lint rule. - undefined_lint
```

The rule does not exist in 3.12.2. So `dart analyze --fatal-warnings lib test`
run locally is **not** the same check CI runs under the same name, and
`HANDOFF.md`'s *"expect exit 0"* is conditional on an SDK version the runbook
never states.

This is the same failure class as the cspell entry next door
([`../cspell/README.md`](../cspell/README.md)) — a local command that resembles
CI's without being it — but with the opposite sign. cspell's local form was
*stricter* than CI (tree-wide vs incremental), so it produced noise. This one is
*weaker*, so it produces silence: the branch analyzed clean locally while
carrying a warning CI would reject.

**Weaker is the more dangerous direction**, because a false green ends the
investigation.

## What this does NOT establish

* **Not** that 3.13.0 flags only this one thing on our tree. No 3.13 SDK is
  installed on this machine, so the full 3.13 result is UNMEASURED. What is
  established is that at least one 3.13 warning existed, and that the local
  analyzer is structurally unable to report rules it does not have.
* A hand scan of `lib/` for the same shape found no other instance: the only
  candidates inside a `try` with a clause the bug would bypass were
  `ios_patcher.dart:506` and `:583`, calling `verifyRouteBReleaseArtifacts`
  (`Map<String, File>`) and `RouteBCoverageAnalyzer.analyze` (`RouteBCoverage`) —
  both **synchronous**, so neither can exhibit it. That is a targeted check, not
  a substitute for running 3.13.

## First CI observation of `58d8cdd2` — INCONCLUSIVE

Fork run [31986647895](https://github.com/mml555/shorebird/actions/runs/31986647895),
2026-08-16, the first time this branch has been through the `ci` workflow at all
(it needs a `pull_request`, and none existed until draft PR #3).

| job | result |
|---|---|
| `🎯 Build shorebird_cli (windows-latest)` | **failure** — 2201 passed, **3 failed**, 12 skipped |
| `🎯 Build shorebird_cli (ubuntu-latest)` | **cancelled** (matrix fail-fast) |
| `🎯 Build shorebird_cli (macos-latest)` | **cancelled** (matrix fail-fast) |

**The fix is still unverified under CI, and the reason is the matrix, not the fix.**
Ubuntu is where the `unawaited_return_in_try_block` warning failed upstream and
where Dart 3.13 would exercise `58d8cdd2` — and fail-fast cancelled it when Windows
failed first. Nothing here confirms or refutes the repair.

**The Windows failures are a separate, previously unobserved problem.** They are
test failures, not analyzer failures:

```
❌ test\src\archive_analysis\archive_differ_test.dart:
     assetKeysReferencedByDart finds keys embedded in the compiled Dart
❌ test\src\archive_analysis\archive_differ_test.dart:
     assetKeysReferencedByDart ignores keys that appear only outside the Dart snapshot
❌ test\src\route_b_release_kernels_test.dart:
     RouteBReleaseKernelBuilder build differs from the release only in the mode
```

None is in the async-rejection group `58d8cdd2` added; all three pass locally on
macOS. They are **newly observed rather than newly introduced** — this branch had
never run through `ci`, so its Windows behaviour had never been looked at. Whether
they are path-separator assumptions or something real is unknown and is its own
investigation.

**What would settle the fix:** re-run the ubuntu job alone. `gh run rerun --job`
targets one job, so the answer costs one job rather than a full matrix.

### Precommitted outcomes for the ubuntu re-run — written BEFORE it was triggered

| observation | verdict |
|---|---|
| ubuntu **green** | **CI confirmation of the await fix.** `58d8cdd2` closes the `unawaited_return_in_try_block` failure under Dart 3.13, on the environment that produced it |
| the **same** `unawaited_return_in_try_block` warning | **fix REFUTED or incomplete.** The construct at `patch_command.dart:1171` was not the only instance, or `return await` did not satisfy the rule |
| a **different** failure | **the fix remains UNMEASURED.** Report the new blocker as its own item; do not read it as evidence either way about the await |

The middle row is the one worth naming: a green here is the expected result, and an
arm whose only outcome is the expected one proves nothing. This arm can refute.

### VERDICT — row 1: CI CONFIRMATION of the await fix

Fork run **31989293325**, after the two Windows fixes unblocked the matrix:
`🎯 Build shorebird_cli (ubuntu-latest)` → **success**.

**Checked before scoring it, because a green proves the fix only if the analyzer
that ran actually has the rule:**

```
Installing the linux-x64 Dart SDK version 3.13.0 from the stable channel.
Dart SDK version: 3.13.0 (stable) on "linux_x64"
Run dart analyze --fatal-warnings lib test
298 issues found.        <- all infos, zero warnings -> exit 0
```

3.13.0 is the SDK that introduced `unawaited_return_in_try_block` — the same
version, the same command, and the warning that failed upstream is gone. So this is
row 1 of the precommitted table: **`58d8cdd2` closes the failure under CI, on the
environment that produced it.** Not a vacuous green.

**Status of `58d8cdd2`: PROVEN.** Locally by a discriminating red/green regression,
and now under CI on Dart 3.13.

### Earlier re-run attempt — row 3: unmeasured (superseded above)

Attempt 2 ran the ubuntu job alone (started 02:25:03) and it came back
**cancelled**, not green and not red. Scoring it against the precommitted table
rather than around it: that is the third row. No observation about
`unawaited_return_in_try_block` was produced, so `58d8cdd2` is exactly as unproven
as before the re-run.

**The blocker is now identified, which is what the attempt bought.**
`build_cross_platform_dart_packages` declares
`matrix: {os: [macos-latest, windows-latest, ubuntu-latest]}` with **no
`fail-fast: false`**, so the default `true` applies: Windows failing cancels its
siblings — and it cancels a *single-job re-run* too, because the failed sibling
persists in the matrix. A targeted re-run cannot escape a matrix-level cancel.

**So settling `58d8cdd2` under CI needs one of two things first**, and both are
decisions rather than reruns:

1. **triage the three Windows test failures** (their own lane), after which the
   matrix completes normally; or
2. **`fail-fast: false` on that matrix**, so all three platforms report
   independently. A real improvement — one run would then tell you about every
   platform instead of the first to fail — but it changes CI behaviour for every
   package in that matrix and costs more minutes, so it is not a side effect to
   introduce while chasing one lint.

Until then the honest status of `58d8cdd2` is: **fixed and locally proven by a test
that fails without it; unverified under CI.**

## What would close it

Pin or match the analyzer version so the local command and CI's are the same
check. Three options, cheapest first:

1. **State the version in the runbook** and treat a local green on an older SDK
   as provisional. Costs nothing; closes nothing.
2. **Install the SDK CI uses** and run the gate on it. Note the hazard: this
   machine's Dart comes from pinned Flutter caches under `~/.shorebird`
   (all 3.12.2), and upgrading a toolchain on the rig can disturb builds this
   repo pins deliberately — so any install should be side-by-side, not a
   replacement.
3. **Pin CI instead**, giving `setup-dart` an explicit `sdk:` rather than latest
   stable. That makes CI reproducible and stops the gate moving under the fork
   without a commit, at the cost of choosing when to take a new SDK.

Until one of those, the honest statement is the one now in `HANDOFF.md`: local
analyze is a pre-flight, and CI is the gate.
