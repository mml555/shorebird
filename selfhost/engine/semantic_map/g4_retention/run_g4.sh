#!/usr/bin/env bash
# cspell:words dartaotruntime dill bytecode dynmod
# run_g4.sh -- SEMANTIC-MAP-1 / G4 (#53). Retention contract and measured cost.
#
# INHERITED, from G0-G3 acceptance:
#   * build from effective Dart tree 7b04b01b (refused otherwise)
#   * the transcript and the JSON come from ONE invocation -- G2 learned this
#     the hard way, so this script writes its own transcript
#   * FAIL_OPEN is a first-class result and is never collapsed into pass/fail
#
# THE CONFOUND RUNS FIRST AND IS FATAL. `@pragma('vm:entry-point')` retains a
# symbol independently of the contract, and worse, di.yaml's `callable:` lowers
# to `@pragma('dyn-module:callable')` which `pragma.dart` routes through the SAME
# handler as `vm:entry-point`. So "retained by the contract" and "retained by a
# pragma" are indistinguishable at load unless the subject is proven clean.
#
# NO INSTRUMENT IS USED. SL1 read execution mode with `functionExecutionMode`,
# but that is a banked patch present only in the SL1 lane build; the frozen map
# lineage does not export it and adding one is outside this gate's boundary.
# Retention is measured behaviourally, through mechanisms the frozen lineage
# actually ships.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SM="$(cd -- "$HERE/.." >/dev/null 2>&1 && pwd)"
SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
DT=${DT:-$SRC/flutter/third_party/dart}
DART="$OUT/dart-sdk/bin/dart"
EVID="$HERE/evidence"; mkdir -p "$EVID"
TRANSCRIPT="$EVID/g4_retention.txt"
W=${W:-${TMPDIR:-/tmp}/sm1_g4}

{
rm -rf "$W"; mkdir -p "$W"

EFF=$(python3 -c "import json;print(json.load(open('$SM/g0_freeze/freeze_manifest.json'))['inherited_lineage']['producing_source']['dart']['effective_tree'])")
[[ "$EFF" == "7b04b01bdc10ec990143257f0d28580571c2122f" ]] \
  || { echo "REFUSING: frozen effective tree is $EFF, not 7b04b01b" >&2; exit 2; }
echo "SM1-G4 retention contract and measured cost"
echo "  frozen effective tree : $EFF"
echo "  substrate             : $OUT"
echo "  dynamic modules       : $(grep -h dart_dynamic_modules "$OUT/args.gn" 2>/dev/null | tr -d ' ' || echo UNKNOWN)"

echo
echo "--- CONFOUND FIRST: retention must be attributable to the contract ---"
bash "$HERE/lib/assert_no_retaining_pragma.sh" 2>&1 | tee "$EVID/confound_pragma.txt" | sed 's/^/  /'
if ! grep -q 'PRAGMA_CONFOUND=CONTROLLED' "$EVID/confound_pragma.txt"; then
  echo
  echo "  REFUSING TO SCORE. Retention is not attributable to the contract, so"
  echo "  every arm below would be measuring the pragma instead. Fatal rather"
  echo "  than a finding: the two mechanisms are indistinguishable at load."
  echo
  echo "SUMMARY checks_failed=1"
  echo "G4 RETENTION FAILED"
  exit 1
fi

echo
echo "--- ARMS: withhold each retention class in turn ---"
bash "$HERE/lib/run_arms.sh" "$EVID/arms.json" 2>&1 | sed 's/^/  /'

echo
echo "--- COST CURVE: measured at release scale, not extrapolated ---"
if [[ -s "$EVID/scale.json" && -z "${REMEASURE:-}" ]]; then
  echo "  reusing $EVID/scale.json (set REMEASURE=1 to rebuild the curve)"
else
  bash "$HERE/lib/measure_scale.sh" "$EVID/scale.json" | tee "$EVID/scale_curve.txt" | sed 's/^/  /'
fi
sed 's/^/  /' "$EVID/scale_curve.txt"

echo
echo "--- RETENTION CONTRACT, per declaration, over the frozen corpus ---"
bash "$SM/g0_freeze/lib/build_corpus_dill.sh" "$SM/g0_freeze/corpus/base" "$W/base.dill" >/dev/null 2>&1 \
  || { echo "could not build the corpus dill" >&2; exit 1; }
"$DART" --packages="$DT/.dart_tool/package_config.json" "$HERE/lib/gen_retention_rows.dart" \
  --dill "$W/base.dill" --enforcement "$EVID/arms.json" \
  --include package:corpus/ --out "$EVID/retention_rows.json" 2>&1 | sed 's/^/  /'

echo
python3 "$HERE/lib/score_g4.py" "$HERE" "$HERE/EXPECTATIONS_G4.json" \
  "$EVID/g4_retention.json" "$EVID/confound_pragma.txt"
} 2>&1 | tee "$TRANSCRIPT"
exit "${PIPESTATUS[0]}"
