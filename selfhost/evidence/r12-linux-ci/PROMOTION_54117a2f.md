# Cell 54117a2f over engine d0714887: the frozen chain, run on ci-build

Date 2026-11-19 to 2026-11-20. Chain: `selfhost/TOOLCHAIN_PROMOTION.md`, run as `PROMOTION_a6a48cf6.md` was. This
mints a new cell address over the same engine `d0714887` (Dart `b4671ab7`). Only one member of the Route B compiler
archive changes: `route_b_analyze.aot`, AOT-built from main `bc6ecdb1` (PR #256, after #247, #248, #251 and #252),
analysis version 23. CLI commit under test: `f66e3c219cf85287f463ac5f1e12fddf1d052af5` (the merge of PR #255, which
selects this cell; `R12_REPO_SHA`). The record's `cli_revision` is `37a0434bcf986bf2e36549591671f9fa181b5a52` (the merge
of #257). Between the two, `packages/shorebird_cli` changes in five files (`route_b_producer.dart`,
`route_b_release_kernels.dart`, the `route_b_scope` fixture pair and `route_b_producer_test.dart`: #257, an extension
getter's target packed under its VM name) and `bin/internal` is unchanged (same tree `06cce90c`, checked with
`git diff --quiet f66e3c21 37a0434b -- bin/internal`). That is the iOS release and patch path, which none of the chain's
Linux steps runs.

    cell address       54117a2fe0510a8cb070faf3f5191542179fb4ce   macos-ios-android, 30 members
    flutter_revision   f4024608592183cbfc27ff404e9fb23e84096f95   shorebird-flutter: 0987ce0a + engine.version = 54117a2f (one line)
    engine bytes       d0714887dd95d2990e0185fe1893523f3d600cc5   published members, byte for byte, except the compiler archive
    fallback           38855c84ca367c58165b8e3844dd7d6a99dec844   as d0714887's own experimental_hashes.map entry
    updater_revision   87c198d30f875a3da317d70935e1025dc13064dd   unchanged

Run in `/srv/ci-cache/shorebird-engine/promo-54117a2f` on ci-build with `R12_REPO_SHA=f66e3c21`. The chain ran from
23:26:10Z to `CHAIN_DONE` 2026-11-19T23:57:06Z, gates 1 to 8 once each, arm A exit 0. R12 arm B ran after it and
finished at 2026-11-20T00:13:52Z (the launcher's done marker), exit 0. This is the first attempt on this cell that ran to the end;
one earlier attempt was aborted (below) and is not evidence.

## Why a new cell over the same engine

`a6a48cf6`'s analyzer (version 21) records a for-in as `Iterable.iterator` with no receiver type, so the CLI's SDK
kept check demanded `get:iterator` on `ObserverList` and refused a List loop; the iPhone run on `a6a48cf6` had to
publish nine of eleven patches with the check skipped (#247). Analysis version 23 (#247) fixes that where the
loop names its receiver, and #256 fills the receiver on the loop's VM-lowered form (`:sync-for-iterator`), which is the
form a real dill holds. The analyzer lives in the compiler archive, which is a cell member, so the change needs a new
address. (A candidate `3d24e504` was staged and never published; #256 superseded it.)

## What was minted

The archive is `a6a48cf6`'s with `route_b_analyze.aot` rebuilt from `bc6ecdb1` (analysis version 23,
`cd4d2663...`, was `768c0109...`). Every other member is byte-identical to `a6a48cf6`'s; `PROVENANCE.txt` differs
in the build time and the analyzer's digest. Archive `e44ac8e6...`, 19976827 B (was `1ca11779...`, 20028870 B).
`audit_route_b_compiler.sh` reported AUDIT CLEAN.

The cell has 30 addressed members; 29 are `a6a48cf6`'s bytes once the address is normalized, and the 30th is the
compiler archive. Seven members are rendered to the address: `engine_stamp.json`, the four POMs,
`artifacts_manifest.yaml` and the descriptor. The same 26 unaddressed host files ship as `host-extras-<address>.tar`.

Checks run on the Mac before the chain: `inlined_ops_qualify.sh --require-v21` against the cell's own compiler,
runtime and platform: QUALIFIED (170 targets); a check that the cell's own analyzer reports analysis version 23 and
names the List receiver on a real `--aot --tfa` dill; `qualify_cell_address_v2.sh`: QUALIFIED (55 checks);
`verify_cell_members.sh` 30 of 30; `audit_route_b_compiler.sh`: AUDIT CLEAN; `check_protection_matchers.py`: `MATCHER
COVERAGE OK`. Against release `1.0.0+70`'s snapshot profile the CLI's kept check refuses `_HomeState._start` with the
previous analyzer (`ObserverList.get:iterator`) and accepts it with this cell's analyzer.

Installed on ci-build by the owner: INSTALL OK. The CDN change is in PR #255 (`experimental_hashes.map`, the
Caddyfile per-cell groups, and the descriptor `selfhost/engine/route_b/cell_manifests/54117a2f....v2`).

## Gates

| # | Gate | Result | Evidence |
|---|---|---|---|
| 1 | candidate exists in the owned Flutter mirror | PASS: `f4024608` at `refs/heads/selfhost/3.47-cell-54117a2f` | `promotion-54117a2f/guard_candidate.log`, `chain.log` |
| 2 | exact `engine.version` | PASS: `54117a2fe0510a8cb070faf3f5191542179fb4ce` | same |
| 3 | SEALED + COLD bootstrap discovery | PASS: `BOOTSTRAP COMPLETED under seal after 0 additions` | `promotion-54117a2f/bootstrap_discovery.log` |
| 4 | bootstrap manifest banked | PASS: 2 rows (dart-sdk 214945654 B, sha `91dfc837...`; engine_stamp 239 B, sha `eb795a40...`), proxy mapping `60b64aa3...` -> `89c39edf` | `bootstrap_closure.tsv`, `proxy_mapping.tsv` |
| 5 | `bootstrap_closure_guard.sh` | PASS: `CLOSURE OK f4024608 -> 54117a2f`, 1 artifact (the engine stamp) size + SHA-256 verified, proxy mapping pinned | `promotion-54117a2f/guard_candidate.log` |
| 6 | fresh sealed cold bootstrap | PASS: bootstrap-only arm BOOT1, fresh container, exit 0; `Flutter 3.46.0-1.0.pre-866`, `Shorebird Engine • revision 54117a2f...`. Sealed mirror: 7 requests, 5 overlay hits, 0 `/gcs/`, 0 non-overlay 200s; the two 502s are both `GET /` (the harness's probe) | `promotion-54117a2f/arms/arm-BOOT1`, `boot1_access.txt` |
| 7 | sealed release/patch artifact discovery | PASS for the closure: iterations 1 to 10 each refused one artifact and imported it (ten stock files, below); iteration 11 exited 1 and refused nothing (`STOP — harness failed with NOTHING refused by the seal`), because the discovery harness's arm 3 expects the release chooser to refuse and the discovery control plane had one release (`arm 3 exited 0, expected 64`). The same stop ended step 7 for `a6a48cf6`; the closure is complete and arm A is the gate for the smoke | `release_patch_discovery.log`, `release_patch_closure.tsv`, `rp_access.txt` |
| 8 | fresh Linux release/patch smoke | PASS: R12 arm A on gate 7's control plane, fresh container, fresh cold mirror, exit 0: 40 requests, 38 overlay hits, 0 `/gcs/`, 0 non-overlay 200s (the two 502s are the harness's `GET /`); fixture 1.0.0+1; arm 3 refused the chooser by name, exit 64 | `armA.log`, `armA_access.txt`, `arms/arm-A` |
| 8b | R12 arm B (run after the chain, `bin/armB_go.sh`) | PASS: fixture 1.0.1+1 on arm A's control plane (`releases_before.log` lists 0.8.11+11 and 1.0.0+1), fresh container, fresh cold mirror, exit 0, 00:03Z to 00:13Z: detector self-tests exit 64/64, release and patch published, `--json` patch 0 prompt hits, arm 3 refused the chooser by name (exit 64). 40 requests, 38 overlay hits, 0 `/gcs/`, 0 non-overlay 200s (the two 502s are the harness's `GET /`) | `armB.log`, `armB_access.txt`, `arms/arm-B` |

The ten imports are the same ten stock files as in the `a6a48cf6`, `2fc41d3f` and earlier runs (seven
`android-*/artifacts.zip` and three `android-*-profile/linux-x64.zip`), now under the `54117a2f` client path. They are
stock engine bytes from the fallback `38855c84` (one, `android-x86/artifacts.zip`, from Flutter's own `89c39edf`), not
built from `d0714887`. The known gap stated in `compatibility.yaml` is unchanged. Their imports went into the
production overlay on ci-build, as in earlier chains; the rows are in `release_patch_closure.tsv`.

## How the run went

The passing run is the first complete one, `promo-54117a2f/logs/chain.log` (`chain.pid` 23:26:10Z). Before it, one
attempt was started in the wrong workspace: the chain and arm B were launched concurrently (about 23:21Z) in
`/srv/ci-cache/shorebird-engine/promo-a6a4`, the previous cell's directory, before the new workspace was finished, and
were killed. Its logs are `promo-a6a4/logs/chain.log` (stops after gate 3 started; it served `cc4fc222`, the
`a6a48cf6` selector) and `promo-a6a4/logs/armB.log` (stops in the first shorebird invocation). They name the previous
cell's candidate, passed no gate for this cell and are **aborted and not evidence**. They are not copied here.

The harness is `selfhost/ci/r12` at `f66e3c21`, which includes PR #228 (bounded, retried GitHub clones). No harness file
was patched in the workspace. Arm B's `logs/armB.log` on ci-build holds the launcher's and the wrapper's output; the
copy here is its final content. `chain.log`, `armA.log` and `armB.log` are copied from the workspace's `logs/`; the rest
of this directory is the workspace's `evidence/` as it stood after arm B.

## Device run

Run on 2026-11-19 through the cell's address; its record is
`selfhost/engine/route_b/evidence/ios-cell-54117a2f/RESULT.md` (PR #259). **Verdict: every expected pass and refusal
held.** Every published patch applied, the refusals were correct, the SDK kept check stayed on with no override (so the
for-in false positive of `a6a48cf6` did not recur), and three rollbacks passed. One check FAILED on the first pass: e1b,
an extension getter published with a truncated target name. #257 (merge `37a0434b`) fixes it, and the re-run on CLI
`37a0434b` PASSED (patch 13, 1 of 1 applied, `stars=*3*` on both boot launches). Limits: the patches were unsigned,
because the CLI's P7 patch signing has not landed, and #254 was not exercised.

## Not done

- Signed patches and #254 on the device (the limits above).
- `verify_supported_state.sh` against the overlay and a populated Shorebird checkout: not run here (see the PR for what
  was run).
- The chain did not run the CLI pinned in `compatibility.yaml` (`37a0434b`), but `f66e3c21`, which lacks #257 (see the top); `37a0434b`, or a later main, is the CLI to use.
