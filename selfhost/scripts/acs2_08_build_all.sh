#!/usr/bin/env bash
# cspell:words armv ninja depot ddm
# ANDROID-CELL-SUPPLY-2: build all three Android release architectures from the
# PATCHED revision. arm64 goes first so it can be compared against the banked
# pre-patch control — an armv7-only applicability gate must not change arm64
# output.
set -uo pipefail
B=/Volumes/build/route-b/acs2
SRC=$B/flutter/engine/src
export PATH=/Volumes/build/ios-engine/depot_tools:$PATH
export GIT_CONFIG_GLOBAL=/Volumes/build/ios-engine/gitconfig
export DEPOT_TOOLS_UPDATE=0
cd "$SRC" || exit 1
echo "=== engine source $(git -C flutter rev-parse HEAD) (parent $(git -C flutter rev-parse HEAD^)) ==="
for cpu in arm64 arm x64; do
  case "$cpu" in
    arm64) OUT=out/android_release_arm64; ABI=android-arm64-release ;;
    arm)   OUT=out/android_release;       ABI=android-arm-release ;;
    x64)   OUT=out/android_release_x64;   ABI=android-x64-release ;;
  esac
  echo "########## $cpu started $(date -u +%FT%TZ) ##########"
  ninja -C "$OUT" \
    "zip_archives/$ABI/darwin-x64.zip" \
    "zip_archives/$ABI/artifacts.zip" \
    "zip_archives/$ABI/symbols.zip" \
    flutter/shell/platform/android:embedding_jars \
    flutter/shell/platform/android:abi_jars
  echo "########## $cpu ninja exit=$? $(date -u +%FT%TZ) ##########"
  ls -la "$OUT/zip_archives/$ABI/" 2>/dev/null | tail -5
done
echo "=== all done $(date -u +%FT%TZ) ==="
