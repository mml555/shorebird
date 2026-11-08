#!/usr/bin/env bash
# cspell:words depot seam
#
# build_ios_seam6.sh -- bare incremental relink of out/ios_release.
#
# VENDORED 2026-09-10 from /Volumes/build/route-b/build_ios_seam6.sh, previously
# the only copy. Changes from that original, all of them here: ROOT/TOOLS take
# the house ${VAR:-default} form (build_host.sh:17-18); `mkdir -p` on the log
# dir, which the original omitted; and `|| exit 1` on the `cd`. Full diff:
# evidence/host/SSD_SCRIPT_VENDORING_2026-09-10.txt.
#
# NO gn STEP, deliberately: this reuses the args.gn build_ios.sh already
# generated, so it is the fast path for re-ninja after a source edit and NOT a
# substitute for build_ios.sh on a fresh tree. It also writes a differently
# named log (ios_seam6_*, not ios_release_*), so run_mint_build.sh will not pick
# it up -- a build driven through here does not update mint_build.status, and
# probes/assert_mint_ready.sh's staleness guard is what catches that.
set -uo pipefail
ROOT=${ROOT:-/Volumes/build/route-b}
TOOLS=${TOOLS:-/Volumes/build/ios-engine}   # depot_tools + gitconfig are shared: tools, not state
SRC=$ROOT/flutter/engine/src
LOG=$ROOT/logs/ios_seam6_$(date +%Y%m%d-%H%M%S).log
mkdir -p "$(dirname "$LOG")"
export PATH="$TOOLS/depot_tools:$PATH" DEPOT_TOOLS_UPDATE=0
export GIT_CONFIG_GLOBAL="$TOOLS/gitconfig"
cd "$SRC" || exit 1
{ echo "=== started $(date -u +%FT%TZ) ==="; time nice -n 5 ninja -C out/ios_release -j8; echo "=== ninja exit=$? ==="; echo "=== DONE ==="; } >>"$LOG" 2>&1
