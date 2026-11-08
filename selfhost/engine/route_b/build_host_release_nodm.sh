#!/usr/bin/env bash
# cspell:words dartaotruntime killgate dynmod nodm depot caffeinate
#
# build_host_release_nodm.sh -- G15 gate 3a: build R3's host toolchain WITHOUT
# dart_dynamic_modules, so the platform dill an app build downloads can come
# from the tree that owns the iOS engine and the Route B Dart patches.
#
# VENDORED 2026-09-10 from /Volumes/build/route-b/build_host_release_nodm.sh,
# previously the only copy. One change from that original: ROOT/TOOLS take the
# house ${VAR:-default} form (build_host.sh:17-18). The body is byte-identical.
# Full diff: evidence/host/SSD_SCRIPT_VENDORING_2026-09-10.txt.
#
# THE DEFECT THIS EXISTS TO FIX. `flutter_patched_sdk_product.zip` is published
# from publish_ios_overlay.sh's HOST_REL default, which points at R4
# (out/host_release_arm64_nodm). R4's Dart tree carries ZERO of the Route B
# patches (`attachBytecodeToFunction` x0 in internal_patch.dart), while R3's
# carries them (x4 in source, x8 in the built dill). So every release ever built
# on any of our cells compiled its app kernel against a dill from a tree that is
# not ours -- and the cell ADDRESS was computed over R3's dill all along
# (mint_route_b_cell.sh:31,68). Address certifies one dill, download delivers
# another. See selfhost/evidence/g15/hooks_delivery_verdict.txt.
#
# WHY nodm, WHEN R3'S ios_release IS dm=true. The "Unexpected tag 4 (Field)"
# failure couples the platform dill to the FRONTEND_SERVER, not to gen_snapshot.
# The published frontend_server (publish_ios_overlay.sh:213) comes from R4's
# host_debug_arm64, which is dm=false. A dm=true gen_snapshot alongside a
# dm=false frontend/dill is the combination that already builds releases today,
# so matching the dill to the frontend is the change that is actually owed.
#
# WHY A NEW OUT DIR RATHER THAN RECONFIGURING out/host_release_arm64. That dir's
# dill (9f5a5f75...) is the FLUTTER_PLATFORM input every existing cell address
# was computed over. Rebuilding it in place would silently rewrite what those
# addresses mean.
#
# The args are DERIVED, not authored: host_release_arm64/args.gn minus its
# `dart_dynamic_modules = true` line. That is exactly and only how R4's nodm dir
# differs from its dm one, so this reproduces a configuration that is known to
# produce a usable dill rather than inventing one.
#
# Run detached, NEVER as a harness background task:
#   screen -dmS r3nodm bash -c 'caffeinate -is selfhost/engine/route_b/build_host_release_nodm.sh'
set -uo pipefail

ROOT=${ROOT:-/Volumes/build/route-b}
TOOLS=${TOOLS:-/Volumes/build/ios-engine}   # depot_tools + gitconfig are shared: tools, not state
SRC=$ROOT/flutter/engine/src
SRCDIR=out/host_release_arm64
OUTDIR=out/host_release_arm64_nodm
LOG=$ROOT/logs/host_release_nodm_$(date +%Y%m%d-%H%M%S).log
mkdir -p "$(dirname "$LOG")"
export PATH="$TOOLS/depot_tools:$PATH"
export GIT_CONFIG_GLOBAL="$TOOLS/gitconfig"
export DEPOT_TOOLS_UPDATE=0
cd "$SRC" || exit 1

{
  echo "=== started $(date -u +%FT%TZ) ==="

  if [ ! -f "$SRCDIR/args.gn" ]; then
    echo "FATAL: $SRCDIR/args.gn missing -- nothing to derive the config from"
    exit 2
  fi

  mkdir -p "$OUTDIR"
  grep -v '^dart_dynamic_modules' "$SRCDIR/args.gn" > "$OUTDIR/args.gn"
  echo "--- derived args.gn (diff vs $SRCDIR) ---"
  diff "$SRCDIR/args.gn" "$OUTDIR/args.gn"
  echo "--- (a lone '< dart_dynamic_modules = true' above is the intended and ONLY difference) ---"

  ./flutter/third_party/gn/gn gen "$OUTDIR" --check --export-compile-commands
  echo "=== gn gen exit=$? ==="

  # The same two archives R4's nodm build produces, and for the same reason: the
  # platform dill and dartaotruntime are version-locked to each other and to the
  # frontend_server that reads their output.
  time nice -n 5 ninja -C "$OUTDIR" -j8 \
    zip_archives/flutter_patched_sdk_product.zip \
    zip_archives/dart-sdk-darwin-arm64.zip
  echo "=== ninja exit=$? finished $(date -u +%FT%TZ) ==="

  ls -lh "$OUTDIR/zip_archives/" 2>/dev/null
  D="$OUTDIR/flutter_patched_sdk_product/platform_strong.dill"
  [ -f "$D" ] || D="$OUTDIR/flutter_patched_sdk/platform_strong.dill"
  if [ -f "$D" ]; then
    echo "--- platform dill: $D"
    shasum -a 256 "$D"
    printf 'attachBytecodeToFunction occurrences: '
    strings -a "$D" | grep -cF attachBytecodeToFunction
    echo "(expect NON-ZERO. A zero here means this build did not pick up R3's"
    echo " Dart patches and publishing it would re-create the very split this"
    echo " build exists to close.)"
  else
    echo "--- NO platform dill produced; the ninja step did not do what this needs"
  fi
  echo "=== DONE ==="
} >>"$LOG" 2>&1
