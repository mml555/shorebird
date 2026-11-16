# Cell 2fc41d3f over engine d0714887: the frozen chain, run on ci-build

Date 2026-11-16. Chain: `selfhost/TOOLCHAIN_PROMOTION.md`, run as `PROMOTION_aab9fd07.md` was. This mints a
new cell address over the same engine `d0714887` (Dart `b4671ab7`). Only one member of the Route B compiler
archive changes: `route_b_analyze.aot`, rebuilt from main `806db5d4` (the merge of PR #194). CLI commit under
test: `d7e5325eba1a96a4791fe774a6badb2404d6029a` (PR #195's head; its merge `f9c56698` has the same
`packages/shorebird_cli` and `bin/internal` trees, checked with `git diff --quiet d7e5325e f9c56698 -- packages/shorebird_cli bin/internal`).

    cell address       2fc41d3fbd9966958ba3ccf2be9761e064e92bcc   macos-ios-android, 30 members
    flutter_revision   5c60356ca635c74696ab737e2d5e77f04d615057   shorebird-flutter: 0987ce0a + engine.version = 2fc41d3f (one line)
    engine bytes       d0714887dd95d2990e0185fe1893523f3d600cc5   published members, byte for byte, except the compiler archive
    fallback           38855c84ca367c58165b8e3844dd7d6a99dec844   as d0714887's own experimental_hashes.map entry
    updater_revision   87c198d30f875a3da317d70935e1025dc13064dd   unchanged

Run in `/srv/ci-cache/shorebird-engine/promo-2fc4` on ci-build with `R12_REPO_SHA=d7e5325e`, from 22:04:37Z to
`CHAIN_DONE` 22:52:11Z, in one uninterrupted run: gates 1 to 8 ran once each, with no reruns.

## Why a new cell over the same engine

PR #193 and PR #194 made the coverage analyzer v16 and v17. From v16 a patch may add a top-level function or
getter (public or private) when everything that calls it is part of the patch; from v17 it may also add a
private instance method of an existing class (lowered with the receiver as its first argument). The v15 analyzer in `aab9fd07` lists every
new member as a rejection, and the CLI from #193 and #194 needs v17 to ship them. The analyzer lives in the
compiler archive, which is a cell member, so the change needs a new address.

## What was minted

`mint4.sh` (log `mint4.log`) took `aab9fd07`'s files and replaced one archive member. The archive is
`aab9fd07`'s with `route_b_analyze.aot` rebuilt from `806db5d4` (analysis version 17, `c3898f45...`, was
`a7c2663c...`). Seven of the archive's nine members are byte-identical to `aab9fd07`'s, including the release
probe and the dynamic-interface generator (their sources are unchanged since `0d7e6192`); `PROVENANCE.txt`
differs, because it records the new build time and the analyzer's digest. Archive `768ad4b8...`, 19835885 B
(was `70f72462...`, 19810923 B).

The 49 other files from the published `d0714887` overlay are identical to `aab9fd07`'s shipped copies. Seven
members are rendered to the address: `engine_stamp.json`, the four POMs, `artifacts_manifest.yaml` and the
descriptor. The first six are identical to `aab9fd07`'s once both addresses are normalized; the descriptor
differs, as it names the address and the new compiler archive. The product's own `v2_transaction` staged, addressed,
rendered, verified and published it: `CELL MEMBERS VERIFIED`, `AUDIT CLEAN`, `COMPLETE`, and
`route-b-cell-v2 QUALIFIED`. The same 26 unaddressed host files ship as `host-extras-<address>.tar`.

The address depends on the time of the mint, because the archive's `PROVENANCE.txt` records the build time
and the zip stores member timestamps.

Installed on ci-build by `install2fc4.sh` (the owner ran it). It installed 57 files: 49 identical to
`d0714887`'s, 7 rendered, 1 compiler archive. `MATCHER COVERAGE OK`, `caddy validate` passed before the
cdn-cache restart (PR #195: Caddyfile, `check_protection_matchers.py`, `experimental_hashes.map`). 57 of 57
files are served from the overlay and identical, 0 differ. `audit` is CLEAN for the cell (`2fc41d3f`), for
`aab9fd07` (macos-ios and macos-ios-android) and for `d0714887` (all three).

## Gates

| # | Gate | Result | Evidence |
|---|---|---|---|
| 1 | candidate exists in the owned Flutter mirror | PASS: `5c60356c` at `refs/heads/selfhost/3.47-cell-2fc41d3f` | `promotion-2fc41d3f/guard_candidate.log` |
| 2 | exact `engine.version` | PASS: `2fc41d3fbd9966958ba3ccf2be9761e064e92bcc` | same |
| 3 | SEALED + COLD bootstrap discovery | PASS: `BOOTSTRAP COMPLETED under seal after 0 additions` | `promotion-2fc41d3f/bootstrap_discovery.log` |
| 4 | bootstrap manifest banked | PASS: 2 rows (dart-sdk 214945654 B, sha `91dfc837...`; engine_stamp 239 B, sha `8cdabc19...`), manifest digest `a1972ce6...` | `bootstrap_closure.tsv`, `proxy_mapping.tsv` |
| 5 | `bootstrap_closure_guard.sh` | PASS: `CLOSURE OK 5c60356c -> 2fc41d3f`, 2 artifacts size + SHA-256 verified, proxy mapping pinned (`a1972ce6...` -> `89c39edf`) | `promotion-2fc41d3f/guard_candidate.log` |
| 6 | fresh sealed cold bootstrap | PASS: bootstrap-only arm BOOT1, fresh container, exit 0; `Flutter 3.46.0-1.0.pre-866`, `Shorebird Engine • revision 2fc41d3f...`. Sealed mirror: 7 requests, 5 overlay hits, 0 `/gcs/`, 0 non-overlay 200s; the two 502s are both `GET /` (the harness's probe) | `promotion-2fc41d3f/fresh_bootstrap_launch.log`, `boot1_access.txt`, `arms/arm-BOOT1` |
| 7 | sealed release/patch artifact discovery | PASS for the closure: 11 iterations, 10 rows imported under `2fc41d3f` (one per iteration for the first ten), and the last iteration refused nothing (`STOP — harness failed with NOTHING refused by the seal`). The discovery harness's own verdict was FAIL, which does not apply here, as in `PROMOTION_aab9fd07.md`: its control plane holds one release, so arm 3's chooser uses it. Arm 3 is decided by arm A. `rp_access.txt` has 109 requests because it covers all 11 iterations: 40 of them are 20 overlay paths answered 302 to `/gcs/` and the 20 `/gcs/` fetches that followed, which the seal answered 502 while discovering; none returned 200 outside the overlay | `release_patch_closure.tsv` (10 rows under `2fc41d3f`), `promotion-2fc41d3f/release_patch_discovery.log`, `rp_access.txt` |
| 8 | fresh Linux release/patch smoke | PASS: R12 arm A on gate 7's control plane, fresh container, fresh cold mirror, exit 0: 40 requests, 38 overlay hits, 0 `/gcs/`, 0 non-overlay 200s (the two 502s are the harness's `GET /`); arm 3 refused the chooser by name, exit 64 | `promotion-2fc41d3f/armA.log`, `armA_access.txt`, `arms/arm-A` |

The ten imports are the same ten stock files as in the `aab9fd07`, `5f6efd98` and `82fc78a8` runs (seven
`android-*/artifacts.zip` and three `android-*-profile/linux-x64.zip`), now under the `2fc41d3f` client
path. Their sizes and SHA-256 digests equal the `aab9fd07` rows' (compared row by row, 10 of 10). They are
stock engine bytes from the fallback `38855c84` (one, `android-x86/artifacts.zip`, from Flutter's own
`89c39edf`), not built from `d0714887`. The known gap stated in `compatibility.yaml` is unchanged.

## How the run went

One uninterrupted run, no reruns and no watchdog stops. PR #191 (skip the control-plane reachability check for
bootstrap-only arms) meant gate 6 needed no control plane, which was the cause of `aab9fd07`'s first gate 6
failure. The ledger files in this PR are the chain's own copies, and each only gained rows.

## Device run

Through the cell address on a physical iPhone 7 (iOS 15.8.8), 2026-11-16, release `1.0.0+33` of the
`aab9fd07` test app. The `aab9fd07` sequence was repeated: patch 1 (18 edits) applied 16 of 16 targets and
patch 2 (4 edits) 3 of 3, each on two launches; a changed top-level `const` and a changed field initializer
were refused before upload (exit 70); rolling back patch 2 returned the device to patch 1. This time p29's
effect was seen on screen. Then the two features this cell adds: a private top-level function (patch 3, 2/2), a
private instance method (patch 4, 2/2) and a private method that calls an existing one and writes a field
(patch 5, 1/1), each showing its new values on two launches; a new public method and a private-name collision
were refused before upload (exit 70); rolling back patch 5 returned the device to patch 4. PASS. See
`selfhost/engine/route_b/evidence/ios-cell-2fc41d3f/RESULT.md`.

## What a patch can add now, and what is still refused

Added by this cell: a new top-level function or getter, public or private (v16), accepted when every caller is
in the patch, and refused when something outside the patch calls it; and a new private instance method of an
existing class (v17, conditions in `ROUTE_B.md`). Only a new instance method has to be private. Still refused,
before upload: a public new instance method (code outside the library can call it by name), a private name
that another member of its library already uses, a new class, a new field, and the other shapes `PARITY.md`
lists as refused. The `aab9fd07` cell refuses every new member. The device run covered the private forms only:
a public top-level function (the `p28` shape) was not run on the device.

## Published

The owner created both on 2026-11-16. The tag `selfhost-flutter-cell-2fc41d3f` on shorebird-flutter is
annotated (tag object `c49018d4`) and points at `5c60356c`. The release `cell-2fc41d3f` on mml555/shorebird
targets `f9c56698` and is not marked latest. GitHub's digest of each of its six files matches this record:

| File | SHA-256 |
|---|---|
| bundle `cell-2fc41d3f....tar` (740864512 B) | `2626334b...` |
| `host-extras-2fc41d3f....tar` (843897344 B) | `1455a371...` |
| descriptor `cell_manifest.v2` (4141 B) | `2fc41d3f...a9b72f5c...` |
| `LAYOUT.txt` (5993 B) | `6b1ad1d9...` |
| `CELL.txt` (386 B) | `08e0f6c9...` |
| `MANIFEST.sha256` (276 B) | `a9aef6ce...` |

Both bootstrap ledger URLs return 200, and the members they name hash to the rows' SHA-256 and sizes:
`dart-sdk-linux-x64.zip` `91dfc837...` (214945654 B, from the host-extras tar) and `engine_stamp.json`
`8cdabc19...` (239 B, from the cell tar).

## Not done

- R12 arm B was not re-run. Since `aab9fd07`'s CLI (`a443d87c`), the changes to `packages/shorebird_cli/lib`
  are Route B coverage work (PRs #193 and #194); none touches a prompt, `canAcceptUserInput`, a confirmation,
  the release chooser or `--release-version` (checked by grepping the `lib/` diff from `a443d87c` to `d7e5325e`
  for those words: no changed line mentions them).
- Not exercised on a device: a tap-driven call of an added method, an added method on a class other than
  `State`, a public top-level function (the `p28` shape), an obfuscated release.
- `verify_supported_state.sh` is run against this branch before merge; its result is in the PR.
