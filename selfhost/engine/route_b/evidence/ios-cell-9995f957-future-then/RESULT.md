# iOS device run through cell 9995f957 with #291 (2026-11-23)

**Result: with #291, the `await` edits that `ios-cell-9995f957` refused publish and run.** The CLI is `668ce3f0`, the merge of #291. #291 makes an iOS release name `dart:async#Future.then`, and the kept check still asks the release snapshot for it. `p06`, `p07` and `p08` each published, applied and showed its change on the iPhone. So did the trio that carries the `async` `_start`. `p05` published, ran and rolled back. The #254 patch (`t254`) is still refused before upload, now for one reason: it uses the constructor `TickerFuture.complete`, which the release never uses. The `then` reason is gone. No launch failed. No patch was built with `--allow-unchecked-sdk-calls`.

This run moves cell `9995f957` to **iPhone-run for `await` patches with CLI `668ce3f0`**, with the limits below.

## Limits

- **`p05_boot`'s device log lost its first lines.** The capture starts at the patch check. Its `applied`, `init` and `Launch success` lines are missing; the cause is not known. The screenshot kept for it shows the app running. The next launch, `p05_boot2`, shows `applied 1/1 targets`, `current_patch_number: Some(5)`, `init=I2` and `Launch success for patch 5`, and so does `rb_learn`. The run of the same step on release `1.0.0+76` (not kept here; its counts are in `release_comparison.txt`) captured all three lines.
- **`catchError`, `whenComplete` and `timeout` on a `TickerFuture` are still refused.** #291 names `then` alone (`future_then_profile_check.txt`).
- **Patches were unsigned.** The release printed `[WARN] No patch public key was provided` (`release_cli.txt`).
- **One CLI, one device, one app.** CLI `668ce3f0`, the iPhone 7, release `1.0.0+77`.
- **Not an Android run.** #291 changes the iOS release and patch path only.

## What ran

| | |
|---|---|
| CLI | mml555/shorebird `668ce3f0a68136e0192a55159fa75b2eb618e2d4` (the merge of #291), a detached worktree at `devrun/run-9995f957-668c/cli`, `Shorebird 1.6.144+selfhost.1` (`bootstrap.log`) |
| Flutter | shorebird-flutter `8e996caeeba7d826cc27397660a996c1e6194d07`; `bootstrap.log` prints `Shorebird Engine • revision 9995f9571ec94b60eca64ec7eaae5fa190285b4d` |
| Cell | `9995f9571ec94b60eca64ec7eaae5fa190285b4d`: the descriptor was served 200, 4141 bytes (`artifact_origin.jsonl`, `up.out`) |
| Server | `code_push_server` from the same checkout, local, `10.0.0.242:18290`. 116 request lines, none 4xx or 5xx (`server_requests.log`) |
| App | the shapes app (`main.dart`, `variants.py` as in `ios-cell-9995f957`), version `1.0.0+77`, `shorebird release ios --no-codesign`, re-signed with `ios_resign.sh`, upgrade-installed over `1.0.0+76` (never uninstalled) |
| Release | `Route B retention: 58 named SDK members kept (default set only …)` (57 before #291), `verified 7159 patchable call sites` (`release_cli.txt`); Route B release hash `bc4bade7cf64377ad4e9cd501f6ab450` (the `built-for` of the patched boots) |
| Device | iPhone 7, iOS 15.8.8 |
| Time | Mac clock 2026-11-23, install log written 22:59, last launch 23:16; `GO_DONE`, exit 0 for `up`, `release` and `steps254` |

The harness in `harness/` is `ios-cell-9995f957`'s, with the run directory, the CLI and the version changed.

## Does the release keep `then`? (`future_then_profile_check.txt`)

`harness/future_then_profile_check.dart` asks each release's `route_b_snapshot_profile.json` what `RouteBRetention.awaitUnchecked` asks: does every `Future` subtype the release allocates, other than `_Future`, have a compiled `then`? It uses the CLI's own `RouteBSnapshotKept` at `037e2975`, whose `packages/shorebird_cli` tree is `668ce3f0`'s.

| Release | CLI | `then` | `catchError`, `whenComplete`, `timeout` |
|---|---|---|---|
| `1.0.0+75` (`ios-cell-9995f957`) | `2f0b38a6` | refused: no `then` on `TickerFuture`, and 1 more | refused |
| `1.0.0+76` | `3bd6eed5` (a head of #291 before its last) | every allocated subtype has `then` | refused |
| `1.0.0+77` (this run) | `668ce3f0` | every allocated subtype has `then` | refused |

Size (`release_comparison.txt`, written by `harness/release_comparison.py` from the three run directories): the snapshot profile's total `self_size` is 4,091,488 B for `1.0.0+75` and 4,092,976 B for `1.0.0+76` and `+77`, +1,488 B (+0.036 %). The archived `App.framework/App` is 3,913,680 B in all three. The profiles (9 MB each) and the `1.0.0+76` run's logs are not kept here.

## Per step (`steps254.out`)

| Step | Edit | Result | On boot |
|---|---|---|---|
| `boot_release`, `boot_release2` | none | ran, `no active patch` | `init=I1`, `greeting=G1`, `count` to 3, `stream=T0..T2` |
| `t254` | `loadGreeting` awaits `TickerFuture.complete()` | **refused**, nothing uploaded | `patch_t254_cli.txt` (an excerpt) line 6246: the constructor `TickerFuture.complete` alone; no `then` reason in the kept lines |
| `p06` | `loadGreeting` returns `'G2'` | **published, patch 1** (1.16 KB) | `applied 1/1`, `greeting=G2` |
| `p07` | `_start` loops 5 times, not 3 | **published, patch 2** (2.71 KB) | `applied 1/1`, `count` to 5 |
| `p08` | `ticker` yields `U$i` | **published, patch 3** (1.33 KB) | `applied 1/1`; `stream=U0..U2` in the device log for `p08_boot`, `p08_boot2` and `trio2_download`, which still ran patch 3 |
| `trio2` | `p03+p16b+p29`, carrying `_start` | **published, patch 4** (3.74 KB) | `applied 3/3`, `count=10/20/30`, `events=3` |
| `p05` | `initState` logs `I2` | **published, patch 5** (1.36 KB) | `p05_boot`: see Limits; `p05_boot2`: `applied 1/1`, `Some(5)`, `init=I2` |
| rollback of patch 5 | | `Rolled back: yes` (`rollback_cli.txt`) | `rb_learn` still on patch 5 (`init=I2`); `rb_boot`, `rb_boot2` on patch 4 (`applied 3/3`, `init=I1`, `count=10/20/30`) |

`Launch success` lines in the device log: patches 1, 2 and 3 three each, patch 4 five, patch 5 two (16; the `1.0.0+76` run had 17, with 3 for patch 5; `release_comparison.txt`). No `Runner` line has `Unhandled` or `NoSuchMethod`.

## Where artifacts came from

`artifact_origin.jsonl`: 22 requests through `origin.py` to ci-build's production cdn-cache (`10.0.0.41:8085`), 0 redirects: 8 were 200 with `X-Overlay: hit`, and 14 were 404s, all `aot-tools.dill`, as before. Fewer than `ios-cell-9995f957`'s 48 because the CLI's cache was cloned from that run. `outbound_connect.jsonl`: `pub.dev` 54, `github.com` 1.
