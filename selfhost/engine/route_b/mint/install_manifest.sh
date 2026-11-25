#!/usr/bin/env bash
# install_manifest.sh -- OWNER-RUN. Put cell_manifest.v2 at
# <overlay>/download.shorebird.dev/shorebird/cell-manifests/<A>.v2 on ci-build, where the CLI looks the
# cell up. publish_cell.sh --run calls it after install_on_ci.sh cell. It checks that the file's sha256
# starts with the address, never overwrites different bytes, then checks the mirror serves it from the overlay.
#
#   MINT_ENV=<env file> bash install_manifest.sh          # PLAN: local check only, no network
#   MINT_ENV=<env file> bash install_manifest.sh --run    # scp + ssh to ci-build
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); . "$HERE/lib.sh"; load_env
RUN=0; case "${1:-}" in --run) RUN=1;; "") ;; *) die "usage: $0 [--run]";; esac
[[ -f $OUT/ADDRESS ]] || die "no $OUT/ADDRESS: run stage_mint.sh --run first"
A=$(cat "$OUT/ADDRESS"); hex40 "address" "$A"; F=$OUT/dist/cell_manifest.v2
[[ $(shasum -a 256 "$F" | cut -c1-40) == "$A" ]] || die "$F does not hash to $A"
echo "cell manifest $F hashes to $A"
[[ $RUN == 1 ]] || { echo "PLAN ONLY. --run copies it to $CI_HOST:$CI_TMP and installs it in $CI_CDN/overlay."; exit 0; }
scp -q "$F" "$CI_HOST:$CI_TMP/cell_manifest-$A.v2"
ssh "$CI_HOST" bash -s -- "$A" "$CI_CDN" "$CI_TMP" <<'REMOTE'
set -euo pipefail
A=$1; OV=$2/overlay; S=$3/cell_manifest-$A.v2; D=$OV/download.shorebird.dev/shorebird/cell-manifests/$A.v2
[[ $(sha256sum "$S" | cut -c1-40) == "$A" ]] || { echo "STOP: copy does not hash to $A"; exit 1; }
if [[ -e $D ]]; then cmp -s "$S" "$D" || { echo "STOP: overlay has a different $D"; exit 1; }; echo "already installed"
else mkdir -p "$(dirname "$D")"; install -m 600 "$S" "$D"; echo "installed $D"; fi
rm -f "$S"
got=$(mktemp)
if curl -fsS -D - -o "$got" "http://localhost:8085/download.shorebird.dev/shorebird/cell-manifests/$A.v2" | tr -d '\r' | grep -qi '^x-overlay: hit' && cmp -s "$got" "$D"; then
  rm -f "$got"; echo "SERVED OK (cell manifest $A)"
else rm -f "$got"; echo "STOP: not served from the overlay"; exit 1; fi
REMOTE
