#!/usr/bin/env bash
# cspell:words killgate dynmod caffeinate routebios regated regen
#
# build_ios.sh -- Route B step 8 prerequisite: the iOS device engine, built
# FROM THE ROUTE B TREE.
#
# This is the build ROUTE_B.md trap #1 predicts will fail. The killgate patch
# edits sdk/lib/_internal/vm/lib/internal_patch.dart and sdk/lib/internal/
# internal.dart, which compile into platform_strong.dill regardless of the GN
# flag; mixing them into an iOS engine build has previously failed the AOT step
# with "Unexpected tag 4 (Field)". Finding out is the point -- the dedicated
# checkout exists so that failure cannot contaminate the shipping iOS tree.
#
# Run detached, NEVER as a harness background task:
#   screen -dmS routebios bash -c 'caffeinate -is /Volumes/build/route-b/build_ios_release.sh'
set -uo pipefail

ROOT=/Volumes/build/route-b
SRC=$ROOT/flutter/engine/src
OUT=ios_release
LOG=$ROOT/logs/ios_release_$(date +%Y%m%d-%H%M%S).log
mkdir -p "$(dirname "$LOG")"
export PATH=/Volumes/build/ios-engine/depot_tools:$PATH
export GIT_CONFIG_GLOBAL=/Volumes/build/ios-engine/gitconfig
export DEPOT_TOOLS_UPDATE=0
cd "$SRC" || exit 1

{
  echo "=== started $(date -u +%FT%TZ) ==="
  # --dart-dynamic-modules on the iOS build too: the whole point is a device
  # engine whose runtime carries the interpreter and InterpretCall.
  # --no-prebuilt-dart-sdk is mandatory (DEPS' macOS Dart SDK is in a private
  # bucket that 401s). --ios takes no cpu flag; iOS is arm64-only here.
  ./flutter/tools/gn --ios --runtime-mode=release \
    --no-prebuilt-dart-sdk --dart-dynamic-modules
  echo "=== gn exit=$? ==="

  # TWO different interpreters, and conflating them costs a build.
  #
  # shorebird_use_interpreter (config.gni, defaults to is_ios) selects
  # SHOREBIRD'S interpreter path -- the one backed by their PRIVATE Dart fork.
  # It pulls in flutter/runtime/shorebird/patch_cache.cc, the single file in the
  # tree that calls Shorebird_ReadLinkHeader, which vanilla Dart does not
  # define. Leaving it at its iOS default is what failed this build in 97
  # seconds with "use of undeclared identifier 'Shorebird_ReadLinkHeader'".
  #
  # dart_dynamic_modules selects VANILLA Dart's interpreter, which is the one
  # Route B is built on. So the correct combination is genuinely
  # shorebird_use_interpreter=false WITH dart_dynamic_modules=true -- "no
  # interpreter" in their sense, "interpreter" in ours. The shipping iOS tree
  # sets the same false for the same reason (selfhost patch 0002 regated this
  # dep from is_ios onto this flag precisely so an iOS engine could build
  # against vanilla Dart).
  #
  # tools/gn has no pass-through for arbitrary args, so append and regenerate.
  if ! grep -q '^shorebird_use_interpreter' "out/$OUT/args.gn"; then
    echo 'shorebird_use_interpreter = false' >> "out/$OUT/args.gn"
  fi
  ./flutter/third_party/gn/gn gen "out/$OUT" --check --export-compile-commands
  echo "=== gn regen exit=$? ==="
  echo "--- args.gn ---"
  cat "out/$OUT/args.gn" 2>/dev/null
  echo "--- ninja ---"
  time nice -n 5 ninja -C "out/$OUT" -j8
  echo "=== ninja exit=$? finished $(date -u +%FT%TZ) ==="
  find "out/$OUT" -name 'Flutter' -type f -maxdepth 4 -exec ls -lh {} \; 2>/dev/null
  echo "=== DONE ==="
} >>"$LOG" 2>&1
