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
