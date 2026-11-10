<!-- cspell:words softwareupdate Rosetta xcframework pgrep fstack dartvm COPYFILE xattrs -->
# Building the macOS engine shard on a Mac

These scripts built the macOS side of engine `3a565f27` (shorebird-flutter
`shorebird/dev`) on an arm64 Mac on 2026-11-09. They run
`shorebird/ci/shards/macos.json` from the checkout, like Shorebird's CI does,
with the changes our setup needs. The files went into the GitHub release
`engine-3a565f273d871d1ef004faf1a87bf45637df8ad0` on mml555/shorebird-flutter,
next to the Linux build.

Everything lives in one work folder, `$SHOREBIRD_ENGINE_DIR` (default
`~/shorebird-engine`): git config, Rust, depot_tools, caches and logs. Nothing
is installed system-wide, and nothing needs `sudo`.

## Before you start

- Xcode, plus its Metal toolchain: `xcodebuild -downloadComponent MetalToolchain`.
- Rosetta: `softwareupdate --install-rosetta --agree-to-license` (no `sudo`
  needed). The x64 host tools run under it.
- About 150 GB free.

`bootstrap.sh` warns when either of the first two is missing.

## Run

```sh
source selfhost/engine/macos/env.sh
selfhost/engine/macos/bootstrap.sh <shorebird-flutter commit>
nohup caffeinate -i python3 selfhost/engine/macos/build_shard.py --jobs 6 > "$W/logs/build.log" 2>&1 &
selfhost/engine/macos/watchdog.sh &      # alerts on a stall or an early stop
```

At `-j6` on a shared 10-core Mac, each shard took 20 to 90 minutes, about 6 hours of building in all.
`logs/shards.status` gets one line per shard. To build what failed or never
ran, except iOS:

```sh
python3 selfhost/engine/macos/build_shard.py --jobs 6 --pending
```

Anything queued behind a build must wait on `logs/build.pid` (`kill -0`), not
on `pgrep -f`. A `pgrep -f` pattern also matches the waiter's own command
line, and on 2026-11-09 that left the Mac idle for three hours.

## What differs from Shorebird's CI, and why

| Change | Why |
|---|---|
| `download_dart_sdk: False` and `--no-prebuilt-dart-sdk` | Shorebird's prebuilt Dart bucket is private. Dart is built from the fork's DEPS. |
| SDK copies made by `strip_x1.py` | Xcode 27's `.tbd` stubs list an `arm64e.x1` architecture the engine's pinned lld cannot parse, and `os/trace_base.h`'s `stack_protector_ignore` breaks `-Werror` under `-fstack-protector-all`. The engine links arm64 and x86_64 only. The copies are APFS clones, so they cost almost no disk. |
| `host_cpu="x64"` for the `--mac --mac-cpu=x64` builds | Without the prebuilt Dart, an arm64 host dartvm would have to simulate x64 to run the build's Dart tools, and Dart's x64 simulator is unimplemented. |
| `build_analyze_snapshot=true` for 32-bit Android | The mac host build asks for `analyze_snapshot` for every Android target, and Dart only defines it for 64-bit ones. |
| `flutter/bin/et` runs on our arm64 Dart SDK | `et` expects the prebuilt SDK under `flutter/prebuilts/macos-arm64/`. `build_shard.py` links the one the mac-arm64 shard built. |
| iOS left out of `--pending` | At `3a565f27` the iOS engine needs `Shorebird_ReadLinkHeader` from the private Dart fork. `selfhost/engine/0002-ios-engine-on-vanilla-dart.patch` removes that, which makes a new engine hash. |

The x64 Dart SDK is cross-built, so it has no app-jit snapshots and no
`kernel-service.dart.snapshot`. That makes it 168 MB against stock's 232 MB.
It still runs, JIT-compiles from source, spawns isolates and `dart compile exe`s.

## Publish

```sh
python3 selfhost/engine/macos/collect_darwin.py <stage dir>
selfhost/engine/publish_patch_tool.sh --overlay <stage dir> --rev <engine>
selfhost/engine/publish_patch_tool.sh --overlay <stage dir> --rev <engine> --platform darwin-x64
```

`collect_darwin.py` stages every artifact from the shards that built, runs the
compose steps (universal framework and `gen_snapshot`), and lays them out as
the CDN overlay expects. Merge the stage into the release's overlay tar. No
path may already exist there. Then:

1. Add the files to `PROVENANCE.txt` in the overlay.
2. Rebuild `overlay-<engine>.txt` and the tar from it, with
   `COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs`, so no `._` files
   get in.
3. Rebuild `SHA256SUMS`.
4. Check every path through `selfhost/cdn/run_native.sh` before uploading.
5. Upload with `gh release upload --clobber`, `SHA256SUMS` last.
