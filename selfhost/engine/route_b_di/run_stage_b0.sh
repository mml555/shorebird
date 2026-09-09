#!/usr/bin/env bash
# ROUTE-B-DI-1 / STAGE B0 (#61) -- derive the production validation input, or
# classify VALIDATION_INPUT_UNDERIVED and stop.
#
# #61's hard boundary: nothing in Route B may be modified until B0 succeeds.
# This script MEASURES rather than reads. It runs Route B's own release-bound
# generator on a real kernel, hands the result to the real validator with a
# valid module, and records what happened.
#
# Route B is not modified. The generator is invoked, not edited.
#
# usage: run_stage_b0.sh [out-dir]
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
OUTDIR="${1:-$HERE}"
REPO="$(cd "$HERE/../../.." && pwd)"
LANE=${LANE:-/Volumes/build/semantic-linker/sl1}
ARM=${ARM:-g3_on}
SRC="$LANE/flutter/engine/src"
OUT="$SRC/out/sl1_$ARM"
DART_TREE="$SRC/flutter/third_party/dart"
GK="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
D2B="$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart"
DART="$OUT/dart-sdk/bin/dart"
GEN="$REPO/selfhost/engine/route_b/gen_dynamic_interface.dart"
FREEZE="$REPO/selfhost/engine/semantic_linker/runtime_feasibility/g0_freeze/freeze_manifest.json"
EVID="$OUTDIR/evidence"; mkdir -p "$EVID"
RAW="$EVID/stage_b0.json"
LOGF="$EVID/stage_b0.txt"
rm -f "$RAW" "$LOGF"

[[ -d "$OUT" ]] || { echo "no build at $OUT" >&2; exit 2; }
[[ -f "$GEN" ]] || { echo "no generator at $GEN" >&2; exit 2; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/lib" "$W/.dart_tool"
cp "$HERE/probe/n_host.dart" "$W/lib/"
cp "$HERE"/probe/m_*.dart "$W/"
cat > "$W/.dart_tool/package_config.json" <<JSON
{"configVersion":2,"packages":[{"name":"dynamic_modules","rootUri":"file://$W/","packageUri":"lib/","languageVersion":"3.9"}]}
JSON
URI=package:dynamic_modules/n_host.dart

{
echo "ROUTE-B-DI-1 / Stage B0 -- the production validation input"
echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by run_stage_b0.sh"
echo "generator $GEN"
echo
echo "############ 1. THE RELEASE'S OWN SPECIFICATION, GENERATED ############"
cat <<'TXT'
  Route B does not hand-write its dynamic interface. It generates one from the
  release's own kernel with gen_dynamic_interface.dart under a named --policy,
  which is exactly the deterministic release-bound source B0 asks for. So the
  question is not whether a specification can be derived -- it is whether the
  derived one is COMPLETE as a MODULE-VALIDATION specification.
TXT
echo
"$DART" "$GK" --platform "$OUT/vm_platform.dill" --no-aot --no-link-platform \
  --packages "$W/.dart_tool/package_config.json" -o "$W/gen_in.dill" "$URI" \
  2>&1 | tail -2 | sed 's/^/  /'
echo "  release kernel: $(wc -c < "$W/gen_in.dill" 2>/dev/null || echo 0) bytes"
"$DART" --packages="$DART_TREE/.dart_tool/package_config.json" "$GEN" \
  --dill "$W/gen_in.dill" --out "$W/di_generated.yaml" 2>&1 \
  | tail -8 | sed 's/^/  /'
GEN_RC=${PIPESTATUS[0]}
echo "  generator exit=$GEN_RC"
echo
echo "  what it emitted (comments stripped):"
grep -v '^#' "$W/di_generated.yaml" 2>/dev/null | sed 's/^/    /'
echo
echo "############ 2. THAT SPECIFICATION, HANDED TO THE VALIDATOR ############"
cat <<'TXT'
  The same valid module Stage A used, compiled with --validate pointed at the
  release's OWN generated specification. If the release's specification cannot
  validate the release's own intended patch, it is not a validation input.
TXT
echo
"$DART" "$GK" --platform "$OUT/vm_platform.dill" --no-aot --no-link-platform \
  --packages "$W/.dart_tool/package_config.json" -o "$W/import.dill" "$URI" \
  >/dev/null 2>&1
"$DART" "$D2B" --platform "$OUT/vm_platform.dill" \
  --import-dill "$W/import.dill" --validate "$W/di_generated.yaml" \
  -o "$W/m.bytecode" "$W/m_ok.dart" > "$W/attempt.log" 2>&1
ATTEMPT_RC=$?
if [[ -s "$W/m.bytecode" ]]; then
  echo "produced=yes" >> "$W/attempt.log"
else
  echo "produced=no" >> "$W/attempt.log"
fi
echo "  module compile exit=$ATTEMPT_RC  produced=$([[ -s "$W/m.bytecode" ]] && echo yes || echo no)"
echo
grep 'Error:' "$W/attempt.log" | sed "s|^.*/m_ok.dart|    m_ok.dart|" | head -10
echo
echo "############ 3. IS A COMPLETE SPECIFICATION DERIVABLE? ############"
python3 "$HERE/lib/derive_validation_input.py" "$W/di_generated.yaml" \
    "$W/attempt.log" "$REPO" "$FREEZE" "$RAW"
B0_RC=$?
echo
echo "############ 3b. THE B0 CLASSIFIER, FALSIFIED ############"
cat <<'TXT'
  VALIDATION_INPUT_UNDERIVED stops this issue. A classifier that reported it
  regardless of input would stop #61 for no reason, and one that reported
  DERIVABLE regardless would send B1 at Route B on no evidence. Both
  directions get negatives.
TXT
echo
python3 "$HERE/lib/falsify_b0.py" "$HERE/lib/derive_validation_input.py" \
    "$REPO" "$FREEZE" "$W/b0neg"
B0NEG_RC=$?
echo
echo "############ 4. ASSERTIONS ############"
} > "$LOGF" 2>&1

rc=0
A=()
want() {
  if [[ "$2" == "$3" ]]; then A+=("  pass  $1")
  else A+=("  FAIL  $1 -- got '$3', expected '$2'"); rc=1; fi
}
j() { python3 -c "
import json,sys
try: print(eval(sys.argv[1], {'d': json.load(open('$RAW'))}))
except Exception: print('unreadable')" "$1"; }

want 'the release generator ran' 0 "${GEN_RC:-1}"
want 'a specification was generated' True "$(j "bool(d['provenance_available'].get('specification_sha256'))")"
want 'the B0 record was written' 0 "$([[ -s "$RAW" ]] && echo 0 || echo 1)"
want 'the four required sections are named' 4 "$(j "len(d['sections_required'])")"
want 'the module itself is rejected as a source' False \
     "$(j "d['candidate_sources']['the_module_itself']['usable']")"
want 'the semantic map cannot supply the surface' 0 \
     "$(j "d['candidate_sources']['semantic_map_admitted_set']['admitted']")"
want 'no release-side permission policy is declared' False \
     "$(j "d['candidate_sources']['declared_release_policy']['exists']")"
want 'the derivation identity is digested' True \
     "$(j "bool(d['provenance_available'].get('derivation_identity'))")"
want 'the Dart identity is recorded' True \
     "$(j "bool(d['provenance_available'].get('dart_effective_tree'))")"
want 'the finding is about the input, not the mechanism' True \
     "$(j "'not the mechanism' in d['does_not_claim']")"
want 'experiment fixtures are not counted as release policy' 4 \
     "$(j "len(d['candidate_sources']['declared_release_policy']['excluded_as_experiment_fixtures'])")"
want 'the B0 classifier is falsified' 0 "${B0NEG_RC:-1}"
{
  printf '%s\n' "${A[@]}"
  echo
  echo "ASSERTIONS (${#A[@]} checked: $(printf '%s\n' "${A[@]}" | grep -c '^  pass  ') pass, $(printf '%s\n' "${A[@]}" | grep -c '^  FAIL  ') fail)"
  echo
  echo "STAGE_B0: $([[ "$rc" == 0 ]] && j "d['b0_result']" || echo B0_INCOMPLETE)"
} >> "$LOGF"
cat "$LOGF"
echo "record:     $RAW"
exit "$rc"
