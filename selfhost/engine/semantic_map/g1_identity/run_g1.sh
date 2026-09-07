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

# RECOMPILATION, as its own G1 arm. An INDEPENDENT rebuild in a separate work
# directory, compared on the complete declaration-id set. G0's deterministic-dill
# result is supporting evidence, not a substitute for this.
W2="$W/independent"; mkdir -p "$W2"
( export CORPUS_BUILD_DIR="$W2/build"
  bash "$SM/g0_freeze/lib/build_corpus_dill.sh" "$G0C/base" "$W/base_rebuild.dill" >/dev/null 2>&1 )
if [[ -s "$W/base_rebuild.dill" ]]; then
  "$DART" --packages="$DT/.dart_tool/package_config.json" \
    "$HERE/lib/gen_declaration_ids.dart" --dill "$W/base_rebuild.dill" \
    --include package:corpus/ --out "$W/base_rebuild.json" >/dev/null 2>&1
fi

# OBFUSCATION, measured. The snapshots are built and the rename map saved, then
# the ids are recomputed from the SAME kernel so both halves are on the record.
OBFW="$W/obf"
bash "$HERE/lib/obfuscation_arm.sh" "$G0C/base" "$OBFW" >/dev/null 2>&1 || true
if [[ -s "$OBFW/obf.dill" ]]; then
  "$DART" --packages="$DT/.dart_tool/package_config.json" \
    "$HERE/lib/gen_declaration_ids.dart" --dill "$OBFW/obf.dill" \
    --include package:corpus/ --out "$W/base_obfuscated.json" >/dev/null 2>&1
fi
for d in "$G0C"/mutants/*; do ids_for "$d" "$(basename "$d")" || echo "  WARN could not build $(basename "$d")"; done
for d in "$XC"/*;            do ids_for "$d" "$(basename "$d")" || echo "  WARN could not build $(basename "$d")"; done

# KERNEL DOMAIN. Build the same source both ways so the tree-shaking arm can
# measure what --aot removes, rather than the map inheriting a silent choice.
SK="$W/shake"; mkdir -p "$SK/lib" "$SK/.dart_tool"
cp "$XC/ext_synthetic_members"/*.dart "$SK/lib/"
printf '{"configVersion":2,"packages":[{"name":"corpus","rootUri":"file://%s/","packageUri":"lib/","languageVersion":"3.9"}]}' "$SK" > "$SK/.dart_tool/package_config.json"
for mode in aot noaot; do
  if [[ "$mode" == aot ]]; then KF="--aot"; else KF="--no-aot --no-link-platform"; fi
  # shellcheck disable=SC2086
  "$DART" "$DT/pkg/vm/bin/gen_kernel.dart" --platform "$OUT/vm_platform.dill" $KF \
    --packages "$SK/.dart_tool/package_config.json" -o "$SK/$mode.dill" \
    package:corpus/app.dart >/dev/null 2>&1
  [[ -s "$SK/$mode.dill" ]] && "$DART" --packages="$DT/.dart_tool/package_config.json" \
    "$HERE/lib/gen_declaration_ids.dart" --dill "$SK/$mode.dill" \
    --include package:corpus/ --out "$W/shake_$mode.json" >/dev/null 2>&1
done

python3 "$HERE/lib/score_g1.py" "$W" "$G0C/EXPECTATIONS.json" "$HERE/EXPECTATIONS_EXT.json" \
  "$EVID/g1_identity.json" "$OBFW" | tee "$EVID/g1_identity.txt"
