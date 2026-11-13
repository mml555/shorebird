<!-- cspell:words dartvm -->

# iOS device run through cell 82fc78a8 (2026-11-12)

**Result: PASS.** Release, Route B patch and rollback on a physical iPhone 7
(iOS 15.8.8), on a clean install, with the toolchain found through the cell
address `82fc78a817ce8290b108cea4dec1ee58317e9a9c`. This is the precondition
that `SUPPORTED_STATE.yaml` set for the tag `selfhost-v1.2.0`.

## What ran

| | |
|---|---|
| CLI | mml555/shorebird `357bc24f` (PR #146 head before the main merge) |
| Flutter | mml555/shorebird-flutter `f6bbc8a0` (`lineage.flutter_selector`), cold bootstrap into a fresh checkout |
| Engine | resolved to `82fc78a8` from the production cdn-cache on ci-build (`artifact_origin.jsonl`: every engine path is under `flutter_infra_release/flutter/82fc78a8…` or `download.shorebird.dev/shorebird/82fc78a8…`, `x_engine_hash: 82fc78a8…`) |
| Descriptor | `GET download.shorebird.dev/shorebird/cell-manifests/82fc78a8….v2` → 200, 4141 bytes, served by the cdn-cache (`artifact_origin.jsonl`) |
| Server | `code_push_server` from the same CLI checkout, on the LAN |
| App | `flutter create` app, marker `CELL82FC-V1-RELEASE` (`release.sh`), released with `shorebird release ios --no-codesign`, re-signed with `ios_resign.sh`, installed fresh |

The only 404s were the two `aot-tools.dill` probes, which fall back to the
executable as designed.

## Launches (`*.log`, the app's `Runner(Flutter)` lines from the device syslog)

| Step | Marker | Updater |
|---|---|---|
| `boot_release` | V1-RELEASE | no state file, so new state; base release; check: no patch |
| `shorebird patch ios` | | `✅ Published Patch 1!` (`patch1_cli.txt`) |
| `p1_download` | V1-RELEASE | check: patch 1 available; downloaded 1105 bytes and applied (`dlc.vmcode`) |
| `p1_boot` | **V2-PATCH1** | `active patch is a Route B container`, `ROUTEB: applied 1/1 targets, entering main`, launch success for patch 1 |
| `p1_boot2` | **V2-PATCH1** | same; the patch persists across launches |
| `shorebird patches rollback --patch-number 1` | | `Patch 1 on release 1.0.0+1 has been rolled back.` (`rollback_cli.txt`) |
| `rb_learn` | V2-PATCH1 | boots the patch while it learns of the rollback (same as the Android scenario) |
| `rb_boot` | **V1-RELEASE** | base release; check: `rolled_back_patch_numbers: Some([1])` |

`steps.sh` is the script that drove these steps.

## Outbound hosts (`outbound_connect.jsonl`, every CONNECT through the run's proxy)

- `pub.dev`: package resolution.
- `github.com` with `git-remote-http`: the clone of mml555/shorebird-flutter, **and the
  git dependency `shorebird_build_trace` that shorebird-flutter's
  `packages/flutter_tools/pubspec.yaml` pins to
  `https://github.com/shorebirdtech/shorebird.git` at `cff436f6`.** That fetch reaches
  upstream's repository. The same commit is in mml555/shorebird, so pointing the URL at
  the fork removes it. That change moves the Flutter selector, so it is recorded here
  as an open item, not fixed in this run.
- `github.com` and `release-assets.githubusercontent.com` from `dartvm`: the CLI
  downloading `google/bundletool` 1.18.3 (Google's Android tool, used by the CLI's cache).

No request went to `*.shorebird.dev`, `storage.googleapis.com` or any other
Shorebird-owned host.
