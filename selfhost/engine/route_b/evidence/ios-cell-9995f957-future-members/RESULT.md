# iOS device run through cell 9995f957 with #295 (2026-11-24)

**Result: with #295, patches that call `timeout`, `whenComplete` or `catchError` on a `Future` publish and run in an app that allocates `TickerFuture`.** The CLI is `a4f84392`, #295's first head. #295 makes an iOS release name `dart:async#Future.catchError`, `whenComplete` and `timeout`, as #291 does for `then`, and the kept check still asks the release snapshot for each. `f01` (`.timeout`), `f02` (`.whenComplete`) and `f03` (`.catchError`) each published with the check on, applied and showed its greeting on the iPhone. Rolling back `f03` brought back `f02`. No launch failed. No patch was built with `--allow-unchecked-sdk-calls`.

## Limits

- **No refusal was run on the old release.** That `1.0.0+77` (CLI `668ce3f0`) refuses these calls is shown by its snapshot profile (`profile_check.txt`), the question the check asks, not by a `shorebird patch` against it.
- **Patches were unsigned.** The release printed `[WARN] No patch public key was provided` (`release_cli.txt`).
- **One CLI, one device, one app.** CLI `a4f84392`, the iPhone 7, release `1.0.0+78`.
- **No screenshots.** Each boot ends on the `/detail` page, which these patches do not change. The device log lines below show the change.
- **Not an Android run.** #295 changes the iOS release and patch path only.

## What ran

| | |
|---|---|
| CLI | mml555/shorebird `a4f84392745f4c67cda5eb7181fb8b208c4c9663` (#295's first head), a detached worktree at `devrun/run-9995f957-kfm/cli`, `Shorebird 1.6.144+selfhost.1` (`bootstrap.log`) |
| Flutter | shorebird-flutter `8e996caeeba7d826cc27397660a996c1e6194d07`; `bootstrap.log` prints `Shorebird Engine • revision 9995f9571ec94b60eca64ec7eaae5fa190285b4d` |
| Cell | `9995f9571ec94b60eca64ec7eaae5fa190285b4d`: the descriptor was served 200, 4141 bytes (`up.out`) |
| Server | `code_push_server` from the same checkout, local, `10.0.0.242:18290`. 79 request lines, none 4xx or 5xx (`server_requests.log`) |
| App | the shapes app (`main.dart`, `variants.py` as in `ios-cell-9995f957-future-then`, plus `f01`-`f03`), version `1.0.0+78`, `shorebird release ios --no-codesign`, re-signed with `ios_resign.sh`, upgrade-installed over `1.0.0+77` (never uninstalled) |
| Release | `Route B retention: 61 named SDK members kept (default set only …)` (58 before #295), `verified 7169 patchable call sites` (`release_cli.txt`); Route B release hash `455aae0a1901982239a9ddaa716f6c46` (the `built-for` of the patched boots) |
| Device | iPhone 7, iOS 15.8.8 |
| Time | Mac clock 2026-11-24, first launch 16:54, last launch 17:05; `GO_DONE`, exit 0 for `up`, `release` and `stepsF` |

The harness in `harness/` is `ios-cell-9995f957-future-then`'s, with the run directory, the CLI, the version and the step script (`stepsF.sh`) changed. `collect.sh`'s leak check is fixed here: in earlier copies its quoting was broken, so it never ran. A leak check over this directory found no home path, key or secret.

## The patches

Each changes `loadGreeting`, the function that awaits `Future<void>.delayed(...)` and returns the greeting `G1`:

| Patch | Edit | Published | Boot after download | Shows |
|---|---|---|---|---|
| `f01` | `.timeout(const Duration(seconds: 5))` on the delayed `Future`; greeting `G5` | Patch 1 | `applied 1/1 targets`, `Launch success for patch 1` (`f01_boot.log`, `f01_boot2.log`) | `shape:greeting=G5`, `FB1 G5` |
| `f02` | `.whenComplete(() => log('when-complete', 'W1'))`; greeting `G6` | Patch 2 | `Launch success for patch 2` (`f02_boot.log`, `f02_boot2.log`) | `G6`, `shape:when-complete=W1` |
| `f03` | `.catchError((Object e) => log('catch-error', e))`; greeting `G7` | Patch 3 | `Launch success for patch 3` (`f03_boot.log`, `f03_boot2.log`) | `G7` |
| rollback of 3 | `shorebird patches rollback` | | `rb_learn` still on 3, then `rb_boot`, `rb_boot2` on patch 2 | `G6`, `W1` |

The release's own boots (`boot_release.log`, `boot_release2.log`) show `no active patch` and `G1`.

## Does the release keep them? (`profile_check.txt`)

`harness/future_then_profile_check.dart` (from `ios-cell-9995f957-future-then`) asks each release's `route_b_snapshot_profile.json`, with the CLI's own `RouteBSnapshotKept`: does every `Future` subtype the release allocates, other than `_Future`, have the member compiled?

| Release | CLI | `then` | `catchError` | `whenComplete` | `timeout` |
|---|---|---|---|---|---|
| `1.0.0+77` (`ios-cell-9995f957-future-then`) | `668ce3f0` | yes | refused: no `catchError` on `TickerFuture`, and 1 more | refused | refused |
| `1.0.0+78` (this run) | `a4f84392` | yes | yes | yes | yes |

The "1 more" is `SynchronousFuture`, the other `Future` subtype in `package:flutter`.

Size (`release_comparison.txt`): the snapshot profile's total `self_size` is 4,092,976 B for `1.0.0+77` and 4,097,392 B for `1.0.0+78`, +4,416 B (+0.108 %). The archived `App.framework/App` is 3,913,680 B in both. The same app, cell and Flutter built both. The profiles (9 MB each) are not kept here.
