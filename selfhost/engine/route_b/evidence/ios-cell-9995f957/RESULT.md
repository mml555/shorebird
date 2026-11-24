<!-- cspell:words NUMS -->
# iOS device run through cell 9995f957, for #254 (2026-11-23)

**Result: the analysis 24 check works on a device run, and it refuses too much.** The #254 patch (`await TickerFuture.complete()`) was refused before upload. So were the three ordinary `await` edits (`p06`, `p07`, `p08`) and a trio that only carries an `async` function. All four of those published and ran under cell `f2458551`. Each refusal names `this release has no then on TickerFuture ... and 1 more`; `t254` also names the constructor `TickerFuture.complete`, which the release never uses. Every Material app allocates `TickerFuture`, so any iOS patch that changes or carries a function with an `await` is refused. That is #289. The one edit with no `await` (`p05`) published, ran on the iPhone, and rolled back cleanly. No launch failed. No patch was built with `--allow-unchecked-sdk-calls`.

This run makes cell `9995f957` **iOS-run with limits, not device-qualified for async patches** until #289 is fixed.

## Limits

- **The #254 patch was refused for two reasons, not one.** `patch_t254_cli.txt` line 6246 names the constructor `TickerFuture.complete` (which the release never used) and then `Future.then` on `TickerFuture`. The `await` reason is shown alone by `p06`, `p07` and `p08`, which use only `Future<void>.delayed`.
- **"and 1 more"**: a second `Future` subtype in the release has no `then` either. The CLI does not name it, and this run did not look for it.
- **Patches were unsigned.** The release printed `[WARN] No patch public key was provided` (`release_cli.txt`).
- **One CLI, one device, one app version, one published patch.** CLI `2f0b38a6`, the iPhone 7, release `1.0.0+75`.
- **Not an Android run.** The Android run of the same edits is separate (#254 does not apply to Android patches, which are full AOT).

## What ran

| | |
|---|---|
| CLI | mml555/shorebird `2f0b38a6990b60549152e282c73a66e8ec0ed906` (the merge of #285), a fresh detached worktree at `devrun/run-9995f957/cli`, `Shorebird 1.6.144+selfhost.1` (`bootstrap.log`) |
| Flutter | shorebird-flutter `8e996caeeba7d826cc27397660a996c1e6194d07` (`selfhost/3.50-cell-9995f957`); `bootstrap.log` prints `Shorebird Engine • revision 9995f9571ec94b60eca64ec7eaae5fa190285b4d`, and `up.out` prints `Flutter 3.50.1-0.0.pre-254` |
| Cell | `9995f9571ec94b60eca64ec7eaae5fa190285b4d`: the descriptor was served 200, 4141 bytes (`up.out`), and the patch builds fetched it and used the compiler bundle `9995f957…-route-b-compiler-darwin-arm64.zip` (`patch_*_cli.txt`, `[route-b] resolved compiler for engine 9995f957…`) |
| Server | `code_push_server` from the same checkout, local, `10.0.0.242:18290`, file store in `run-9995f957/data`. 69 request lines, none 4xx or 5xx (`server_requests.log`) |
| App | the shapes app (`main.dart`, `tally.dart`, `intl`), display name `shapes-9995f957`, app id `d650f802-c2aa-da73-2c03-6b4557c559b7`, version `1.0.0+75`, `shorebird release ios --no-codesign`, re-signed with `ios_resign.sh`, upgrade-installed over the signed run's `1.0.0+74` (never uninstalled; the updater printed `release_version changed 1.0.0+74 -> 1.0.0+75, creating new state`) |
| Release | `Route B retention: 57 named SDK members kept (default set only …)`, `verified 7156 patchable call sites` (`release_cli.txt`); Route B release hash `b207a26f7fca990da4b4044161398baf` (the `built-for` of the patched boots) |
| Device | iPhone 7, iOS 15.8.8 (`install.txt`) |
| Time | Mac clock 2026-11-23, release installed 20:45, last launch 20:54; `GO_DONE`, exit 0 for `up`, `release` and `steps254` |

The harness is in `harness/`: `go.sh` runs `up.sh`, `release.sh`, `steps254.sh` and `down.sh`, and `lib.sh` and `env.sh` are beside them (`env.sh` sources `../secrets.sh`, which is not copied). `main.dart` and `variants.py` are the `f2458551` run's files, with one variant added, `t254_await_ticker`. The scripts are the `f2458551` run's scripts with the cell, selector and version changed. `up.sh` now waits up to 60 s for the proxies to listen; at load 21 Python took about 5 s, and the first attempt stopped at the old fixed 2 s wait, before any build. heavy.lock was held around the bootstrap, the release build and each patch build.

## Per step (`steps254.out`)

| Step | Edit | Result | Reason (from `patch_<name>_cli.txt`) |
|---|---|---|---|
| `boot_release`, `boot_release2` | none | ran, `no active patch`, `init=I1`, `greeting=G1` | |
| `t254` | `loadGreeting` awaits `TickerFuture.complete()` instead of `Future<void>.delayed(...)` | **refused**, nothing uploaded | constructor `TickerFuture.complete` never used; and `Future.then` with no `then` on `TickerFuture` |
| `p06` | `loadGreeting` returns `'G2'` (body still awaits `Future<void>.delayed`) | **refused** | `Future.then`: `this release has no then on TickerFuture ... and 1 more` |
| `p07` | `_start` loops 5 times, not 3 (each iteration awaits `Future<void>.delayed`) | **refused** | the same, in `_HomeState._start` |
| `p08` | `ticker` yields `U$i` (an `async*` body that awaits `Future<void>.delayed`) | **refused** | the same, in `ticker` |
| `trio2` | `p03+p16b+p29`: the `setState` closure in `_increment`, a list length, a const | **refused** | `[route-b] carrying 1 unchanged member ... _HomeState._start`, then the same `Future.then` reason in `_start` |
| `p05` | `initState` logs `I2` | **published, patch 1** (1.35 KB) | |
| `p05_download` | | downloaded patch 1 (1384 bytes), still ran the release: `init=I1` | |
| `p05_boot`, `p05_boot2` | | `applied 1/1 targets`, `current_patch_number: Some(1)`, `init=I2`, `Launch success for patch 1` | |
| rollback of patch 1 | | `Rolled back: yes` (`rollback_cli.txt`) | |
| `rb_learn` | | still on patch 1 (`init=I2`); it learns of the rollback | |
| `rb_boot`, `rb_boot2` | | `no active patch`, `rolled_back_patch_numbers: Some([1])`, `init=I1` | |

Under `f2458551` (`../ios-cell-f2458551/RESULT.md`), `p06` and `p08` published inside the combo, and `p07` inside the trio. Each ran on this same iPhone.

No device excerpt has `Unhandled`, `NoSuchMethod`, `Exception`, `REFUSED` or `Reporting failed`. There are 3 `Launch success for patch 1` lines.

## Where artifacts came from

`artifact_origin.jsonl`: 48 requests through `origin.py` to ci-build's production cdn-cache (`10.0.0.41:8085`), 0 redirects. 34 were 200 with `X-Overlay: hit` (662.5 MB). The 14 404s are all `aot-tools.dill`, as in the `f2458551` run. 40 name `9995f957`. `outbound_connect.jsonl`: 164 CONNECTs, `pub.dev` 157, `github.com` 6 (the clone of shorebird-flutter at `8e996cae`), `release-assets.githubusercontent.com` 1.

## What follows

- #289: keep `then` on every allocated `Future` subtype in new releases, or narrow the analysis. Then re-run `p06`, `p07`, `p08` and the trio on the iPhone.
- The Android run of the same edits.
