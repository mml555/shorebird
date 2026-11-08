#!/usr/bin/env bash
# cspell:words dartaotruntime killgate nodm depot
#
# build_host_zips.sh -- build the host toolchain zips FROM THE ROUTE B TREE.
#
# VENDORED 2026-09-10 from /Volumes/build/route-b/build_host_zips.sh, previously
# the only copy. Changes from that original, all of them here: ROOT/TOOLS take
# the house ${VAR:-default} form (build_host.sh:17-18); `mkdir -p` on the log
# dir, which the original omitted and got away with only because logs/ already
# existed; and `|| exit 1` on the `cd`. Full diff:
# evidence/host/SSD_SCRIPT_VENDORING_2026-09-10.txt.
#
# publish_ios_overlay.sh defaults HOST_REL to the shipping tree's
# host_release_arm64_nodm, which does NOT carry the killgate SDK edits. That is
# correct for the shipping engine and wrong here: it published a
# flutter_patched_sdk_product whose dart:_internal has no
# attachBytecodeToFunction, while sky_engine.zip (from this tree) does. The app
# then compiles against a platform dill that cannot see the symbol its own
# sources declare.
set -uo pipefail
ROOT=${ROOT:-/Volumes/build/route-b}
TOOLS=${TOOLS:-/Volumes/build/ios-engine}   # depot_tools + gitconfig are shared: tools, not state
SRC=$ROOT/flutter/engine/src
LOG=$ROOT/logs/host_zips_$(date +%Y%m%d-%H%M%S).log
mkdir -p "$(dirname "$LOG")"
export PATH="$TOOLS/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0
export GIT_CONFIG_GLOBAL="$TOOLS/gitconfig"
cd "$SRC" || exit 1
{
  echo "=== started $(date -u +%FT%TZ) ==="
  time nice -n 5 ninja -C out/host_release_arm64 -j8 \
    zip_archives/flutter_patched_sdk_product.zip \
    zip_archives/dart-sdk-darwin-arm64.zip
  echo "=== ninja exit=$? ==="
  ls -la out/host_release_arm64/zip_archives/ 2>/dev/null
  echo "=== DONE ==="
} >>"$LOG" 2>&1
