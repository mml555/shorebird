#!/usr/bin/env bash
# stage_h2_cell.sh -- assemble the real 16-member v2 stage for the H2 successor.
#
# Five members carry the CORRECTED 9e8c898a host lineage; the other eleven are
# EXACT H-era bytes, because H's engine, iOS modes, sky packages, compiler and
# patch differs were never the defect. The two self-referential metadata files
# are canonicalized back to their %H templates before staging, so the stage is
# addressable without a fixed point.
#
# The `darwin-arm64/artifacts.zip` staged here already carries the injected
# const_finder. That injection uses `zip`, which stamps mtimes, so it is done
# ONCE and the resulting bytes are what get addressed AND published -- doing it
# again at publish time would produce a different archive than the one addressed.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SELFHOST="$(cd "$HERE/../.." >/dev/null 2>&1 && pwd)"
SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OVERLAY=${OVERLAY:-$SELFHOST/cdn/overlay}
H=${H:-a5a8be5854c529268378ce16762a16d6e31763e9}
FS_NEW=${FS_NEW:?set FS_NEW to the regenerated font-subset.zip}
ART_NEW=${ART_NEW:?set ART_NEW to the new darwin-arm64/artifacts.zip WITH const_finder}
STAGE=${STAGE:?set STAGE to the output stage dir}

MINT_CELL_LIB_ONLY=1 . "$HERE/mint_route_b_cell.sh"
set +e
die() { echo "ERROR: $*" >&2; exit 1; }

FI='flutter_infra_release/flutter/%H'
SB='download.shorebird.dev/shorebird/%H'
rm -rf "$STAGE"

# --- five corrected host members ---------------------------------------------
v2_stage_install "$STAGE" "$FI/dart-sdk-darwin-arm64.zip"       "$SRC/out/host_release_arm64_nodm/zip_archives/dart-sdk-darwin-arm64.zip" || die dart-sdk
v2_stage_install "$STAGE" "$FI/flutter_patched_sdk_product.zip" "$SRC/out/host_release_arm64_nodm/zip_archives/flutter_patched_sdk_product.zip" || die psdk_product
v2_stage_install "$STAGE" "$FI/flutter_patched_sdk.zip"         "$SRC/out/host_debug_arm64/zip_archives/flutter_patched_sdk.zip" || die psdk
v2_stage_install "$STAGE" "$FI/darwin-arm64/artifacts.zip"      "$ART_NEW" || die host_artifacts
v2_stage_install "$STAGE" "$FI/darwin-arm64/font-subset.zip"    "$FS_NEW"  || die font_subset

# --- nine unchanged members, exact H bytes ------------------------------------
for m in "$FI/ios-release/artifacts.zip" "$FI/ios/artifacts.zip" "$FI/ios-profile/artifacts.zip" \
         "$FI/sky_engine.zip" "$FI/flutter_gpu.zip" \
         "$SB/route-b-compiler-darwin-arm64.zip" \
         "$SB/patch-darwin-arm64.zip" "$SB/patch-darwin-x64.zip" "$SB/patch-linux-x64.zip"; do
  v2_stage_install "$STAGE" "$m" "$OVERLAY/${m/\%H/$H}" || die "$m"
done

# --- two self-referential members, canonicalized to %H templates --------------
mkdir -p "$STAGE/$FI" "$STAGE/$SB"
v2_canonicalize "$OVERLAY/flutter_infra_release/flutter/$H/engine_stamp.json" "$H" \
  > "$STAGE/$FI/engine_stamp.json" || die "engine_stamp canonicalization"
v2_canonicalize "$OVERLAY/download.shorebird.dev/shorebird/$H/artifacts_manifest.yaml" "$H" \
  > "$STAGE/$SB/artifacts_manifest.yaml" || die "artifacts_manifest canonicalization"

# --- the compiler must be the already-qualified bundle ------------------------
WANT=9d4ace27d6d6b77c0bad6d0cbc318f4b4a4b74c59f3462407d688843ee779c59
GOT=$(shasum -a 256 "$STAGE/$SB/route-b-compiler-darwin-arm64.zip" | cut -d' ' -f1)
[[ "$GOT" == "$WANT" ]] || die "compiler bundle is $GOT, not the qualified $WANT"
echo "compiler bundle verified: $WANT"
echo "staged $(cd "$STAGE" && find . -type f | wc -l | tr -d ' ') files"
