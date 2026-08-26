#!/usr/bin/env bash
# cspell:words killgate dynmod caffeinate routebios regen prebuilt routebmodes
#
# build_ios_debug_profile.sh -- the iOS DEBUG and PROFILE engines, from the same
# pinned Route B tree as ios_release.
#
# WHY THESE EXIST NOW. `flutter_cache.dart`'s `_iosBinaryDirs` requires all three
# iOS engine groups -- `ios`, `ios-profile`, `ios-release` -- before it will
# proceed with an iOS build, INCLUDING a release build. Measured 2026-08-25: a
# clean-cache release on cell 3b2471e8 completes the Flutter SDK group and then
# 404s on `ios/artifacts.zip`, because this tree had only `out/ios_release`.
#
# THE INVARIANT THIS SERVES, and it is deliberately not weakened to "the bytes
# that ship":
#
#   For each certified workflow, the cell must provide every engine-addressed
#   artifact the real consumer requests for that workflow from an empty cache.
#
# "debug/profile are not linked into the release" is NOT permission to exclude
# them. They are toolchain state the consumer requires to perform the workflow,
# and borrowing them from another engine's hash is the same defect that
# `sky_engine.zip` just exposed.
#
# SAME RECIPE AS build_ios.sh, mode being the only difference. The two flag
# traps it records apply unchanged:
#   * `--no-prebuilt-dart-sdk` is mandatory (DEPS' macOS Dart SDK 401s);
#   * `shorebird_use_interpreter = false` WITH `--dart-dynamic-modules` -- "no
#     interpreter" in Shorebird's sense, "interpreter" in ours. Leaving the iOS
#     default fails in ~97s on `Shorebird_ReadLinkHeader`.
#
# Run detached, NEVER as a harness background task:
#   screen -dmS routebmodes bash -c 'caffeinate -is /Users/mendell/shorebird/selfhost/engine/route_b/build_ios_debug_profile.sh'
set -uo pipefail

ROOT=/Volumes/build/route-b
SRC=$ROOT/flutter/engine/src
LOG=$ROOT/logs/ios_modes_$(date +%Y%m%d-%H%M%S).log
mkdir -p "$(dirname "$LOG")"
export PATH=/Volumes/build/ios-engine/depot_tools:$PATH
export GIT_CONFIG_GLOBAL=/Volumes/build/ios-engine/gitconfig
export DEPOT_TOOLS_UPDATE=0
cd "$SRC" || exit 1

build_mode() { # <runtime-mode> <out-dir>
  local mode=$1 out=$2
  echo "=== $out ($mode) started $(date -u +%FT%TZ) ==="
  ./flutter/tools/gn --ios --runtime-mode="$mode" \
    --no-prebuilt-dart-sdk --dart-dynamic-modules
  echo "=== gn exit=$? ==="
  if ! grep -q '^shorebird_use_interpreter' "out/$out/args.gn"; then
    echo 'shorebird_use_interpreter = false' >> "out/$out/args.gn"
  fi
  ./flutter/third_party/gn/gn gen "out/$out" --check --export-compile-commands
  echo "=== gn regen exit=$? ==="
  echo "--- args.gn ---"
  cat "out/$out/args.gn" 2>/dev/null
  echo "--- ninja ---"
  time nice -n 5 ninja -C "out/$out" -j8
  echo "=== ninja exit=$? finished $(date -u +%FT%TZ) ==="
  find "out/$out" -name 'Flutter' -type f -maxdepth 4 -exec ls -lh {} \; 2>/dev/null
  echo "=== $out DONE ==="
}

{
  # DEBUG FIRST, deliberately: it is the one the consumer asks for first, so a
  # failure shows up against the artifact that is actually blocking.
  build_mode debug   ios_debug
  build_mode profile ios_profile
  echo "=== ALL DONE $(date -u +%FT%TZ) ==="
} >>"$LOG" 2>&1
echo "$LOG"
