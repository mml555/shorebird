# iOS device run through cell 5f6efd98 (2026-11-16)

**Result: PASS.** Release, Route B patch and rollback on a physical iPhone 7
(iOS 15.8), with the toolchain found through the cell address
`5f6efd9826ae8fadc6ff66150cbcac8c7201140f`. The cell is minted over engine
`d0714887` (Dart `b4671ab7`), and its compiler archive carries PR #184's coverage
analyzer.

The first cell minted over `d0714887`, `fb12c60a`, failed this run before it was
recorded. At `shorebird release ios`, its v14 coverage analyzer crashed checking
the two release kernels against each other (`Reference to dart:core::Object is
not bound to an AST node`: the release dill's platform is not linked in), so the
release uploaded no kernel and `shorebird patch ios` refused the patch (exit 70,
"This release did not upload the kernel a patch has to be compiled against").
Here the same release step printed no such warning. PR #184 fixed the analyzer, and
`5f6efd98` differs from `fb12c60a` only in the compiler archive (and the members
rendered to the address). See `evidence/r12-linux-ci/PROMOTION_5f6efd98.md`.

## What ran

| | |
|---|---|
| CLI | mml555/shorebird `22f14441` (the merge of PR #185, which selects `5f6efd98`) |
| Flutter | mml555/shorebird-flutter `ef0eec1b` (`lineage.flutter_selector`); the bootstrap reported `Flutter 3.46.0-1.0.pre-866`, `Shorebird Engine • revision 5f6efd98…` |
| Engine | resolved to `5f6efd98` from the production cdn-cache on ci-build (`artifact_origin.jsonl`: 24 of 32 requests are under `…/5f6efd98…`; the other 8 are fonts, the Gradle wrapper and the iOS USB tools, all served from the overlay) |
| Descriptor | `GET download.shorebird.dev/shorebird/cell-manifests/5f6efd98….v2` → 200, 4141 bytes |
| Server | `code_push_server` from the same CLI checkout, on the LAN |
| App | `flutter create` app, marker `CELL5F6E-V1-RELEASE` (`release.sh`), version `1.0.0+31`, released with `shorebird release ios --no-codesign`, re-signed with `ios_resign.sh`, installed as an upgrade over the previous build of the same bundle id |

The only 404s were the four `aot-tools.dill` probes, which fall back to the
executable as designed.

## Launches (`*.log`, the app's `Runner(Flutter)` lines from the device syslog)

| Step | Marker | Updater |
|---|---|---|
| `boot_release` | V1-RELEASE | `release_version changed 1.0.0+30 -> 1.0.0+31, creating new state`; base release; check: no patch |
| `shorebird patch ios` | | `✅ Published Patch 1!` (`patch1_cli.txt`) |
| `p1_download` | V1-RELEASE | check: patch 1 available; downloaded 1105 bytes and applied |
| `p1_boot` | **V2-PATCH1** | `active patch is a Route B container`, `ROUTEB: activated markerText in package:cell5f6e/main.dart before main`, `applied 1/1 targets, entering main`, launch success |
| `p1_boot2` | **V2-PATCH1** | same; the patch persists across launches |
| `shorebird patches rollback --patch-number 1` | | `Patch 1 on release 1.0.0+31 has been rolled back.` (`rollback_cli.txt`) |
| `rb_learn` | V2-PATCH1 | boots the patch while it learns of the rollback |
| `rb_boot` | **V1-RELEASE** | base release, `no active patch`; check: `rolled_back_patch_numbers: Some([1])` |

`steps.sh` is the script that drove these steps.

## Outbound hosts (`outbound_connect.jsonl`, every CONNECT through the run's proxy)

- `pub.dev`: package resolution (129 connections).
- `github.com` with `git-remote-http` (5): the clone of mml555/shorebird-flutter, and
  the git dependency `shorebird_build_trace`, which `packages/flutter_tools/pubspec.yaml`
  at `ef0eec1b` still pins to `https://github.com/shorebirdtech/shorebird.git` at
  `cff436f6`. That is the open item from the `82fc78a8` run, unchanged.

No request went to `*.shorebird.dev`, `storage.googleapis.com` or any other
Shorebird-owned host. Bundletool was already in the CLI's cache, so it was not
downloaded this time.
