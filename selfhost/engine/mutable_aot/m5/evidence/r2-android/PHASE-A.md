# R2 Android — Phase A: supported build inputs

**Result: no enablement work was required.** The checkout already carries the
Android dependencies, and the fork's own GN machinery configures an arm64
release engine without any substitution.

## What this engine revision expects, and how the checkout provides it

`flutter/DEPS` gates the Android dependencies on:

```
'download_android_deps': 'host_os == "mac" or (host_os == "linux" and host_cpu == "x64")'
```

On this macOS host that condition is **already true**, so an ordinary
`gclient sync` fetches them. All four are registered in `.gclient_entries` and
present on disk as CIPD packages:

```
engine/src/flutter/third_party/android_tools                     flutter/android/sdk/all/${platform}  version:36v8unmodified
engine/src/flutter/third_party/android_tools/trace_to_text       perfetto/trace_to_text/${platform}   git_tag:v25.0
engine/src/flutter/third_party/android_tools/google-java-format  flutter/android/google-java-format   version:1.7-1
engine/src/flutter/third_party/android_embedding_dependencies    flutter/android/embedding_bundle     last_updated:2025-10-15
engine/src/flutter/third_party/java/openjdk
```

There is no `android_tools/ndk`: this engine revision builds Android with the
`buildtools` clang toolchain rather than an NDK, so its absence is expected
rather than missing.

**Correction to the earlier report.** I previously stated Android had "no
checkout dependencies" after looking in `engine/src/third_party/android_*`.
DEPS places them under `engine/src/flutter/third_party/`. They were there the
whole time; I looked in the wrong directory.

## GN configuration

Produced by the fork's own tool, unmodified:

```
./flutter/tools/gn --android --android-cpu arm64 --runtime-mode release \
                   --no-prebuilt-dart-sdk --dart-dynamic-modules
-> out/android_release_arm64, 1355 targets from 362 files
```

The `--no-prebuilt-dart-sdk` and `--dart-dynamic-modules` flags mirror the iOS
build for the same reasons recorded in `build_ios_release.sh`: the prebuilt
macOS Dart SDK lives in a private bucket, and dynamic modules select vanilla
Dart's interpreter.

Resulting args, with the fork correctly stamped this time:

```
dart_version        = "5878283d55ef56049a8f3523759baa7e5ab72406"
target_os           = "android"
target_cpu          = "arm64"
dart_target_arch    = "arm64"
flutter_runtime_mode = "release"
dart_runtime_mode   = "release"
dart_dynamic_modules = true
```

## Targets being built

```
clang_arm64/gen_snapshot_arm64   the Android-targeting snapshot generator
libflutter.so                    the production Android engine library
```

## Target device

```
CPH2551, Android 16, arm64-v8a, attached over adb
```

## Nothing prohibited was done

No SDK or NDK copied from another checkout; no stale upstream gen_snapshot
reused; no target-OS check patched; no snapshot header altered; no host or
macOS snapshot used. The iOS rule applies from the start here: **both the
snapshot version hash and the target configuration string must match the
runtime.**
