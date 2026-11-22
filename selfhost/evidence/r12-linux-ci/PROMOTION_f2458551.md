<!-- cspell:words ARMB dbbdd -->
# Cell f2458551 over engine 09c6f422 (Flutter 3.50): the promotion chain, run once on ci-build

Date 2026-11-22 (UTC throughout). Chain: `selfhost/TOOLCHAIN_PROMOTION.md`, run as `PROMOTION_a377ecb7.md` was, but **once, with no resume**,
in `/srv/ci-cache/shorebird-engine/promo-f2458551` on ci-build (cloned from `promo-a377ecb7`, with an empty ledger). The engine is `09c6f4225d3ddf276fe4f3473beca79e038360b6`
(shorebird-flutter branch `selfhost/3.50-up`, commit "DEPS: updater from the Route B mirror, mirror #10 and #11 on 91dbbdd (64a458f)", release
`engine-09c6f422...` on `mml555/shorebird-flutter`, in parts). Its parent `b5333482` is a CI-only commit whose parent is `e737ede3`, the engine of `a377ecb7`, so the engine
source equals `e737ede3`'s except `DEPS` `updater_rev`, which is `64a458f034c86bca2eff6541a19d73781728b18f`: `mml555/shorebird-updater-mirror` branch `route-b-91dbbdd` after mirror PR #14
(a merge of `a58774ab` and `32676dc0` whose tree equals `32676dc0`'s; `32676dc0` carries mirror #10 and #11: bounded diag logs, and a proxy refusing CONNECT is a transport error in the ureq builds).
Dart `0cd04a7717f20d5f9ae64014cb2239a3f961f895` and the fallback engine `f0a7d29193ea6e077e02080a3511b405a4401b6f` did not move. It replaces `a377ecb7`.

    cell address       f2458551039ceb1a48a2ffb4a41dff35950fec5b   route-b-cell-v2, macos-ios-android, 30 members
    flutter_revision   8f54cc7bc78915802fb29fa1d7b8b88fbd2d4974   shorebird-flutter: parent is the engine commit 09c6f422 itself; delta = bin/internal/engine.version only
    engine bytes       09c6f4225d3ddf276fe4f3473beca79e038360b6   published members, byte for byte, except the seven rendered to the address
    fallback           f0a7d29193ea6e077e02080a3511b405a4401b6f
    dart               0cd04a7717f20d5f9ae64014cb2239a3f961f895
    compiler archive   1edabab1b56f6d139ffe62a179b36a1bca2cb12c6a82ad09c93539e101639dc2   19938491 B; route_b_analyze.aot 7fde93ed3a2954b3ec824a2b145cb72f42c809ee3c70745af3f82258a0de1a3e
    updater_revision   64a458f034c86bca2eff6541a19d73781728b18f   DEPS updater_rev at the engine (was a58774ab8a88); restamped in compatibility.yaml and the record

The selector `8f54cc7b` (branch `selfhost/3.50-cell-f2458551`, tag `selfhost-flutter-cell-f2458551`, annotated tag object `7c177155`, tagged 2026-11-22T18:47:40Z, tree `43b4c83d`;
all read with `git ls-remote` and `gh api`) has the engine commit as its parent; the delta is `bin/internal/engine.version` alone. It is selected by PR #270 (merge `c212f715`),
which also adds `'09c6f422'` and `'f2458551'` (both mapping to `'0cd04a77'`) to `DartSdkCompatibility`.

CLI under test: `R12_REPO_SHA=dfdc86cce47929435609caf680d7adb849604ae2`, the head of #270. The record's `cli_revision` is `c212f715711d00c4b82261bc093f927d82b7cba9`, the merge. The two have
the same `packages/shorebird_cli` tree (`368f4a2e`) and the same `bin/internal` tree (`b891c868`) (`git rev-parse <rev>:<path>` on both), so the pin is the CLI the chain ran. `cli_version`
is `1.6.144+selfhost.1`, the pubspec version at the merge. The previous pin's trees were `e8cc324c` and `7eab49a5`.

## What was minted

The release `cell-f2458551` on `mml555/shorebird` (`gh release view cell-f2458551`: `createdAt` 2026-11-22T18:46:28Z, `publishedAt` 2026-11-22T18:56:46Z, targets `55d08ce0`, the select commit of #270; not a
prerelease). It was repacked on 2026-11-22 (the cell tar and the host extras were re-uploaded at 19:10Z and 19:11Z). Sizes and digests are GitHub's asset digests.

| Asset | Bytes | SHA-256 |
|---|---|---|
| `cell-f2458551....tar` (the 30 addressed members) | 750381568 | `38d7139a9fb3d73e8757cea1d1020753b6b69c825d017ef67ee5f3c9813c5b0e` |
| `host-extras-f2458551....tar` (the same 26 host files as `a377ecb7`'s, additive) | 848962560 | `c7e1dd98049b0998ad32399922c6351be23b261bf2e6a1a14fc54a233242db97` |
| `cell_manifest.v2` (the descriptor; also in-tree at `selfhost/engine/route_b/cell_manifests/f2458551....v2`) | 4141 | `f2458551039ceb1a48a2ffb4a41dff35950fec5b67d552148917080454b69c4c` |
| `LAYOUT.txt` | 5993 | `427f6cbe92fff9cd8be18c7f03c5163e2a6da680cf17ea9b682092ff1723d2cf` |
| `CELL.txt`, `MANIFEST.sha256`, `PARTS.sha256`, `files.sha256` | | |
| the full 100-file overlay: `.tar.part-aa` | 1992294400 | `d5754d30efc52097bd98efaf05aaa0012453bc0ca46753f1cfbf825466bf3e06` |
| `.tar.part-ab` | 1258637824 | `4dde6a026a7699fe5a002299d6c371b799bc7da01512f3961c62f2a5a8e4d020` |
| the parts joined | | `6cd1a964922e91b750ed0d304904c62efbc49f5f1bee8408a2d997001fb54035`: the first line of the mint's `MANIFEST.sha256` (the digest of the mint's 100-file tar); not recomputed from the downloaded parts |

The repacked release was hydrated on the Mac with `sd1_hydrate_cell.sh`: `CELL HYDRATED FROM THE DURABLE DISTRIBUTION`, 30 of 30 members, 26 host extras.
The mint is `~/Developer/shorebird-wt/tmp/f350/mint350b` (not in the repository); the compiler archive's digest, size and `route_b_analyze.aot` digest above were read from its `out/`
(the archive's `PROVENANCE.txt` names engine `09c6f422`, Dart `0cd04a77`, built 2026-11-22T18:29:30Z).

## Gates

Chain `chain.log`: 19:52:55Z to `CHAIN_DONE` 20:20:45Z. Arm B: 20:31:47Z to `ARMB_DONE` 20:41:44Z. Evidence is in [`promotion-f2458551/`](promotion-f2458551/).

| # | Gate | Result | Evidence |
|---|---|---|---|
| 1 | candidate exists in the owned Flutter mirror | PASS: `8f54cc7b` served at `refs/heads/selfhost/3.50-cell-f2458551` | `chain.log`, `guard_candidate.log` |
| 2 | exact `engine.version` | PASS: `f2458551039ceb1a48a2ffb4a41dff35950fec5b`, served `X-Overlay: hit` | same |
| 3 | SEALED + COLD bootstrap discovery | PASS: `BOOTSTRAP COMPLETED under seal after 0 additions` (cloned at `dfdc86cc`) | `bootstrap_discovery.log` |
| 4 | bootstrap manifest banked | PASS: 2 rows (`dart-sdk-linux-x64.zip` 227469081 B, sha `8f3d92e1...`; `engine_stamp.json` 246 B, sha `8676bfe5...`), proxy mapping `c336d698...` -> `371f7720` | `bootstrap_closure.tsv`, `proxy_mapping.tsv` |
| 5 | `bootstrap_closure_guard.sh` | PASS: `CLOSURE OK 8f54cc7b -> f2458551`, **2 artifacts, size + sha256 verified: 2 of 2 ledger rows** (the Dart SDK zip and `engine_stamp.json` each print their own `ok` line), proxy mapping pinned. This chain includes #266's fix (every ledger row checked) | `guard_candidate.log` |
| 6 | fresh sealed cold bootstrap | PASS: arm BOOT1, exit 0; `Flutter 3.50.1-0.0.pre-254`, Dart 3.14.0. Sealed mirror: 7 requests, 5 overlay hits, 0 `/gcs/`, 0 non-overlay 200s; the two 502s are both `GET /` (the harness's probe) | `arms/arm-BOOT1`, `boot1_access.txt`, `fresh_bootstrap_launch.log` |
| 7 | sealed release/patch artifact discovery | arms 1 and 2 exit 0; the harness's verdict is FAIL on one check, `arm 3 exited 0, expected 64` (the discovery control plane has one release, so the chooser is never reached; the designed outcome for this step, as in the `a377ecb7` and `54117a2f` records). Its check lines are the same as `a377ecb7`'s apart from hashes and times. 36 requests, 35 overlay hits, 0 `/gcs/`, the one 502 is `GET /` | `release_patch_discovery.log`, `rp_access.txt` |
| 8 | fresh Linux release/patch smoke | PASS: R12 arm A, fresh container, fresh cold mirror, exit 0, 20:11:08Z to 20:20:21Z: fixture `1.0.0+1`; 39 requests, 37 overlay hits, 0 `/gcs/`, 0 non-overlay 200s (two 502s are the harness's `GET /`); arm 3 refused the chooser by name, exit 64 | `armA.log`, `armA_access.txt`, `arms/arm-A` |
| 8b | R12 arm B (`bin/armB_go.sh`) | PASS: fixture `1.0.1+1` on arm A's control plane (`releases_before.log` lists `0.8.1+1` and `1.0.0+1`), fresh container, fresh cold mirror, exit 0: detector self-tests exit 64/64, release and patch published, `--json` patch 0 prompt hits, arm 3 refused the chooser by name (exit 64). 39 requests, 37 overlay hits, 0 `/gcs/`, 0 non-overlay 200s (two 502s are `GET /`) | `armB.log`, `armB_access.txt`, `arms/arm-B` |

(The request counts are the access logs' `handled request` lines, counted by `status`, the `X-Overlay: hit` response header and the `/gcs/` URI prefix, as `PROMOTION_a377ecb7.md` counted them.)
Bootstrap discovery added 0 closure rows. Step 4's `grep: ... No such file or directory` in `chain.log` is the harmless pre-append check on a ledger that does not exist yet, as in earlier chains.

## Engine updater evidence guard

`bash selfhost/ci/engine_updater_evidence_guard.sh --require-engine`, run once against the E2 engine tree (`~/shorebird-engine/flutter-350`, `src/flutter` at `09c6f422`) after
`compatibility.yaml` was updated, no build: all six checks pass, exit 0. Check 1 (the vendored `VENDOR.md` revision is `64a458f034c8`), the vendor-side checks 2 and 3, check 4 (`DEPS` `updater_rev` is
`64a458f034c86bca2eff6541a19d73781728b18f`) and the engine-side checks 2, 3, 5 and 6 each print `ok`. Output: [`promotion-f2458551/engine_updater_evidence_guard.txt`](promotion-f2458551/engine_updater_evidence_guard.txt).
(Before the record's `engine_revision` and `updater_revision` moved, the same command failed check 4 against `a58774ab8a88`, as it should.) `tool/check_updater_pin.sh` also passes.
The `a58774ab` launch and retention behaviour (#453, #454, #455) was not re-read for this record, beyond what the guard's checks follow.

## Vendored updater

`vendor/updater` was compared with `~/shorebird-engine/flutter-350/engine/src/flutter/third_party/updater` at `64a458f0` with `diff -rq` on 2026-11-22. The differences are the known ones: the fork-local edit in
`library_test_hooks/src/lib.rs`, CRLF line endings in `library/.cargo/config.toml`, the unvendored `shorebird_code_push/coverage_badge.svg`, and `.github/` (upstream's at the base commit, by design:
`VENDOR.md`). One more difference was found and fixed in this PR: `SELFHOST_PORT_91dbbdd.md` lacked the "Mirror #10 and #11" section, which is copied from the engine tree. `VENDOR.md` now names `64a458f0` as the source revision.

## Device run

Run on 2026-11-22 (later than this record's chain): an iPhone 7 release and Route B patch run through this cell, unsigned patches only, with limits ([`ios-cell-f2458551`](../../engine/route_b/evidence/ios-cell-f2458551/RESULT.md): iPhone 7, iOS 15.8.8, 12 published, 9 refused, 3 rollbacks, no launch failed). The earlier device-qualified cell is `a377ecb7`
([`ios-cell-a377ecb7`](../../engine/route_b/evidence/ios-cell-a377ecb7/RESULT.md)). This cell is over a different engine commit
(the updater differs), and no device evidence of `a377ecb7` is claimed for it (the run above is this cell's own). No Android device applied a patch on this cell: the chain shows an Android release and patch built and published under seal
with the CLI arms passing; the harness itself frames that as "NOT self-certifying" (`armA.log:147-151`).

## Not done

- Signed-patch device run, and the on-device `state_diag.log` of the iPhone run (not read).
- `selfhost/engine/route_b/verify_supported_state.sh` ran after the iPhone run (`VERIFY_f2458551.txt`): it failed one check on the record as #271 merged it (`cli_revision` still named 64a64473, which selects a377ecb7), and passed once #273 set it to `c212f715`.
- Port the post-step-7 failure check (`arm 1 release FAILED|arm 2 FAILED`) from the `a377ecb7` resume script into `selfhost/ci`. In this run arms 1 and 2 exited 0, read from the log, not enforced by the chain.
- shorebird-flutter's `selfhost-engine-mirror` action downloads a single `overlay-<engine>.tar`, but this engine's overlay is released in parts, so shorebird-flutter CI on a commit whose `engine.version` is `09c6f422` (or `e737ede3`)
  cannot fetch it (read on `selfhost/3.50-up` on 2026-11-22). The fix is a push to shorebird-flutter and is pending.
- The analyzer's analysis version for this archive was not read out; the record names the archive and `route_b_analyze.aot` by digest.
- The launch and retention behaviour of the updater (#453-#455) was not re-read for `64a458f0`.
- `PolicyEpoch.b` gains `64a458f034c8` in a separate commit of this PR (`packages/code_push_server/lib/src/repository.dart`); until that merges, measurement mode does not count 3.50 clients on this engine.

Resolved by this cell, and so dropped from `a377ecb7`'s list: the closure guard's skipped first ledger row (2 of 2 rows verified here, #266); the 3.50.0 tag (the owner pushed it:
`git ls-remote --tags https://github.com/mml555/shorebird-flutter.git 3.50.0` prints `ab2912035e160d9cad6306df307576da6128ebdb refs/tags/3.50.0`, and the cold bootstrap reports `Flutter 3.50.1-0.0.pre-254`);
`vendor/updater` and the engine updater evidence guard's engine-side checks (above).
