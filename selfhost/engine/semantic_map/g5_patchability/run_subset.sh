#!/usr/bin/env bash
# SM1-G5 Phase D -- the mechanical subset check.
#
#     predicted patchable  SUBSET-OF  mechanically demonstrated patchable
#
# The two sides are produced by independent paths. Prediction reads release
# evidence only (G1 projection, privacy, retention, body references, release
# contract, Route-2 reader state). Demonstration applies each patch container
# with dartaotruntime and reads the program's own before/after output. Neither
# consults the other, and the scorer refuses a demonstration that declares
# itself predictor-derived.
#
# usage: run_subset.sh <clone-src> <workdir>
set -uo pipefail
SRC="${1:?usage: run_subset.sh <clone-src> <workdir>}"
W="${2:?usage: run_subset.sh <clone-src> <workdir>}"
G="$(cd "$(dirname "$0")" && pwd)"
S="$SRC/out/host_release_arm64"
DT="$SRC/flutter/third_party/dart"
SUBJ="$W/app_release.aot"
rc=0
ASSERTIONS=()
want() {
  if [ "$2" = "$3" ]; then ASSERTIONS+=("  pass  $1")
  else ASSERTIONS+=("  FAIL  $1 -- got '$3', expected '$2'"); rc=1; fi
}
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
must() {
  local what="$1"; shift
  "$@" || { echo "  PRODUCER FAILED: $what"; PRODUCER_FAILED="${PRODUCER_FAILED}$what; "; rc=1; return 1; }
}
PRODUCER_FAILED=""

[ -f "$SUBJ" ] || { echo "MISSING $SUBJ -- run run_route2.sh first"; exit 2; }
rm -f "$W/release_contract.json" "$W/predictions.json" "$W/demonstrated.json" \
      "$W/subset.json" "$W/empty_rows.json"
python3 -c "import json,sys;json.dump({'rows':[]},open(sys.argv[1],'w'))" "$W/empty_rows.json"

{
echo "SM1-G5 Phase D -- predicted patchable SUBSET-OF demonstrated patchable"
echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by run_subset.sh"
echo
echo "SUBJECT (the canonical release, taken not rebuilt)"
echo "  $(sha "$SUBJ")  app_release.aot"
echo "  $(sha "$G/evidence/g1_projection.json")  evidence/g1_projection.json"
echo "  $(sha "$G/evidence/inlining_state.json")  evidence/inlining_state.json"
echo
echo "############ 1. RELEASE CONTRACT, FROM THE RELEASE ITSELF ############"
must release-contract "$S/dart" --packages="$DT/.dart_tool/package_config.json" \
    "$G/lib/release_contract.dart" --dill "$W/release3.dill" --aot "$SUBJ" \
    --out "$W/release_contract.json"
python3 - "$W/release_contract.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  capability        {d['release_patch_capability']}")
print(f"  evidence          {d['release_patch_capability_evidence'][:64]}")
print(f"  release_aot_sha256 {d['release_aot_sha256']}")
print(f"  contract rows     {len(d['rows'])}")
PY
echo
echo "############ 2. PREDICTION -- RELEASE EVIDENCE ONLY ############"
cat <<'TXT'
  G3 privacy rows, G4 retention rows and body-reference rows DO NOT EXIST for
  this corpus -- no checked-in producer emits them for
  package:dynamic_modules/*. They are supplied as empty, which is not a
  convenience: the predictor treats a missing row as unproven and refuses. The
  run below is therefore a real end-to-end prediction whose refusals include
  "this evidence was never produced".
TXT
echo
must predictor "$S/dart" "$G/lib/predict_patchable.dart" \
    --g2 "$G/evidence/g1_projection.json" \
    --g3 "$W/empty_rows.json" --g4 "$W/empty_rows.json" \
    --refs "$W/empty_rows.json" \
    --release-contract "$W/release_contract.json" \
    --inlining-state "$G/evidence/inlining_state.json" \
    --out "$W/predictions.json"
python3 - "$W/predictions.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  declarations        {d['count']}")
print(f"  predicted patchable {d['predicted_patchable']}")
print("  refusal histogram:")
for k, v in sorted(d['refusal_histogram'].items(), key=lambda x: (-x[1], x[0])):
    print(f"    {v:3}  {k}")
PY
echo
echo "############ 3. DEMONSTRATION -- THE SHIPPING PATH ############"
must demonstration python3 "$G/lib/collect_demonstration.py" \
    "$S/dartaotruntime" "$SUBJ" "$G/evidence/g1_projection.json" \
    "$G/probe/callsite_target.dart" "$W/demonstrated.json" \
    "alpha=$W/patch_alpha.sbrb" "Base.work=$W/patch_basework.sbrb" \
    "smallTarget=$W/patch_smallTarget.sbrb" \
    "tearOffTarget=$W/patch_tearOffTarget.sbrb"
cat <<'TXT'

  A declaration counts demonstrated only when EVERY observed ordinary call site
  moved. Container parsing, attach success, a direct C++ invoke, predictor
  agreement and the absence of a bad machine-code shape are recorded for
  context and ignored by the scorer. The call-site map is parsed out of the
  probe's own _state(), and a printed field that no target maps and nothing
  excludes is a hard failure -- an unmapped call site is how a stale site would
  go unobserved.
TXT
echo
echo "############ 4. THE SUBSET CHECK ############"
must scorer python3 "$G/lib/score_subset.py" "$W/predictions.json" \
    "$W/demonstrated.json" "$W/subset.json"
echo
echo "############ 5. THE SCORER MUST BE ABLE TO FAIL ############"
cat <<'TXT'
  The subset property is trivially satisfied while nothing is predicted
  patchable, so the verdict alone carries no information. What carries
  information is that the scorer fails on an injected over-claim and stays PASS
  under merely reduced coverage.
TXT
echo
python3 "$G/lib/falsify_subset.py" "$W/predictions.json" "$W/demonstrated.json" "$W"
echo "exit=$?  (asserted: 0)"
echo
echo "############ 6. CORPORA STILL OUTSTANDING ############"
cat <<'TXT'
  Phase D requires the adversarial corpus, Wonderous and LocalSend. Only the
  adversarial corpus is run here.

  Wonderous and LocalSend checkouts exist under /Volumes/build/route-b, but the
  subset check needs, per corpus: a G1 projection, G3 privacy rows, G4
  retention rows and body-reference rows. NO CHECKED-IN SCRIPT PRODUCES ANY OF
  THEM -- not even for this 36-row probe, whose g2_r.json was a work-directory
  artifact now banked as evidence/g1_projection.json precisely because it could
  not be regenerated.

  So the blocker is a missing producer chain, not compute. Running the two app
  corpora is not attempted and is NOT reported as passing.
TXT
} > "$G/evidence/subset_check.txt" 2>&1

T="$G/evidence/subset_check.txt"
want 'no producer in this run failed' '' "$PRODUCER_FAILED"
want 'the release contract binds to the canonical subject' "$(sha "$SUBJ")" \
     "$(python3 -c "import json;print(json.load(open('$W/release_contract.json'))['release_aot_sha256'])" 2>/dev/null)"
want 'route 2 evidence is bound to the same artifact' \
     "$(python3 -c "import json;print(json.load(open('$W/release_contract.json'))['release_aot_sha256'])" 2>/dev/null)" \
     "$(python3 -c "import json;print(json.load(open('$G/evidence/inlining_state.json'))['diagnostics']['aot_sha256'])")"
want 'the subset property holds' SUBSET_HOLDS \
     "$(python3 -c "import json;print(json.load(open('$W/subset.json'))['verdict'])" 2>/dev/null)"
want 'route 2 actually reached the predictor' 2 \
     "$(python3 -c "import json;print(json.load(open('$W/predictions.json'))['refusal_histogram'].get('INLINED_BODY',0))" 2>/dev/null)"
python3 "$G/lib/falsify_subset.py" "$W/predictions.json" "$W/demonstrated.json" "$W" >/dev/null 2>&1
want 'the scorer fails on an injected over-claim and passes otherwise' 0 "$?"
want 'the falsification records SCORER_IS_SENSITIVE' 1 \
     "$(grep -c 'SM1_G5_SUBSET_FALSIFICATION: SCORER_IS_SENSITIVE' "$T")"
cp "$W/subset.json" "$G/evidence/subset.json"
cp "$W/demonstrated.json" "$G/evidence/demonstrated.json"
cp "$W/predictions.json" "$G/evidence/predictions.json"

{
  echo
  echo "ASSERTIONS (${#ASSERTIONS[@]} checked)"
  printf '%s\n' "${ASSERTIONS[@]}"
  echo
  echo "SM1_G5_SUBSET_BANK: $([ "$rc" = 0 ] && echo ADVERSARIAL_CORPUS_ONLY || echo FAILED)"
} >> "$T"
printf '%s\n' "${ASSERTIONS[@]}"
echo "SM1_G5_SUBSET_BANK: $([ "$rc" = 0 ] && echo ADVERSARIAL_CORPUS_ONLY || echo FAILED)"
exit "$rc"
