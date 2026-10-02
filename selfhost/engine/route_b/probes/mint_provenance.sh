#!/usr/bin/env bash
# cspell:words psdk
#
# mint_provenance.sh -- does the mint write a TRUE ancestry claim into the map?
#
# WHAT THIS EXISTS TO CATCH. experimental_hashes.map is the one file whose entire
# job is to say what an engine hash contains. Until 2026-08-16 the mint inferred
# that sentence from a single flag: with --ios-artifacts it wrote "Donor X
# supplied every OTHER engine artifact", and without it "cloned byte-for-byte;
# only the CELL differs". Neither statement is measured, and both are FALSE the
# moment anything ELSE is substituted -- which routinely happens, because
# PSDK_ZIP installs a platform dill over the donor clone.
#
# It had already happened twice when this probe was written:
#   cd137db6  dill 757d09d7… against the donor's 9f5a5f75… -- the line claimed
#             the donor supplied every other artifact. Corrected by hand in
#             064115f9, which is what prompted this.
#   87130ae8  the same understatement, still uncorrected in the map, and
#             deliberately left there until the generator can express it.
#
# THE DECISIVE ARM IS `psdk-only` (case A): iOS artifacts INHERITED from the
# donor, platform dill SUBSTITUTED. That is the input shape the old logic cannot
# see at all -- no --ios-artifacts, so it takes the "cloned byte-for-byte" branch
# and asserts an ancestry that is false for one of the artifacts.
#
# THE NEGATIVE CONTROL IS THE OLD WORDING ITSELF. `legacy_provenance_comment`
# below is a frozen copy of the pre-fix logic, and the probe REQUIRES it to be
# caught on cases A and C. Without that, every arm here could pass because the
# judge is lenient rather than because the generator is truthful -- and a check
# that cannot fail is the failure this project has named more times than any
# other. The legacy copy is also required to PASS cases B and D, where it was
# accidentally right: a control that fails everything discriminates nothing.
#
# THE JUDGE IS INDEPENDENT. `judge` recomputes the true diff by digesting the
# two directories itself rather than believing the generator's own count. It
# accepts an artifact as NAMED by either its path or its digest, so the legacy
# wording gets credit where it genuinely identified one.
#
# THE PRODUCT'S OWN FUNCTION IS UNDER TEST, not a copy: this sources
# mint_route_b_cell.sh with MINT_CELL_LIB_ONLY=1. A reimplementation here would
# keep passing after the mint changed, which is the false-green shape the
# handoffs keep recording.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# Overridable so a MUTANT copy can be run through the same arms -- the check that
# arm 1 fails when the PRODUCT regresses, not only when the frozen copy does.
MINT=${MINT:-$HERE/../mint_route_b_cell.sh}
SELFHOST="$(cd "$HERE/../../.." >/dev/null 2>&1 && pwd)"
OVERLAY=${OVERLAY:-$SELFHOST/cdn/overlay}

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }
pass=0; fail=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then
    echo "  PASS  $1 -> $2"; pass=$((pass+1))
  else
    echo "  FAIL  $1 -> got [$2] want [$3]"; fail=$((fail+1))
  fi
}

[ -f "$MINT" ] || die "no mint script at $MINT"
# shellcheck disable=SC1090
MINT_CELL_LIB_ONLY=1 . "$MINT"
declare -f provenance_comment >/dev/null \
  || die "sourcing $MINT did not define provenance_comment -- the probe is not testing the product"

# ---------------------------------------------------------------------------
# The frozen pre-fix generator. DO NOT REPAIR THIS. It is the negative control,
# and its value is precisely that it is wrong on cases A and C.
# Copied verbatim from mint_route_b_cell.sh:206-227 as of 064115f9.
# ---------------------------------------------------------------------------
legacy_provenance_comment() { # <donor> <donorDir> <cellDir> [iosDigest] [note]
  local donor=$1 ios_digest=${4:-} note_text=${5:-}
  echo "# Route B compiler cell, minted $(date -u +%Y-%m-%d) from the cell"
  echo "# manifest (see mint_route_b_cell.sh)."
  if [[ -n "$ios_digest" ]]; then
    echo "# Engine binary CHANGED: iOS artifacts supplied via --ios-artifacts,"
    echo "# sha256 $ios_digest, which participates in this cell's address."
    echo "# Donor $donor supplied every OTHER engine artifact."
  else
    echo "# Engine binary is $donor's, cloned byte-for-byte; only the CELL differs."
  fi
  [[ -n "$note_text" ]] && echo "#"
  [[ -n "$note_text" ]] && printf '# %s\n' "$note_text"
  return 0
}

# ---------------------------------------------------------------------------
# The judge: measures the truth itself, then asks whether the text told it.
# ---------------------------------------------------------------------------
judge() { # <textFile> <donorDir> <cellDir> -> truthful | false-ancestry:<why>
  local txt=$1 donor_dir=$2 cell_dir=$3
  local rel ch dh entry
  local -a diffs=()

  while IFS= read -r rel; do
    if [[ ! -f "$donor_dir/$rel" ]]; then
      diffs+=("$rel|-"); continue
    fi
    ch=$(shasum -a 256 "$cell_dir/$rel" | cut -d' ' -f1)
    dh=$(shasum -a 256 "$donor_dir/$rel" | cut -d' ' -f1)
    [[ "$ch" == "$dh" ]] || diffs+=("$rel|$ch")
  done < <(cd "$cell_dir" && find . -type f | sed 's|^\./||' | sort)

  if (( ${#diffs[@]} == 0 )); then
    if grep -qi 'identical\|cloned byte-for-byte' "$txt"; then
      echo truthful
    else
      echo "false-ancestry:no-identity-claim"
    fi
    return
  fi

  # Something differs, so an unqualified clone claim is false on its face.
  if grep -qi 'cloned byte-for-byte' "$txt"; then
    echo "false-ancestry:claims-clone"; return
  fi
  # ...and every differing artifact must be named, by path or by digest.
  for entry in "${diffs[@]}"; do
    IFS='|' read -r rel ch <<<"$entry"
    if ! grep -qF -- "$rel" "$txt" && ! grep -qF -- "$ch" "$txt"; then
      echo "false-ancestry:unnamed:$rel"; return
    fi
  done
  echo truthful
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A donor cell shaped like a real one: nested paths, a mix of artifacts.
make_donor() { # <dir>
  local d=$1
  mkdir -p "$d/darwin-arm64" "$d/ios-release"
  echo "dart-sdk v1"        > "$d/dart-sdk-darwin-arm64.zip"
  echo "host artifacts v1"  > "$d/darwin-arm64/artifacts.zip"
  echo '{"stamp":"v1"}'     > "$d/engine_stamp.json"
  echo "psdk v1"            > "$d/flutter_patched_sdk_product.zip"
  echo "ios artifacts v1"   > "$d/ios-release/artifacts.zip"
  echo "sky engine v1"      > "$d/sky_engine.zip"
}

DONOR_HASH=1111111111111111111111111111111111111111
D="$WORK/donor"; make_donor "$D"

digest() { shasum -a 256 "$1" | cut -d' ' -f1; }

# case A -- THE DECISIVE ONE. iOS inherited, platform dill substituted.
A="$WORK/cellA"; cp -R "$D" "$A"; echo "psdk v2 SEAM" > "$A/flutter_patched_sdk_product.zip"
# case B -- iOS substituted only. The shape the old logic was written for.
B="$WORK/cellB"; cp -R "$D" "$B"; echo "ios artifacts v2" > "$B/ios-release/artifacts.zip"
B_IOS=$(digest "$B/ios-release/artifacts.zip")
# case C -- both, which is cd137db6's real shape.
C="$WORK/cellC"; cp -R "$D" "$C"
echo "psdk v2 SEAM" > "$C/flutter_patched_sdk_product.zip"
echo "ios artifacts v2" > "$C/ios-release/artifacts.zip"
C_IOS=$(digest "$C/ios-release/artifacts.zip")
# case D -- a true clone. Nothing substituted.
E="$WORK/cellD"; cp -R "$D" "$E"

emit() { # <generator> <cellDir> <iosDigest> -> file
  local gen=$1 cell=$2 ios=${3:-} out
  out=$(mktemp "$WORK/text.XXXXXX")
  "$gen" "$DONOR_HASH" "$D" "$cell" "$ios" "" > "$out"
  echo "$out"
}

echo
note "arm 0 -- judge instrument controls (a lenient judge would pass everything)"
FAKE=$(mktemp "$WORK/text.XXXXXX")
printf '# nothing to see here\n' > "$FAKE"
check "judge catches a text that names no substitution" \
  "$(judge "$FAKE" "$D" "$A")" "false-ancestry:unnamed:flutter_patched_sdk_product.zip"
printf '# flutter_patched_sdk_product.zip changed\n' > "$FAKE"
check "judge accepts a text that names it" "$(judge "$FAKE" "$D" "$A")" "truthful"
printf '# all artifacts identical\n' > "$FAKE"
check "judge accepts a clone claim when it is true" "$(judge "$FAKE" "$D" "$E")" "truthful"

echo
note "arm 1 -- the FIXED generator must be truthful on every input shape"
check "A psdk-only substitution"   "$(judge "$(emit provenance_comment "$A")"         "$D" "$A")" "truthful"
check "B ios-only substitution"    "$(judge "$(emit provenance_comment "$B" "$B_IOS")" "$D" "$B")" "truthful"
check "C both substituted"         "$(judge "$(emit provenance_comment "$C" "$C_IOS")" "$D" "$C")" "truthful"
check "D true clone"               "$(judge "$(emit provenance_comment "$E")"         "$D" "$E")" "truthful"

echo
note "arm 2 -- NEGATIVE CONTROL: the old wording must be CAUGHT on A and C"
check "A legacy is caught"  "$(judge "$(emit legacy_provenance_comment "$A")"         "$D" "$A")" \
  "false-ancestry:claims-clone"
check "C legacy is caught"  "$(judge "$(emit legacy_provenance_comment "$C" "$C_IOS")" "$D" "$C")" \
  "false-ancestry:unnamed:flutter_patched_sdk_product.zip"

echo
note "arm 3 -- and the control DISCRIMINATES: legacy was right on B and D"
check "B legacy passes"     "$(judge "$(emit legacy_provenance_comment "$B" "$B_IOS")" "$D" "$B")" "truthful"
check "D legacy passes"     "$(judge "$(emit legacy_provenance_comment "$E")"         "$D" "$E")" "truthful"

echo
note "arm 4 -- REAL CELLS: 87130ae8 -> cd137db6, the pair 064115f9 corrected by hand"
RD="$OVERLAY/flutter_infra_release/flutter/87130ae841e92d3e8bd4ea1759fb3cb474a6b3e4"
RC="$OVERLAY/flutter_infra_release/flutter/cd137db6aea4c76f41903a872b91afb8ac799626"
if [[ -d "$RD" && -d "$RC" ]]; then
  R_IOS=$(digest "$RC/ios-release/artifacts.zip")
  REAL_TEXT=$(mktemp "$WORK/text.XXXXXX")
  provenance_comment cd137db6aea4c76f41903a872b91afb8ac799626 "$RD" "$RC" "$R_IOS" "" > "$REAL_TEXT" \
    || true
  # Re-run with the donor hash in the donor position, which is how the mint calls it.
  provenance_comment 87130ae841e92d3e8bd4ea1759fb3cb474a6b3e4 "$RD" "$RC" "$R_IOS" \
    "G15: the _runMain success seam (patch 0011)." > "$REAL_TEXT"
  check "fixed generator is truthful on the real pair" "$(judge "$REAL_TEXT" "$RD" "$RC")" "truthful"
  check "it names the platform dill zip" \
    "$(grep -qF 'CHANGED flutter_patched_sdk_product.zip' "$REAL_TEXT" && echo yes || echo no)" "yes"
  check "it names the ios artifacts zip" \
    "$(grep -qF 'CHANGED ios-release/artifacts.zip' "$REAL_TEXT" && echo yes || echo no)" "yes"
  check "it reproduces 064115f9's measured count (9 unchanged)" \
    "$(grep -qE 'supplied the other 9,' "$REAL_TEXT" && echo yes || echo no)" "yes"
  check "legacy is caught on the real pair" \
    "$(judge "$(emit legacy_provenance_comment "$RC" "$R_IOS")" "$RD" "$RC")" \
    "false-ancestry:unnamed:flutter_patched_sdk_product.zip"
  echo
  echo "--- what the fixed generator writes for the real pair ---"
  sed 's/^/    /' "$REAL_TEXT"
else
  echo "  SKIP  real cells not present under $OVERLAY (arm 4 needs the overlay)"
fi

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
