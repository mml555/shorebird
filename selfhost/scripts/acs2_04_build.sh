#!/usr/bin/env bash
# cspell:words armv gclient prebuilt ninja depot cipd openjdk ddm
# ANDROID-CELL-SUPPLY-2 gate 1, step 3b: build the Android release engines.
#
# Targets are the engine's OWN publish-pipeline archives, not hand-assembled
# copies — the closure members are exactly what these emit:
#   zip_archives/android-<abi>-release/darwin-x64.zip      gen_snapshot
#   zip_archives/android-<abi>-release/artifacts.zip       flutter.jar
#   zip_archives/download.flutter.io/io/flutter/...         maven jar + pom
#
# armv7 is NOT built here: it cannot be CONFIGURED from this lineage on a macOS
# host. See logs/03_gn.log and the report — a Shorebird-added, ungated
# dependency on Dart's `analyze_snapshot`, which Dart itself supports only on
# 64-bit AOT builds. Changing engine source to work around that is a PM
# decision, not this script's.
set -uo pipefail
B=/Volumes/build/route-b/acs2
SRC=$B/flutter/engine/src
export PATH=/Volumes/build/ios-engine/depot_tools:$PATH
export GIT_CONFIG_GLOBAL=/Volumes/build/ios-engine/gitconfig
export DEPOT_TOOLS_UPDATE=0
cd "$SRC" || exit 1
CPU=${1:?usage: 04_build.sh <arm64|x64>}
case "$CPU" in
  arm64) OUT=out/android_release_arm64; ABI=android-arm64-release ;;
  x64)   OUT=out/android_release_x64;   ABI=android-x64-release ;;
  *) echo "unsupported cpu $CPU"; exit 64 ;;
esac
echo "=== $CPU started $(date -u +%FT%TZ) ==="
echo "--- args.gn ---"; grep -E "target_cpu|dart_target_arch|flutter_runtime_mode|dart_version|enable_lto|is_official_build" "$OUT/args.gn" | sed 's/^/    /'
ninja -C "$OUT" \
  "zip_archives/$ABI/darwin-x64.zip" \
  "zip_archives/$ABI/artifacts.zip" \
  "zip_archives/$ABI/symbols.zip" \
  flutter/shell/platform/android:embedding_jars \
  flutter/shell/platform/android:abi_jars
echo "=== ninja exit=$? $(date -u +%FT%TZ) ==="
echo "--- what landed ---"
ls -la "$OUT/zip_archives/$ABI/" 2>/dev/null
find "$OUT/zip_archives/download.flutter.io" -type f 2>/dev/null | head -12
echo "=== done $(date -u +%FT%TZ) ==="
