#!/usr/bin/env bash
# cspell:words depot
#
# build_flutter_platform.sh -- build the Flutter platform dill + frontend_server
# in the Route B tree, so the step 7 size measurement can run against a REAL
# Flutter app instead of a toy.
#
# VENDORED 2026-09-10 from /Volumes/build/route-b/build_flutter_platform.sh,
# previously the only copy. Changes from that original, all of them here:
# ROOT/TOOLS take the house ${VAR:-default} form (build_host.sh:17-18), and the
# bare `cd "$SRC"` gained an `|| exit 1` -- without it a missing tree does not
# stop the script, it builds whatever happens to be in the caller's cwd. Full
# diff: evidence/host/SSD_SCRIPT_VENDORING_2026-09-10.txt.
set -u
ROOT=${ROOT:-/Volumes/build/route-b}
TOOLS=${TOOLS:-/Volumes/build/ios-engine}   # depot_tools + gitconfig are shared: tools, not state
SRC=$ROOT/flutter/engine/src
LOG=$ROOT/logs/flutter_platform_$(date +%Y%m%d-%H%M%S).log
mkdir -p "$(dirname "$LOG")"
export PATH="$TOOLS/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0
export GIT_CONFIG_GLOBAL="$TOOLS/gitconfig"
cd "$SRC" || exit 1
{
  echo "=== started $(date -u +%FT%TZ) ==="
  time nice -n 5 ninja -C out/host_release_arm64 -j8 \
    flutter_patched_sdk/platform_strong.dill \
    gen/frontend_server_aot.dart.snapshot
  echo "=== ninja exit=$? ==="
  ls -la out/host_release_arm64/flutter_patched_sdk/ 2>/dev/null
  echo "=== DONE ==="
} >>"$LOG" 2>&1
