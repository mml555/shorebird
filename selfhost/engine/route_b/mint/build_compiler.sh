#!/usr/bin/env bash
# build_compiler.sh -- build the Route B compiler zip for engine E from the Mac engine tree's
# host_release_arm64_ddm out dir, with the selfhost/engine/route_b scripts of the helpers checkout.
# Local only: the overlay it writes is $IN/ov. Nothing is uploaded. Holds the shared heavy lock.
#
#   MINT_ENV=<env file> bash build_compiler.sh          # PLAN
#   MINT_ENV=<env file> bash build_compiler.sh --run
#
# Needs: MAC_TREE at E with out/host_release_arm64_ddm built (dart_dynamic_modules = true), and the
# patched SDK zip from the Linux half (PSDK_ZIP; publish_engine.sh --pull-linux fetches the half).
# Writes: $COMPILER_ZIP (also copied into $ENGINE_EXTRA for publish_engine.sh) and
# $IN/flutter_platform_strong.dill (used by stage_mint.sh).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); . "$HERE/lib.sh"; load_env; resolve_helpers
RUN=0; case "${1:-}" in --run) RUN=1;; "") ;; *) die "usage: $0 [--run]";; esac
T=${MAC_TREE:?set MAC_TREE in $MINT_ENV}
SRC=$T/engine/src; DDM=$SRC/out/${DDM_OUT_DIR:-host_release_arm64_ddm}
say "engine E=$E; tree $T; helpers $HELPERS_SHA"
say "ddm out dir $DDM; patched SDK $PSDK_ZIP; compiler zip $COMPILER_ZIP"
[[ -d $T/.git && "$(git -C "$T" rev-parse HEAD)" == "$E" ]] || die "$T is not a checkout at $E"
[[ -d $DDM ]] || die "no $DDM: build the host_release_arm64_ddm out dir first (dart_dynamic_modules = true)"
[[ -f $PSDK_ZIP ]] || die "no patched SDK zip at $PSDK_ZIP: run publish_engine.sh --pull-linux first"
[[ $RUN == 1 ]] || { echo "PLAN ONLY. Add --run to build."; exit 0; }
take_heavy_lock "build_compiler"
for s in build_dart2bytecode build_route_b_analyzer build_route_b_gen_kernel build_route_b_gen_dynamic_interface build_route_b_release_probe; do
  say "$(date +%T) $s"; SRC=$SRC OUT=$DDM nice -n 10 bash "$RB/$s.sh"
done
say "$(date +%T) package"
rm -rf "$IN/ov"; mkdir -p "$IN"
SRC=$SRC OUT=$DDM PSDK_ZIP=$PSDK_ZIP bash "$RB/publish_route_b_compiler.sh" --rev "$E" --overlay "$IN/ov"
mkdir -p "$(dirname "$COMPILER_ZIP")"
cp "$IN/ov/download.shorebird.dev/shorebird/$E/route-b-compiler-darwin-arm64.zip" "$COMPILER_ZIP"
unzip -p "$COMPILER_ZIP" flutter_platform_strong.dill > "$IN/flutter_platform_strong.dill"
mkdir -p "$ENGINE_EXTRA/download.shorebird.dev/shorebird/$E"
cp "$COMPILER_ZIP" "$ENGINE_EXTRA/download.shorebird.dev/shorebird/$E/"
shasum -a 256 "$COMPILER_ZIP" "$IN/flutter_platform_strong.dill"
echo BUILD_COMPILER_DONE
