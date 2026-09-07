#!/usr/bin/env bash
# cspell:words semantic dill devirtualizes
# run_g1.sh -- SEMANTIC-MAP-1 / G1 (#50). Is the declaration identity stable
# under the things that actually move in a release, and does it move when the
# declaration itself does?
#
# INHERITED CONSTRAINTS, from the #50 authorization:
#   1. build from effective Dart tree 7b04b01b
#   2. pin the shipped analyzer 67741a08...
#   3. never derive identity from dill ordering or digest
#   4. include the deliberately index-derived identity as the positive control
#
# (3) is a property of the tool, not of this driver: lib/gen_declaration_ids.dart
# takes no position input. (4) is emitted alongside as `index_id`, and this
# driver REQUIRES it to fail the reorder case -- a harness that cannot catch an
# order-derived identity has said nothing about the canonical one.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SM="$(cd -- "$HERE/.." >/dev/null 2>&1 && pwd)"
SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
DT="$SRC/flutter/third_party/dart"
DART="$OUT/dart-sdk/bin/dart"
G0C="$SM/g0_freeze/corpus"
XC="$HERE/corpus_ext"
EVID="$HERE/evidence"; mkdir -p "$EVID"
W=${W:-${TMPDIR:-/tmp}/sm1_g1}
rm -rf "$W"; mkdir -p "$W"

# Constraint 1: the tree this runs against must be the frozen one.
EFF=$(python3 -c "import json;print(json.load(open('$SM/g0_freeze/freeze_manifest.json'))['inherited_lineage']['producing_source']['dart']['effective_tree'])")
[[ "$EFF" == "7b04b01bdc10ec990143257f0d28580571c2122f" ]] \
  || { echo "REFUSING: frozen effective tree is $EFF, not 7b04b01b" >&2; exit 2; }

ids_for() { # <corpus-dir> <label>
  local dir=$1 label=$2
  bash "$SM/g0_freeze/lib/build_corpus_dill.sh" "$dir" "$W/$label.dill" >/dev/null 2>&1 || return 1
  [[ -s "$W/$label.dill" ]] || return 1
  "$DART" --packages="$DT/.dart_tool/package_config.json" \
    "$HERE/lib/gen_declaration_ids.dart" --dill "$W/$label.dill" \
    --include package:corpus/ --out "$W/$label.json" >/dev/null 2>&1
}

echo "SM1-G1 declaration identity"
echo "  frozen effective tree : $EFF"
echo "  analyzer pin          : $(python3 -c "import json;print(json.load(open('$SM/g0_freeze/freeze_manifest.json'))['analyzer']['shipped_sha256'])")"
echo

ids_for "$G0C/base" base || { echo "could not produce base ids" >&2; exit 1; }
for d in "$G0C"/mutants/*; do ids_for "$d" "$(basename "$d")" || echo "  WARN could not build $(basename "$d")"; done
for d in "$XC"/*;            do ids_for "$d" "$(basename "$d")" || echo "  WARN could not build $(basename "$d")"; done

python3 "$HERE/lib/score_g1.py" "$W" "$G0C/EXPECTATIONS.json" "$HERE/EXPECTATIONS_EXT.json" \
  "$EVID/g1_identity.json" | tee "$EVID/g1_identity.txt"
