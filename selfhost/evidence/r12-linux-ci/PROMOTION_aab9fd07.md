<!-- cspell:words installaab -->
# Cell aab9fd07 over engine d0714887: the frozen chain, run on ci-build

Date 2026-11-16. Chain: `selfhost/TOOLCHAIN_PROMOTION.md`, run as `PROMOTION_5f6efd98.md` was. This mints a
new cell address over the same engine `d0714887` (Dart `b4671ab7`). Only the Route B compiler archive changes:
three of its tools are rebuilt from main `0d7e6192` (PR #189). CLI commit under test:
`a443d87cded02537348bb204a08d99f074e7b1d4` (PR #190's head; its merge `dd93e875` has the same
`packages/shorebird_cli` and `bin/internal` trees).

    cell address       aab9fd07857142c232e4b5a41e41814b8dbf640f   macos-ios-android, 30 members
    flutter_revision   7def8a997dd87eaad43d88ddfa283ed9f4e1127b   shorebird-flutter: 0987ce0a + engine.version = aab9fd07 (one line)
    engine bytes       d0714887dd95d2990e0185fe1893523f3d600cc5   published members, byte for byte, except the compiler archive
    fallback           38855c84ca367c58165b8e3844dd7d6a99dec844   as d0714887's own experimental_hashes.map entry
    updater_revision   87c198d30f875a3da317d70935e1025dc13064dd   unchanged

Run in `/srv/ci-cache/shorebird-engine/promo-aab9` on ci-build, set up from the `5f6efd98` run's workspace:
the same scripts retargeted to this cell, `selfhost/ci` from `a443d87c`, and the ledgers taken fresh from main.

## Why a new cell over the same engine

PR #189 made the coverage analyzer v15. It takes `--carry` and reports `callers`: when an edited method
was inlined into other methods in the release, the patch has to replace those callers too, or they keep
running the release's copy. The v14 analyzer in `5f6efd98` cannot report them, and the CLI from PR #189
needs v15 to ship them. The release probe (inlining and held tear-offs) and the dynamic-interface
generator changed in the same PR. All three tools live in the compiler archive, which is a cell member,
so the change needs a new address.

## What was minted

The compiler archive is `5f6efd98`'s with three members replaced: `route_b_analyze.aot` (v15,
`a7c2663c...`), `route_b_release_probe.aot` and `route_b_gen_dynamic_interface.aot`, each built from
`0d7e6192`. The other six members are byte-identical. Archive `70f72462...`, 19810923 B.

Every other member comes from the published `d0714887` overlay. The members rendered to the address
(`engine_stamp.json`, the four POMs, `artifacts_manifest.yaml` against the 38855c84 base, and the
descriptor) are rendered as for `5f6efd98`. The product's own `v2_transaction` staged, addressed, rendered,
verified and published it: `CELL MEMBERS VERIFIED (30/30)`, `AUDIT CLEAN`, `COMPLETE`, and
`route-b-cell-v2 QUALIFIED`. The same 26 unaddressed host files ship as `host-extras-<address>.tar`.

The address depends on the time of the mint, because the archive's `PROVENANCE.txt` records the build time
and the zip stores member timestamps. Three trial mints that day produced three addresses. Each was
checked the same way, and `aab9fd07` is the one installed and recorded here.

Installed on ci-build by `installaab9.sh` (the owner ran it). It installed 57 files without overwriting,
extended the CDN protection lists (PR #190: Caddyfile, `check_protection_matchers.py`,
`experimental_hashes.map`), and ran `caddy validate` before the cdn-cache restart. 57 of 57 files are served
from the overlay and identical. `audit` is CLEAN for the cell (macos-ios, macos-ios-android), for
`5f6efd98` and for `d0714887` (all three).

## Gates

| # | Gate | Result | Evidence |
|---|---|---|---|
| 1 | candidate exists in the owned Flutter mirror | PASS: `7def8a99` at `refs/heads/selfhost/3.47-cell-aab9fd07` | `promotion-aab9fd07/guard_candidate.log` |
| 2 | exact `engine.version` | PASS: `aab9fd07857142c232e4b5a41e41814b8dbf640f` | same |
| 3 | SEALED + COLD bootstrap discovery | PASS, 0 additions | `promotion-aab9fd07/bootstrap_discovery.log` |
| 4 | bootstrap manifest banked | PASS: 2 rows (dart-sdk 214945654 B, sha `91dfc837...`; engine_stamp 239 B, sha `1fa4303a...`), manifest digest `e430e154...` | `bootstrap_closure.tsv`, `proxy_mapping.tsv` |
| 5 | `bootstrap_closure_guard.sh` | PASS: `CLOSURE OK`, 2 artifacts size + SHA-256 verified, proxy mapping pinned (`e430e154...` -> `89c39edf`) | `promotion-aab9fd07/guard_candidate.log` |
| 6 | fresh sealed cold bootstrap | PASS: bootstrap-only, fresh container, exit 0; `Flutter 3.46.0-1.0.pre-866`, `Shorebird Engine • revision aab9fd07...`. Sealed mirror: 7 requests, 5 overlay hits, 0 `/gcs/`, 0 non-overlay 200s; two 502s, both `GET /` (the harness's CA probe) | `promotion-aab9fd07/fresh_bootstrap_launch.log`, `boot1_access.txt`, `arms/arm-BOOT1` |
| 7 | sealed release/patch artifact discovery | PASS for the closure: 10 rows imported under `aab9fd07`, and the final iteration refused nothing. The discovery harness's own verdict was FAIL, which does not apply here, as in `PROMOTION_82fc78a8.md`: its control plane holds one release, so arm 3's chooser uses it. Arm 3 is decided by arm A | `release_patch_closure.tsv` (10 rows under `aab9fd07`), `promotion-aab9fd07/release_patch_discovery.log`, `rp_access.txt` |
| 8 | fresh Linux release/patch smoke | PASS: R12 arm A on gate 7's control plane, fresh container, fresh cold mirror: 40 requests, 38 overlay hits, 0 `/gcs/`, 0 refused (the two 502s are the harness's `GET /`); arm 3 refused the chooser by name, exit 64 | `promotion-aab9fd07/armA.log`, `armA_access.txt`, `arms/arm-A` |

The ten imports are the same ten stock files as in the `5f6efd98`, `82fc78a8` and `d12e29ec` runs (seven
`android-*/artifacts.zip` and three `android-*-profile/linux-x64.zip`), now under the `aab9fd07` client
path, with the same sizes and digests as the `5f6efd98` rows. They are stock engine bytes from the
fallback `38855c84`, not built from `d0714887`. The known gap stated in `compatibility.yaml` is unchanged.

## How the run went

- **Gate 6, first attempt:** `FAIL: control-plane unreachable from a container`. `launch.sh` checks that the
  control plane is reachable even for a bootstrap-only arm, which talks to no control plane. The chain
  starts the control plane at gate 7, so at gate 6 nothing was listening. The rerun started it before
  gate 6. PR #191 skips that check for bootstrap-only arms.
- **Gate 7, first attempt:** it imported the ten rows above. A watchdog I had put around the chain then
  stopped it, because the chain log had not grown for 15 minutes. That is normal during a discovery
  iteration. The rerun (no watchdog) found all ten already banked and closed on its first iteration, with
  nothing refused by the seal. The first attempt's iteration log was overwritten by the rerun's; the ten
  rows it imported are in `release_patch_closure.tsv`.
- **Gates 6 to 8 were rerun together** (`chain7.sh` on ci-build) after the gate 6 fix, so the evidence
  for 6, 7 and 8 comes from one run. CHAIN_DONE at 2026-11-16T06:43:07Z.

## Device run

Through the cell address on a physical iPhone 7 (iOS 15.8), 2026-11-16. The app has a local path package
and `intl`. Patch 1 had 18 ordinary edits and applied 16 of 16 targets on two launches. Patch 2 had 4 edits
and applied 3 of 3 on two launches. Two edits were refused before anything was uploaded: a changed
top-level `const` and a changed field initializer. Rolling back patch 2 returned the device to patch 1.
PASS. See `selfhost/engine/route_b/evidence/ios-cell-aab9fd07/RESULT.md`.

## Published

Not yet. The owner creates the tag `selfhost-flutter-cell-aab9fd07` on shorebird-flutter at `7def8a99` and
the release `cell-aab9fd07` on mml555/shorebird. Its assets, from the mint, are:

| File | SHA-256 |
|---|---|
| bundle `cell-aab9fd07....tar` (740839936 B) | `021144f5...` |
| `host-extras-aab9fd07....tar` (843897344 B) | `96f4c2fc...` |
| `LAYOUT.txt` | `275c2494...` |
| descriptor `cell_manifest.v2` | `aab9fd07...` |

The bootstrap ledger rows point at those two tars. They resolve only once the release exists.

## Not done

- R12 arm B was not re-run. Since the `5f6efd98` record's CLI (`d227ec00`), the only change to
  `packages/shorebird_cli/lib` is PR #189 (Route B coverage: carrying callers, reading v15, the
  instance-getter, super, compound-assignment and static-member fixes). Its `lib/` diff touches no
  prompt, `canAcceptUserInput`, confirmation, release chooser or `--release-version`.
- `verify_supported_state.sh` is run against this branch before merge; its result is in the PR.
