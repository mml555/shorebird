#!/usr/bin/env bash
# stage_v13_cell.sh -- assemble the 16-member v2 stage for the v13 successor to H3.
#
# ONE MEMBER CHANGES. Fifteen are H3's EXACT published bytes, copied from the
# overlay rather than rebuilt, because H3's engine, iOS modes, sky packages and
# patch differs were never the subject: the only thing this cell changes is the
# Route B compiler archive, which now carries the analysis-version-13 analyzer.
#
# THE COMPILER ARCHIVE IS FROZEN, and that is not a convenience. `zip` stamps
# mtimes, so re-staging the same seven files produces a different archive than
# the one that was addressed -- the same trap `stage_h2_cell.sh` records for the
# const_finder injection. `route_b_analyze.aot` is additionally non-byte
# -reproducible on its own. So the archive is built ONCE (gate 6A), and these
# exact bytes are what get addressed AND published.
#
# The two self-referential metadata members are canonicalized back to their %H
# templates, so the stage is addressable without a fixed point.
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SELFHOST="$(cd "$HERE/../.." >/dev/null 2>&1 && pwd)"
OVERLAY=${OVERLAY:-$SELFHOST/cdn/overlay}
# Named so the mint library cannot clobber it: sourcing that file declares its
# own DONOR="" for argument parsing, which silently emptied this and produced
# member paths with no hash in them.
CELL_DONOR=${DONOR:-d4c0dbc2905286eb4537d5f9a7802693096ca1fd}
COMPILER=${COMPILER:?set COMPILER to the frozen route-b-compiler-darwin-arm64.zip}
WANT=${WANT:-7975b27c724240e720f77d338c80fcace5296148bd78c17588cee1b089e3fb22}
STAGE=${STAGE:?set STAGE to the output stage dir}
MINT_CELL_LIB_ONLY=1 . "$HERE/mint_route_b_cell.sh"
DONOR="$CELL_DONOR"
set +e
die() { echo "ERROR: $*" >&2; exit 1; }

FI='flutter_infra_release/flutter/%H'
SB='download.shorebird.dev/shorebird/%H'
rm -rf "$STAGE"

# --- fifteen unchanged members, H3's exact published bytes -------------------
for m in "$FI/dart-sdk-darwin-arm64.zip" "$FI/darwin-arm64/artifacts.zip" \
         "$FI/darwin-arm64/font-subset.zip" "$FI/flutter_gpu.zip" \
         "$FI/flutter_patched_sdk.zip" "$FI/flutter_patched_sdk_product.zip" \
         "$FI/ios-release/artifacts.zip" "$FI/ios/artifacts.zip" \
         "$FI/ios-profile/artifacts.zip" "$FI/sky_engine.zip" \
         "$SB/patch-darwin-arm64.zip" "$SB/patch-darwin-x64.zip" \
         "$SB/patch-linux-x64.zip"; do
  v2_stage_install "$STAGE" "$m" "$OVERLAY/${m/\%H/$DONOR}" || die "$m"
done

# --- two self-referential members, canonicalized to %H templates -------------
mkdir -p "$STAGE/$FI" "$STAGE/$SB"
v2_canonicalize "$OVERLAY/flutter_infra_release/flutter/$DONOR/engine_stamp.json" "$DONOR" \
  > "$STAGE/$FI/engine_stamp.json" || die "engine_stamp canonicalization"
v2_canonicalize "$OVERLAY/download.shorebird.dev/shorebird/$DONOR/artifacts_manifest.yaml" "$DONOR" \
  > "$STAGE/$SB/artifacts_manifest.yaml" || die "artifacts_manifest canonicalization"

# --- the ONE changed member: the frozen v13 compiler archive -----------------
v2_stage_install "$STAGE" "$SB/route-b-compiler-darwin-arm64.zip" "$COMPILER" \
  || die "compiler archive"
GOT=$(shasum -a 256 "$STAGE/$SB/route-b-compiler-darwin-arm64.zip" | cut -d' ' -f1)
[[ "$GOT" == "$WANT" ]] || die "compiler archive is $GOT, not the frozen $WANT"
echo "compiler archive verified: $WANT"

# --- prove the delta is exactly one ------------------------------------------
same=0; changed=0
while IFS= read -r rel; do
  donor_file="$OVERLAY/${rel/\%H/$DONOR}"
  if [[ ! -f "$donor_file" ]]; then echo "  ABSENT-IN-DONOR $rel"; changed=$((changed+1)); continue; fi
  a=$(shasum -a 256 "$donor_file" | cut -d' ' -f1)
  b=$(shasum -a 256 "$STAGE/$rel" | cut -d' ' -f1)
  if [[ "$a" == "$b" ]]; then same=$((same+1)); else
    changed=$((changed+1)); echo "  CHANGED $rel"
    echo "      $a"; echo "   -> $b"
  fi
done < <(cd "$STAGE" && find . -type f | sed 's|^\./||' | sort)
echo "staged $(cd "$STAGE" && find . -type f | wc -l | tr -d ' ') files: $same identical to the donor, $changed changed"
