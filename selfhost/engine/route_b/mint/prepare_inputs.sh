#!/usr/bin/env bash
# prepare_inputs.sh -- put the engine extras in place before the compiler build and publish_engine.sh --build:
#   1. patch-{darwin-arm64,darwin-x64,linux-x64}.zip, carried from an earlier cell
#   2. analyze-snapshot-macos-{arm64,x64}, from the Mac stage
#   3. artifacts_manifest.yaml, written by selfhost/engine/generate_manifest.sh
# Everything lands in $ENGINE_EXTRA/download.shorebird.dev/shorebird/<E>/. Local only, except that step 3
# fetches BASE_MANIFEST when it is a URL (a public read).
#
#   MINT_ENV=<env file> bash prepare_inputs.sh          # PLAN
#   MINT_ENV=<env file> bash prepare_inputs.sh --run
#
# Patch zips: if $PATCH_ZIPS_DIR already holds the three, they are used. Otherwise PATCH_SOURCE_TAR (a
# cell tar that holds them, such as the previous cell's) is read. Either way each zip is checked against
# the digest in the previous cell's descriptor (selfhost/engine/route_b/cell_manifests/<PREV>.v2), because
# they are carried unchanged. Set PATCH_VERIFY=0 only when the patch tool really changed.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); . "$HERE/lib.sh"; load_env; resolve_helpers
RUN=0; case "${1:-}" in --run) RUN=1;; "") ;; *) die "usage: $0 [--run]";; esac
X=$ENGINE_EXTRA/download.shorebird.dev/shorebird/$E
ZIPS=(patch-darwin-arm64.zip patch-darwin-x64.zip patch-linux-x64.zip)
PREV=${PREV:-$(prev_from_caddyfile "$CDN_SRC/Caddyfile")}
DESC=$RB/cell_manifests/$PREV.v2
say "engine $E; extras $X; previous hash $PREV"
[[ -d $MAC_STAGE/shorebird/$E ]] || echo "NOTE: no $MAC_STAGE/shorebird/$E yet (the Mac build has not run); --run will stop here."
echo "patch zips: $PATCH_ZIPS_DIR (source tar: ${PATCH_SOURCE_TAR:-none}); descriptor $DESC"
echo "manifest: generate_manifest.sh --hash $E --base-manifest $BASE_MANIFEST --flutter-revision $E --dart-revision $DART --host darwin-arm64 --target $CELL"
[[ $RUN == 1 ]] || { echo "PLAN ONLY. Add --run."; exit 0; }

mkdir -p "$X" "$PATCH_ZIPS_DIR"
for z in "${ZIPS[@]}"; do
  if [[ ! -f $PATCH_ZIPS_DIR/$z ]]; then
    [[ -n ${PATCH_SOURCE_TAR:-} && -f ${PATCH_SOURCE_TAR} ]] || die "no $PATCH_ZIPS_DIR/$z and no PATCH_SOURCE_TAR to take it from"
    python3 -I - "$PATCH_SOURCE_TAR" "$z" "$PATCH_ZIPS_DIR/$z" <<'PY'
import sys, tarfile, shutil
tar, name, dst = sys.argv[1:]
with tarfile.open(tar) as t:
    m = [m for m in t.getmembers() if m.isfile() and m.name.split('/')[-1] == name]
    if len(m) != 1: sys.exit(f"STOP: {name} appears {len(m)} times in {tar}")
    with t.extractfile(m[0]) as src, open(dst, 'wb') as out: shutil.copyfileobj(src, out)
PY
  fi
  if [[ ${PATCH_VERIFY:-1} == 1 ]]; then
    [[ -f $DESC ]] || die "no descriptor $DESC to check $z against (set PATCH_VERIFY=0 to skip)"
    want=$(awk -v n="/%H/$z" 'index($1, n) {print $2}' "$DESC")
    [[ -n $want ]] || die "$z is not in $DESC"
    [[ "$(shasum -a 256 "$PATCH_ZIPS_DIR/$z" | cut -d' ' -f1)" == "$want" ]] || die "$z differs from the previous cell's (digest $want)"
  fi
  cp "$PATCH_ZIPS_DIR/$z" "$X/$z"
done
echo "patch zips ok"
for f in analyze-snapshot-macos-arm64 analyze-snapshot-macos-x64; do
  [[ -f $MAC_STAGE/shorebird/$E/$f ]] || die "no $MAC_STAGE/shorebird/$E/$f: the Mac build has not staged the analyze snapshots"
  cp "$MAC_STAGE/shorebird/$E/$f" "$X/$f"
done
bash "$HELPERS/selfhost/engine/generate_manifest.sh" --hash "$E" --base-manifest "$BASE_MANIFEST" --flutter-revision "$E" \
  --dart-revision "$DART" --host darwin-arm64 --target "$CELL" --out "$X/artifacts_manifest.yaml"
echo "Compare it with the previous engine's manifest: only the hash should differ."
echo PREPARE_INPUTS_DONE
