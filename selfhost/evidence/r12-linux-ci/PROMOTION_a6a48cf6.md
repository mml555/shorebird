# Cell a6a48cf6 over engine d0714887: the frozen chain, run on ci-build

Date 2026-11-17. Chain: `selfhost/TOOLCHAIN_PROMOTION.md`, run as `PROMOTION_2fc41d3f.md` was. This mints a
new cell address over the same engine `d0714887` (Dart `b4671ab7`). Only one member of the Route B compiler
archive changes: `route_b_analyze.aot`, AOT-built from main `825085505` (after PRs #217, #219 and #223), analysis
version 21. CLI commit under test: `af1e14a1e6e95730c528111fc118c1b64c6e3728` (PR #226's head; its merge
`3f10d18ef97ea46b1f29f244ebecd1596792ccdf` has the same `packages/shorebird_cli` and `bin/internal` trees,
checked with `git diff --quiet af1e14a1 3f10d18e -- packages/shorebird_cli bin/internal`).

    cell address       a6a48cf673a291f607323e89b41839c4b8b74e5d   macos-ios-android, 30 members
    flutter_revision   cc4fc222c210836f89bde6e91f7580e8241432da   shorebird-flutter: 0987ce0a + engine.version = a6a48cf6 (one line)
    engine bytes       d0714887dd95d2990e0185fe1893523f3d600cc5   published members, byte for byte, except the compiler archive
    fallback           38855c84ca367c58165b8e3844dd7d6a99dec844   as d0714887's own experimental_hashes.map entry
    updater_revision   87c198d30f875a3da317d70935e1025dc13064dd   unchanged

Run in `/srv/ci-cache/shorebird-engine/promo-a6a4` on ci-build with `R12_REPO_SHA=af1e14a1`. The passing run is the
fourth; it ran from 22:17:09Z to `CHAIN_DONE` 22:44:44Z. Gates 1 to 8 ran once each in it. Three earlier runs did
not finish; they are listed under "How the run went", and none of them failed on a product defect.

## Why a new cell over the same engine

PRs #217 and #219 made the coverage analyzer version 21: operator references the patch's bytecode compiler turns
into opcodes are marked `inlined`, the inferred signature types are written into lowered signatures
(`signatureTypes`), and the enclosing scope of class and extension members is reported (`enclosingScope`). Against
an older analyzer the CLI on main refuses class and extension member targets, so those patches reach users only
through a new cell. The analyzer lives in the compiler archive, which is a cell member, so the change needs a new
address.

## What was minted

The archive is `2fc41d3f`'s with `route_b_analyze.aot` rebuilt from `825085505` (analysis version 21,
`768c0109...`, was `c3898f45...`). Every other member is byte-identical to `2fc41d3f`'s; `PROVENANCE.txt` differs
only in the build time and the analyzer's digest. Archive `1ca11779...`, 20028870 B (was `768ad4b8...`,
19835885 B). `audit_route_b_compiler.sh` reported AUDIT CLEAN.

The cell has 30 addressed members; 29 are `2fc41d3f`'s bytes once the address is normalized, and the 30th is the
compiler archive. Seven members are rendered to the address: `engine_stamp.json`, the four POMs,
`artifacts_manifest.yaml` and the descriptor. The same 26 unaddressed host files ship as
`host-extras-<address>.tar`.

Checks run on the Mac before the chain (PR #226): `inlined_ops_qualify.sh --require-v21` against the cell's own
compiler, runtime and platform: QUALIFIED (170 targets; it needed PR #225, because the harness predated #219's
type-parameter refusal); `qualify_cell_address_v2.sh`: QUALIFIED (55 checks); `verify_cell_members.sh` 30 of 30;
`audit_route_b_compiler.sh`: AUDIT CLEAN; `verify_cell_completeness.sh`: COMPLETE.

Installed on ci-build by the owner: INSTALL OK, 57 files served from the overlay, audits clean. The CDN change is in
PR #226 (`experimental_hashes.map`, the Caddyfile per-cell groups, `check_protection_matchers.py`: `MATCHER COVERAGE
OK`, and the descriptor `selfhost/engine/route_b/cell_manifests/a6a48cf6....v2`).

## Gates

Of the passing (fourth) run.

| # | Gate | Result | Evidence |
|---|---|---|---|
| 1 | candidate exists in the owned Flutter mirror | PASS: `cc4fc222` at `refs/heads/selfhost/3.47-cell-a6a48cf6` | `promotion-a6a48cf6/guard_candidate.log` |
| 2 | exact `engine.version` | PASS: `a6a48cf673a291f607323e89b41839c4b8b74e5d` | same |
| 3 | SEALED + COLD bootstrap discovery | PASS: `BOOTSTRAP COMPLETED under seal after 0 additions` | `promotion-a6a48cf6/bootstrap_discovery.log` |
| 4 | bootstrap manifest banked | PASS: 2 rows (dart-sdk 214945654 B, sha `91dfc837...`; engine_stamp 239 B, sha `9020f215...`), manifest digest `efbf6ef7...` | `bootstrap_closure.tsv`, `proxy_mapping.tsv` |
| 5 | `bootstrap_closure_guard.sh` | PASS: `CLOSURE OK cc4fc222 -> a6a48cf6`, 2 artifacts size + SHA-256 verified, proxy mapping pinned (`efbf6ef7...` -> `89c39edf`) | `promotion-a6a48cf6/guard_candidate.log` |
| 6 | fresh sealed cold bootstrap | PASS: bootstrap-only arm BOOT1, fresh container, exit 0; `Flutter 3.46.0-1.0.pre-866`, `Shorebird Engine • revision a6a48cf6...`. Sealed mirror: 7 requests, 5 overlay hits, 0 `/gcs/`, 0 non-overlay 200s; the two 502s are both `GET /` (the harness's probe) | `promotion-a6a48cf6/fresh_bootstrap_launch.log`, `boot1_access.txt`, `arms/arm-BOOT1` |
| 7 | sealed release/patch artifact discovery | PASS for the closure: on iteration 1 the harness exited 1 and refused nothing (`STOP — harness failed with NOTHING refused by the seal`), because the ten files had already been imported by the first run (below). The discovery harness's own verdict was FAIL (EXIT=1), which does not apply here, as in `PROMOTION_2fc41d3f.md`: its control plane holds one release, so arm 3's chooser uses it. Arm 3 is decided by arm A. `rp_access.txt`: 37 requests, 36 overlay hits, 0 `/gcs/`, 0 non-overlay 200s (the one 502 is the harness's `GET /`) | `promotion-a6a48cf6/release_patch_discovery.log`, `rp_access.txt`, `release_patch_closure.tsv` (10 rows under `a6a48cf6`, from run 1) |
| 8 | fresh Linux release/patch smoke | PASS: R12 arm A on gate 7's control plane, fresh container, fresh cold mirror, exit 0: 40 requests, 38 overlay hits, 0 `/gcs/`, 0 non-overlay 200s (the two 502s are the harness's `GET /`); arm 3 refused the chooser by name, exit 64 | `promotion-a6a48cf6/armA.log`, `armA_access.txt`, `arms/arm-A` |

The ten imports are the same ten stock files as in the `2fc41d3f`, `aab9fd07`, `5f6efd98` and `82fc78a8` runs
(seven `android-*/artifacts.zip` and three `android-*-profile/linux-x64.zip`), now under the `a6a48cf6` client
path. Their sizes and SHA-256 digests equal the `2fc41d3f` rows' (compared row by row, 10 of 10). They are stock
engine bytes from the fallback `38855c84` (one, `android-x86/artifacts.zip`, from Flutter's own `89c39edf`), not
built from `d0714887`. The known gap stated in `compatibility.yaml` is unchanged.

## How the run went

Four runs, in `/srv/ci-cache/shorebird-engine/promo-a6a4`. Only the fourth is the evidence above. The logs of the
others stay in the workspace (`logs-run1/` to `logs-run3/`, and `evidence-run1/` for run 1's ledgers); they are not
copied here.

1. **Run 1** (20:35:04Z, `logs-run1/`) went through gates 1 to 6, then step 7. The chain's watchdog watched only
   `chain.log`, which does not grow while step 7 runs, because the discovery harness writes `rp.log`. It killed
   step 7 (`WATCHDOG: no log growth for 15 min, killing`) while it was making progress: `rp.log` shows iterations 1
   to 10 each refusing one artifact and importing it (`importing ... owned: ...`), and iteration 11 had started.
   **Those imports went into the production overlay on ci-build**: the `owned:` lines name the ten files under the
   `a6a48cf6` client path, and each file was copied from the fallback `38855c84` (or Flutter's `89c39edf`) by the
   mirror's own import, the same ten as in earlier cells. Run 1's ledger rows are the ten in
   `release_patch_closure.tsv`. The fix was in the workspace's `bin/watch.sh`: it now watches the whole logs
   directory. It is the workspace's, not this repository's.
2. **Run 2** (21:04:10Z, `logs-run2/`) stopped at step 4 (`CHAIN STOP: ledger already has a6a48cf6... rows`),
   because run 1 had banked ledger rows. The workspace's ledgers were reset from PR #226's commit, with run 1's
   kept in `evidence-run1/`.
3. **Run 3** (21:27:58Z, `logs-run3/`) went through step 5, then the arm of step 6 hung for 15 minutes in
   `git clone` of `mml555/shorebird` until the watchdog killed it (a clone of the same repository on the host took
   13 s). That was a harness defect, not a product one. PR #228 (merged as `87e6f017`) bounds and retries the
   harness's GitHub clones.
4. **Run 4** (22:17:09Z, the workspace's `logs/`) is the passing run.

The harness difference from the CLI under test's commit `af1e14a1` is PR #228. Three scripts were installed in the
workspace from `87e6f017`, and the `af1e14a1` originals were kept beside them as `ci/r12/*.sh.af1e14a1`:
`discover_closure.sh`, `discover_release_closure.sh` and `run_arm.sh` (`selfhost/ci/r12/`, 23 lines added, 9
removed: a bound and a retry on each GitHub clone, and the checkout bounded in the same attempt). They run the
harness, not the product; the CLI, the cell and the control plane are the same in all four runs. The ledger files in
this record are the chain's own: the two bootstrap rows and the proxy mapping from run 4, and the ten
release/patch rows from run 1.

## Device run

TODO: not yet run. The iPhone sequence for this cell (the `2fc41d3f` sequence repeated through the cell address,
plus the class and extension member edits that analysis 21 allows) is to be recorded in
`selfhost/engine/route_b/evidence/ios-cell-a6a48cf6/RESULT.md`, and its outcome summarised here. Until it is filled in,
the cell is promoted on the Linux chain but NOT device-qualified.

## What a patch can change now

TODO (to be confirmed by the device run): a class or extension member whose body names its own class's statics, and
an operator reference the patch's bytecode compiler emits as an opcode, are accepted by the version-21 analyzer;
`2fc41d3f`'s analyzer refuses the first for the CLI on main. Everything `2fc41d3f` adds (private top-level and
instance helpers) is unchanged.

## Published

The tag `selfhost-flutter-cell-a6a48cf6` on shorebird-flutter is annotated (tag object `04cdfca8`) and points at
`cc4fc222`. The release `cell-a6a48cf6` on mml555/shorebird was published 2026-11-17T20:29:03Z, targets `966b6318`
(the select commit of PR #226, which is in `main`; `cell-2fc41d3f` targeted the merge) and is not marked latest.
GitHub's digest of each of its six files:

| File | SHA-256 |
|---|---|
| bundle `cell-a6a48cf6....tar` (741057536 B) | `cdeb3922...` |
| `host-extras-a6a48cf6....tar` (843950592 B) | `fb9f6fc5...` |
| descriptor `cell_manifest.v2` (4141 B) | `a6a48cf6...f8df0015...` |
| `LAYOUT.txt` (5993 B) | `01f3bd21...` |
| `CELL.txt` (386 B) | `9f1436dc...` |
| `MANIFEST.sha256` (276 B) | `b7fd3f51...` |

The two bootstrap ledger rows name `dart-sdk-linux-x64.zip` `91dfc837...` (214945654 B, in the host-extras tar) and
`engine_stamp.json` `9020f215...` (239 B, in the cell tar); the gate 4 and 5 logs verified both by size and
SHA-256.

## Not done

- R12 arm B was not re-run, and the check that justified that for `2fc41d3f` does NOT hold here. Grepping the
  `packages/shorebird_cli/lib` diff from `d7e5325e` to `af1e14a1` (58 files) for prompt, `canAcceptUserInput`,
  confirmation, release-chooser and `--release-version` words finds changed lines: the native-diff check in the patch
  command no longer tests `canAcceptUserInput` or calls `logger.confirm` in the lines it replaced, a
  `PromptDeclinedExit` mapping is added to the run-failure reasons, and `inferredReleaseVersion` is threaded through
  the patch path. Arm A (the no-TTY patch, with and without `--json`, and the chooser refusal) passed on this CLI.
  TODO for the owner: decide whether arm B must be re-run for this cell.
- The iPhone run (above).
- `verify_supported_state.sh` is run against this branch before merge; its result is in the PR.
