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
SM="$(cd "$G/.." && pwd)"
PKG="--packages=$DT/.dart_tool/package_config.json"
INC="package:dynamic_modules/callsite_target.dart"
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
      "$W/subset.json" "$W/g1_regen.json" "$W/g3_rows.json" "$W/g4_rows.json" \
      "$W/refs_rows.json"

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
echo "############ 2. THE EVIDENCE CHAIN, REGENERATED ############"
cat <<'TXT'
  CORRECTION. An earlier version of this transcript said no checked-in script
  produces the G1 projection, privacy rows, retention rows or body-reference
  rows for this corpus. That was WRONG. All four producers are checked in and
  run; they had simply never been pointed at this library. They are regenerated
  here, so the prediction rests on produced evidence rather than on empty
  inputs standing in for missing ones.
TXT
echo
( cd "$W" && "$S/dart" $PKG "$SM/g2_fingerprints/lib/gen_map_rows.dart" \
    --dill release3.dill --pre-dill pre_r.dill --include "$INC" \
    --out g1_regen.json ) || { PRODUCER_FAILED="${PRODUCER_FAILED}g1; "; rc=1; }
( cd "$W" && "$S/dart" $PKG "$SM/g3_privacy/lib/gen_privacy_rows.dart" \
    --dill release3.dill --pre-dill pre_r.dill --include "$INC" \
    --out g3_rows.json ) || { PRODUCER_FAILED="${PRODUCER_FAILED}g3; "; rc=1; }
( cd "$W" && "$S/dart" $PKG "$SM/g4_retention/lib/gen_retention_rows.dart" \
    --dill release3.dill --enforcement "$SM/g4_retention/evidence/arms.json" \
    --include "$INC" --out g4_rows.json ) \
  || { PRODUCER_FAILED="${PRODUCER_FAILED}g4; "; rc=1; }
( cd "$W" && "$S/dart" $PKG "$G/lib/body_references.dart" \
    --dill release3.dill --include "$INC" --out refs_rows.json ) \
  || { PRODUCER_FAILED="${PRODUCER_FAILED}refs; "; rc=1; }
echo
echo "  the regenerated G1 projection must equal the banked copy BYTE FOR BYTE:"
if cmp -s "$W/g1_regen.json" "$G/evidence/g1_projection.json"; then
  echo "    equal  $(sha "$W/g1_regen.json")"
else
  echo "    DIFFERS"
  echo "      regenerated $(sha "$W/g1_regen.json")"
  echo "      banked      $(sha "$G/evidence/g1_projection.json")"
  rc=1
fi
echo
echo "############ 3. PREDICTION -- RELEASE EVIDENCE ONLY ############"
must predictor "$S/dart" "$G/lib/predict_patchable.dart" \
    --g2 "$W/g1_regen.json" --g3 "$W/g3_rows.json" --g4 "$W/g4_rows.json" \
    --refs "$W/refs_rows.json" \
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
echo "############ 4. DEMONSTRATION -- THE SHIPPING PATH ############"
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
echo "############ 4b. THE SAME SET, DERIVED WITHOUT A CALL-SITE MAP ############"
cat <<'TXT'
  The map above is parsed from the probe's _state(). A real application has no
  _state(), so that method does not generalise. This derives the same set from a
  SINGLE-TARGET DIFF instead: each container carries one target, so any change
  in the program's observable state is attributable to it.

      moved = fields whose value changed
      stale = fields still showing a value the patch moved elsewhere
      demonstrated = moved non-empty AND stale empty

  No field is named in advance, and the scorer RECOMPUTES the derivation from
  the recorded before/after state rather than trusting the row -- so deleting a
  stale site, with or without lowering the declared count, is refused.

  If an unrelated declaration coincidentally shares a moved-from value, its
  field is misread as a stale site of this target. That OVER-reports staleness,
  which withdraws a demonstration rather than manufacturing one. Only call
  sites exercised during the run are observed; that limit is reported, not
  implied.
TXT
echo
L="package:dynamic_modules/callsite_target.dart"
must derived-demonstration python3 "$G/lib/derive_demonstration.py" \
    "$S/dartaotruntime" "$SUBJ" "$W/g1_regen.json" "$W/derived.json" \
    "$L##method#alpha=$W/patch_alpha.sbrb" \
    "$L#Base#method#work=$W/patch_basework.sbrb" \
    "$L##method#smallTarget=$W/patch_smallTarget.sbrb" \
    "$L##method#tearOffTarget=$W/patch_tearOffTarget.sbrb"
echo
echo "  the two methods must agree, declaration by declaration:"
python3 - "$W/demonstrated.json" "$W/derived.json" <<'PY' | sed 's/^/  /'
import json, sys
h, d = (json.load(open(p)) for p in sys.argv[1:3])
def verdict(doc):
    out = {}
    for r in doc['rows']:
        sites = [s for s in r['call_sites'] if s.get('ordinary', True)]
        out[r['declaration_id']] = bool(sites) and all(s['moved'] for s in sites)
    return out
vh, vd = verdict(h), verdict(d)
for did in sorted(set(vh) | set(vd)):
    tag = 'agree' if vh.get(did) == vd.get(did) else 'DISAGREE'
    print(f"{did[:16]}  mapped={str(vh.get(did)):5} derived={str(vd.get(did)):5} {tag}")
print('ALL AGREE' if vh == vd else 'MISMATCH')
PY
echo
echo "############ 5. THE SUBSET CHECK ############"
must scorer python3 "$G/lib/score_subset.py" "$W/predictions.json" \
    "$W/demonstrated.json" "$W/subset.json"
echo
echo "############ 6. THE SCORER MUST BE ABLE TO FAIL ############"
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
echo "############ 7. CORPORA STILL OUTSTANDING ############"
cat <<'TXT'
  Phase D requires the adversarial corpus, Wonderous and LocalSend. Only the
  adversarial corpus is run here.

  The producer chain is NOT the blocker -- section 2 corrects that. Nor is the
  call-site map, any more: section 4b derives the same verdicts without one, so
  the method now generalises to a corpus that has no _state().

  What each app corpus still needs is its own release built through this exact
  toolchain -- a kernel compiled WITH --dynamic-interface, an AOT from the
  instrumented gen_snapshot, a generated dynamic interface, and patch
  containers for chosen targets -- plus some observable state to diff, and an
  exercise that actually reaches the targets. The observable state is the open
  design question for a GUI app: this probe prints a line, and Wonderous does
  not.

  Running them is not attempted and is NOT reported as passing.
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
want 'the G1 projection regenerates byte-identically' '' \
     "$(cmp -s "$W/g1_regen.json" "$G/evidence/g1_projection.json" || echo differs)"
want 'real privacy evidence reached the predictor' True \
     "$(python3 -c "import json;h=json.load(open('$W/predictions.json'))['refusal_histogram'];print(h.get('PRIVATE_TYPE_REFERENCE',0)>0)" 2>/dev/null)"
want 'real retention evidence reached the predictor' True \
     "$(python3 -c "import json;h=json.load(open('$W/predictions.json'))['refusal_histogram'];print(h.get('MISSING_CAN_BE_OVERRIDDEN',0)>0)" 2>/dev/null)"
want 'body-reference evidence was produced, not stubbed' 0 \
     "$(python3 -c "import json;h=json.load(open('$W/predictions.json'))['refusal_histogram'];print(h.get('BODY_REFERENCES_UNPROVEN',0))" 2>/dev/null)"
want 'route 2 actually reached the predictor' 2 \
     "$(python3 -c "import json;print(json.load(open('$W/predictions.json'))['refusal_histogram'].get('INLINED_BODY',0))" 2>/dev/null)"
python3 "$G/lib/falsify_subset.py" "$W/predictions.json" "$W/demonstrated.json" "$W" >/dev/null 2>&1
want 'the scorer fails on an injected over-claim and passes otherwise' 0 "$?"
want 'the falsification records SCORER_IS_SENSITIVE' 1 \
     "$(grep -c 'SM1_G5_SUBSET_FALSIFICATION: SCORER_IS_SENSITIVE' "$T")"
want 'the map-free derivation agrees with the mapped one' 1 \
     "$(grep -c '^  ALL AGREE' "$T")"
python3 "$G/lib/score_subset.py" "$W/predictions.json" "$W/derived.json" \
    "$W/subset_derived.json" >/dev/null 2>&1
want 'the subset holds on the derived demonstration too' 0 "$?"
python3 "$G/lib/falsify_subset.py" "$W/predictions.json" "$W/derived.json" "$W" >/dev/null 2>&1
want 'the scorer is sensitive on the derived demonstration too' 0 "$?"
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
