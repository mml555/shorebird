#!/usr/bin/env bash
# stage_mint.sh -- stage the cell from engine E's own bytes, compute the address, and (--run) mint it and
# bundle cell-<A>.tar + files.sha256 + names + tar.sha. Local only: no network, no publish.
#
#   MINT_ENV=<env file> bash stage_mint.sh          # DRY: stages, prints DRY_ADDRESS, mints nothing
#   MINT_ENV=<env file> bash stage_mint.sh --run    # mints, after the owner has confirmed FB and the inputs
#
# Needs: $OUT/engine/merged (publish_engine.sh --build made it; or set ENGINE_OV to a copy of the merged
# halves), $COMPILER_ZIP, $PATCH_ZIPS_DIR, and FLUTTER_PLATFORM (default $IN/flutter_platform_strong.dill,
# from the same ddm out dir as the compiler zip; build_compiler.sh writes it).
# Reads selfhost/ helpers from the checkout these scripts live in, or from HELPERS_REF (see README).
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); . "$HERE/lib.sh"; load_env; resolve_helpers
RUN=0; case "${1:-}" in --run) RUN=1;; "") ;; *) die "usage: $0 [--run]";; esac
export LC_ALL=C
ENGINE_OV=${ENGINE_OV:-$OUT/engine/merged}
FLUTTER_PLATFORM=${FLUTTER_PLATFORM:-$IN/flutter_platform_strong.dill}
EXPECT_MEMBERS=${EXPECT_MEMBERS:-30}
[[ -d "$ENGINE_OV" ]] || die "no engine overlay at $ENGINE_OV (run publish_engine.sh --build first, or set ENGINE_OV)"
for f in "$COMPILER_ZIP" "$FLUTTER_PLATFORM"; do [[ -f "$f" ]] || die "MISSING input $f"; done
RB=$HELPERS/selfhost/engine/route_b; POLICY=$HELPERS/selfhost/cdn/artifact_policy.conf
STAGE=$OUT/stage; OV=$OUT/ov-mint; EV=$OUT/evidence
for d in "$STAGE" "$OV" "$EV" "$OUT/dist" "$OUT/ci-stage" "$OUT/extras-tree"; do rm -rf "${d:?}"; done
mkdir -p "$OUT"
echo "$HELPERS_SHA" > "$OUT/helpers.sha"
export FLUTTER_PLATFORM
MINT_CELL_LIB_ONLY=1 . "$RB/mint_route_b_cell.sh"; set +e
src_for() { # member path with %H -> source file
  local m=$1 b; b=$(basename "$m")
  case "$b" in
    route-b-compiler-darwin-arm64.zip) echo "$COMPILER_ZIP"; return;;
    patch-*.zip) echo "$PATCH_ZIPS_DIR/$b"; return;;
  esac
  echo "$ENGINE_OV/${m//\%H/$E}"
}
n=0; miss=0
while IFS= read -r m; do
  n=$((n+1)); s=$(src_for "$m")
  [[ -f "$s" ]] || { echo "MISSING member source: $m  (looked for $s)"; miss=$((miss+1)); continue; }
  mkdir -p "$STAGE/$(dirname "$m")"
  case "$(basename "$m")" in
    engine_stamp.json)
      # The engine's stamp is compact JSON; the canonicalizer wants `"git_revision": "H"` (spaced). Re-dump spaced.
      # The canonicalizer picks its rule by basename, so the re-dump keeps the name engine_stamp.json.
      spd=$(mktemp -d); sp=$spd/engine_stamp.json
      python3 -I -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1]))),end="")' "$s" > "$sp" &&
      python3 -I "$RB/lib/v2_canonicalize.py" "$sp" "$E" > "$STAGE/$m" || { echo "CANON REFUSED $m"; exit 1; }
      rm -rf "$spd";;
    artifacts_manifest.yaml|*.pom)
      python3 -I "$RB/lib/v2_canonicalize.py" "$s" "$E" > "$STAGE/$m" || { echo "CANON REFUSED $m"; exit 1; };;
    *) cp "$s" "$STAGE/$m";;
  esac
done < <(v2_members "$POLICY" "$CELL")
echo "members: $n, missing: $miss"
[[ $miss == 0 ]] || { echo "STOP: $miss members have no source. Run prepare_inputs.sh and build_compiler.sh."; exit 1; }
[[ $n == "$EXPECT_MEMBERS" ]] || { echo "STOP: the policy lists $n members for $CELL, expected $EXPECT_MEMBERS (set EXPECT_MEMBERS if the policy changed on purpose)"; exit 1; }
MF=$OUT/cell_manifest.v2
v2_manifest "$STAGE" "$POLICY" "$CELL" "$FB" > "$MF" || { echo "STOP: v2_manifest failed"; exit 1; }
A=$(v2_address "$MF")
echo "DRY_ADDRESS $A (fallback $FB, engine $E)"
[[ $RUN == 1 ]] || { echo "dry run only; --run to mint"; exit 0; }
H=$(v2_transaction "$STAGE" "$POLICY" "$CELL" "$FB" "$OV" "$EV"); rc=$?
echo "MINT rc=$rc address=$H"; [[ $rc == 0 && "$H" == "$A" ]] || { echo "STOP: mint failed or address drift"; exit 1; }
# Extras: engine files that are not cell members, copied under the A path (same bytes).
# An extra whose bytes embed the engine hash is not rewritten: the host-extras list names only files that do not.
D=$OUT/dist; mkdir -p "$D" "$OUT/ci-stage" "$OUT/extras-tree"
( cd "$OV" && find . -type f | sed 's#^\./##' | sort ) > "$OUT/members.names"
( cd "$ENGINE_OV" && find . -type f | sed 's#^\./##' | sort ) | while read -r p; do
  q=${p//$E/$H}; grep -qxF "$q" "$OUT/members.names" && continue
  mkdir -p "$OUT/extras-tree/$(dirname "$q")"; cp -p "$ENGINE_OV/$p" "$OUT/extras-tree/$q"
done
( cd "$OUT/extras-tree" && find . -type f | sed 's#^\./##' | sort > "$OUT/extras.names" )
cp -Rp "$OUT/extras-tree/." "$OV/"          # cell overlay = members + extras
[[ -z "$(find "$OV" -name '._*' -print -quit)" ]] && echo "no AppleDouble files in the cell overlay" || { echo "STOP: AppleDouble (._*) files in $OV"; exit 1; }
( cd "$OV" && find . -type f | sed 's#^\./##' | sort > "$OUT/ci-stage/names" && xargs -I{} shasum -a 256 "{}" < "$OUT/ci-stage/names" > "$OUT/ci-stage/files.sha256" )
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -cf "$OUT/ci-stage/cell-$A.tar" -C "$OV" -T "$OUT/ci-stage/names"
( cd "$OUT/ci-stage" && shasum -a 256 "cell-$A.tar" > tar.sha )
cp "$OUT/ci-stage/cell-$A.tar" "$D/"; cp "$MF" "$D/cell_manifest.v2"; cp "$OUT/ci-stage/files.sha256" "$D/"
( cd "$D" && shasum -a 256 -- * > MANIFEST.sha256 )
echo "$A" > "$OUT/ADDRESS"; echo "BUNDLED: $D ($(wc -l < "$OUT/ci-stage/names" | tr -d ' ') files, $(wc -l < "$OUT/extras.names" | tr -d ' ') extras)"
