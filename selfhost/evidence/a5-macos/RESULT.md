# A5: iOS on a Mac, following GETTING_STARTED.md at `selfhost-v1.2.1`

2026-11-13, on the owner's Mac: Apple silicon, macOS 27, Xcode 27.2, Docker Desktop 29.9.2. The
bootstrap ran with a new `--root` in a scratch directory. The Mac's home directory was shared with
other work: the CLI's log folder, Xcode's DerivedData and the pub cache were not new. So this is
not a clean macOS user; that is still open (A7 on macOS). Gradle used its own `GRADLE_USER_HOME`
after another process on the shared Mac stopped the daemons in `~/.gradle` during the first
`shorebird init`.

Builds used `--no-codesign`. Installing and booting a patch on an iPhone is covered by IOS-E2E
([`UPSTREAM_PARITY.md`](../../UPSTREAM_PARITY.md)); this run covers the steps before that.

| Guide step | Result |
|---|---|
| 2 bootstrap `--ref selfhost-v1.2.1 --start-mirror` | `BOOTSTRAP COMPLETE`, about 5 minutes |
| 3 `setup.sh` | **failed**: `no matching manifest for linux/arm64/v8`. The server image `ghcr.io/mml555/code-push-server:1.4.0` is published for amd64 only. With `DOCKER_DEFAULT_PLATFORM=linux/amd64` it pulled the amd64 image, ran it under Docker Desktop's emulation and reported ready |
| 4 `flutter create`, `shorebird init`, `doctor --fix` | exit 0 (`init` on the second try, see above) |
| 5 `shorebird release ios --no-codesign` | exit 0, release `1.0.0+1` active for ios |
| 5 `shorebird patch ios --no-codesign` | **refused** for each of three edits a newcomer would try on the counter app, nothing uploaded (below) |
| 5, with a patchable function | release `1.0.0+2` with a top-level `greeting()` marked `@pragma('vm:never-inline')` and `@pragma('vm:entry-point')`, called from `build()`; a patch changing only its return value: exit 0, "Published Patch 1!", active on `stable` at 100%, one `aarch64` artifact of 1,002 bytes |

## The three refused edits

| Edit to `flutter create`'s `lib/main.dart` | CLI verdict |
|---|---|
| The text of `const Text('You have pushed the button this many times:')` | `Nothing in this patch differs from the release, so it would install and change nothing.` Wrong: the text did change. The refusal is safe (nothing was uploaded), the reason is not |
| `_counter++` to `_counter += 2`, inside the closure passed to `setState` | refused: every invocation of the target was compiled away (inlined, then folded) |
| `colorScheme.inversePrimary` to `colorScheme.primaryContainer` in `_MyHomePageState.build` | refused: `the release contains no surviving call site for it` |

`build()` is the method a UI change most often touches. `ROUTE_B.md` ("What patchable now covers")
already states that calls through the dispatch table are not patchable; this run shows what that
means for the first edit a developer makes. The guide's iOS section now says so and gives the shape
that is accepted.

## The `setup.sh` fix, checked on the same Mac

With the fallback from this PR: with the image removed, `setup.sh` printed the amd64-only warning,
pulled `linux/amd64` and reported the server ready. Run again with the image present, it printed
no warning and reported ready. Not run: a failing `docker manifest inspect` (the change leaves the
platform alone then, which is the behaviour before it), and `--scale` or TLS mode on arm64.

## Mirror

The bootstrap's mirror served the run: 24 `flutter_infra_release`, 27 `download.shorebird.dev`
(overlay paths, including the Route B compiler bundle and cell manifest), 8 `/gcs` (stock Flutter
files fetched once from Google's storage), 3 others.
