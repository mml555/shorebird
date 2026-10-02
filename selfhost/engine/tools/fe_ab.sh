#!/usr/bin/env bash
# cspell:words dartaotruntime OURSDK SDKROOT FLREV FLDIR tostring genkernel selfhost stockfe ourfe frontends nodm Ddart
# A/B the two frontends for the table-selector divergence documented in
# ../../TFA_ROOT_CAUSE.md. Compiles the same app twice with the exact argument
# list flutter_tools builds for an iOS release, changing only the frontend
# binary: Shorebird's published one vs the one from our own engine build.
#
# Read the two dills afterwards with probe_length.dart / dump_selectors.dart /
# layout_scan.dart. See README.md.
set -euo pipefail

APP=${APP:?set APP to the Flutter app directory}
PKG=${PKG:?set PKG to the app's package name (pubspec `name:`)}
OUT=${OUT:-/tmp}
FLREV=${FLREV:-c15ef6379403a0a55531a058bdb2c8e55bc05c98}
FLDIR=${FLDIR:-$HOME/.shorebird/bin/cache/flutter/$FLREV}
SRC=${SRC:-/Volumes/build/ios-engine/flutter/engine/src}
OURSDK=${OURSDK:-$SRC/out/host_release_arm64_nodm/dart-sdk}
SDKROOT=${SDKROOT:-$FLDIR/bin/cache/artifacts/engine/common/flutter_patched_sdk_product/}

run_fe () {  # $1=label  $2=dartaotruntime  $3=frontend_server snapshot
  echo "==> $1"
  "$2" "$3" \
    --sdk-root "$SDKROOT" \
    --target=flutter \
    --no-print-incremental-dependencies \
    -Ddart.vm.profile=false \
    -Ddart.vm.product=true \
    --delete-tostring-package-uri=dart:ui \
    --delete-tostring-package-uri=package:flutter \
    --aot --tfa \
    --target-os ios \
    --packages "$APP/.dart_tool/package_config.json" \
    --output-dill "$OUT/app_$1.dill" \
    --verbosity=error \
    "package:$PKG/main.dart"
  echo "    size=$(stat -f%z "$OUT/app_$1.dill" 2>/dev/null || echo MISSING)"
}

# Shorebird's published host SDK. Use the dart-sdk pairing: the copy of
# frontend_server_aot.dart.snapshot under artifacts/engine/ is built against a
# different snapshot version and dies with `Wrong full snapshot version`.
run_fe stockfe "$FLDIR/bin/cache/dart-sdk/bin/dartaotruntime" \
               "$FLDIR/bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot"
run_fe ourfe   "$OURSDK/bin/dartaotruntime" \
               "$OURSDK/bin/snapshots/frontend_server_aot.dart.snapshot"
