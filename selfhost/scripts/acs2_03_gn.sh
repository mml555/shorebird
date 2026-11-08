#!/usr/bin/env bash
# cspell:words armv gclient prebuilt ninja depot cipd openjdk ddm
# ANDROID-CELL-SUPPLY-2 gate 1, step 3a: CONFIGURE the three Android release
# targets. Separated from ninja on purpose — a wrong flag set costs seconds
# here and hours after `ninja` starts.
#
# Flag set matches the iOS build of this same lineage
# (out/ios_release/args.gn): --no-prebuilt-dart-sdk because DEPS' macOS Dart
# prebuilt is a private bucket that 401s, and --dart-dynamic-modules because
# that is the configuration this tree is known to build.
#
# `shorebird_use_interpreter` defaults to `is_ios`, so it is already false on
# Android and needs no override — the iOS build had to set it explicitly and
# that is the one difference worth not re-deriving by hand.
set -uo pipefail
B=/Volumes/build/route-b/acs2
SRC=$B/flutter/engine/src
export PATH=/Volumes/build/ios-engine/depot_tools:$PATH
export GIT_CONFIG_GLOBAL=/Volumes/build/ios-engine/gitconfig
export DEPOT_TOOLS_UPDATE=0
cd "$SRC" || exit 1
echo "=== started $(date -u +%FT%TZ) ==="
for cpu in arm64 arm x64; do
  echo "----- gn --android --android-cpu=$cpu --runtime-mode=release -----"
  ./flutter/tools/gn --android --android-cpu="$cpu" --runtime-mode=release \
    --no-prebuilt-dart-sdk --dart-dynamic-modules
  echo "  gn exit=$?"
done
echo "=== generated out dirs ==="
ls -d out/android_release* 2>/dev/null
for d in out/android_release out/android_release_arm64 out/android_release_x64; do
  [ -d "$d" ] || continue
  echo "--- $d/args.gn (the lines that matter) ---"
  grep -E "target_os|target_cpu|dart_target_arch|flutter_runtime_mode|dart_dynamic_modules|shorebird_use_interpreter|dart_version|is_official_build|enable_lto" "$d/args.gn" | sed 's/^/    /'
done
echo "=== done $(date -u +%FT%TZ) ==="
