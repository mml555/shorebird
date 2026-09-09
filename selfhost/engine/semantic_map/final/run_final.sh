#!/usr/bin/env bash
# SM1-FINAL (#58) -- extract the matrix, compute the verdict, publish.
#
# This lane IMPLEMENTS NOTHING. It extracts every row from evidence, computes
# one verdict from the extracted matrix using #58's five-verdict vocabulary and
# precedence, digests every input it consumed, and generates RESULT.md from the
# same machine-readable artifacts.
#
# OUTPUTS ARE DELETED FIRST. A previous RESULT.md or manifest surviving a
# failed assembly would read as current output -- the stale-input class that
# has cost this programme several cycles. If any step fails, RESULT.md is
# REPLACED by a generated failure notice rather than left as it was.
#
# usage: run_final.sh <semantic-map-dir> [out-dir]
set -uo pipefail
SM="${1:?usage: run_final.sh <semantic-map-dir> [out-dir]}"
G="$(cd "$(dirname "$0")" && pwd)"
OUT="${2:-$G}"
SM="$(cd "$SM" && pwd)"
mkdir -p "$OUT/evidence"
MATRIX="$OUT/evidence/final_matrix.json"
VERDICT="$OUT/evidence/final_verdict.json"
MANIFEST="$OUT/evidence/provenance_manifest.json"
TRANSCRIPT="$OUT/evidence/final_assembly.txt"
RESULT="$OUT/RESULT.md"
rc=0
ASSERTIONS=()
want() {
  if [ "$2" = "$3" ]; then ASSERTIONS+=("  pass  $1")
  else ASSERTIONS+=("  FAIL  $1 -- got '$3', expected '$2'"); rc=1; fi
}

# DELETE BEFORE ASSEMBLING, not after a success check.
rm -f "$MATRIX" "$VERDICT" "$MANIFEST" "$TRANSCRIPT" "$RESULT"

{
echo "SM1-FINAL -- evidence matrix, computed verdict, provenance"
echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by run_final.sh"
echo "source tree $SM"
echo
echo "############ 1. THE MATRIX, EXTRACTED FROM EVIDENCE ############"
cat <<'TXT'
  Every row is derived at run time from a named file and field or marker. A row
  whose evidence cannot be resolved reads NOT_ESTABLISHED and is never filled
  from a remembered conclusion. SEMANTIC-LINKER-1's assembler returned
  ABANDON_OR_REDESIGN on its first run because two rows pointed at the wrong
  transcript; the fix was the pointer, not the check. That happened again here:
  PRIVACY_CROSS_DOMAIN_REFUSAL first read NOT_ESTABLISHED because it was bound
  to G5/G6's marker convention, which G3 predates.
TXT
echo
python3 "$G/lib/extract_matrix.py" "$SM" "$G/evidence_registry.json" "$MATRIX"
EXTRACT_RC=$?
echo
echo "############ 2. THE VERDICT, COMPUTED FROM THE MATRIX ############"
cat <<'TXT'
  No verdict is seeded. Every predicate below is evaluated against row
  CATEGORIES and generated gap data, and all of them are published -- not only
  the one that selected -- so the decision surface is visible. If no predicate
  holds the verdict is NOT_ESTABLISHED: #58 forbids a generic FAIL, and
  inventing one of the five to fill the hole would be worse than saying the
  matrix does not classify.
TXT
echo
python3 "$G/lib/compute_verdict.py" "$MATRIX" "$VERDICT"
VERDICT_RC=$?
echo
echo "############ 3. PROVENANCE ############"
cat <<'TXT'
  The input set comes from the extractor's access log -- the files it actually
  opened, digested at read time -- cross-checked against the registry. A file a
  row names but the extractor never opened, or vice versa, is a finding. This
  manifest does not digest itself, RESULT.md, the matrix or the verdict: they
  are outputs of this assembly. G5 once produced a manifest that included its
  own output, and a second run never reproduced the first.
TXT
echo
python3 "$G/lib/build_manifest.py" "$SM" "$G/evidence_registry.json" \
    "$MATRIX" "$VERDICT" "$G" "$MANIFEST"
MANIFEST_RC=$?
echo
echo "############ 4. RESULT.md, GENERATED FROM THOSE ARTIFACTS ############"
python3 "$G/lib/gen_result.py" "$MATRIX" "$VERDICT" "$MANIFEST" "$RESULT"
RESULT_RC=$?
echo
echo "############ 5. SENSITIVITY CONTROLS ############"
cat <<'TXT'
  The published verdict is only worth something if a DIFFERENT verdict was
  reachable. Family B drives the computation to each of the five allowed
  verdicts in turn, and to NOT_ESTABLISHED, from a described state of the
  evidence. Family A removes and corrupts every row's evidence in turn.
  Family C proves the arms discriminate, by showing a weakened assembler that
  hard-codes the baseline satisfies exactly one family-B arm -- the baseline's
  own -- and no other. Family D runs this orchestrator against damaged
  evidence and checks what RESULT.md then says.
TXT
echo
# NESTED GUARD. Family D of the controls runs this orchestrator against
# damaged evidence. Without the guard that nested run re-entered the
# controls, and the nested falsifier reused the SAME workdir -- wiping the
# outer control's scratch tree while it was still being measured, so three
# degraded-path arms read a healthy RESULT.md and "failed" for a reason that
# had nothing to do with the assembler. A control may not re-enter the thing
# it is controlling.
if [ "${SM1_FINAL_NESTED:-0}" = 1 ]; then
  echo "  SKIPPED: nested invocation (SM1_FINAL_NESTED=1)."
  echo "  A nested run exists only to be measured by family D. It can never"
  echo "  be presented as this lane's result: the verdict line below is"
  echo "  NESTED_INVOCATION_NO_CONTROLS regardless of how the stages went."
  SENS_RC=skipped
else
  python3 "$G/lib/falsify_final.py" "$SM" "$G" \
      "${TMPDIR:-/tmp}/sm1_final_neg"
  SENS_RC=$?
fi
} > "$TRANSCRIPT" 2>&1
cat "$TRANSCRIPT"

# If any stage failed, RESULT.md must say so rather than be absent or stale.
if [ "${EXTRACT_RC:-1}" != 0 ] || [ "${VERDICT_RC:-1}" != 0 ] \
   || [ "${MANIFEST_RC:-1}" != 0 ] || [ "${RESULT_RC:-1}" != 0 ]; then
  rm -f "$RESULT"
  {
    echo "# SEMANTIC-MAP-1 -- FINAL: ASSEMBLY FAILED"
    echo
    echo "Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by run_final.sh."
    echo
    echo "This assembly did not complete, so there is no current matrix or"
    echo "verdict. Any previous RESULT.md was deleted rather than left in"
    echo "place: a stale report that still reads as current output is worse"
    echo "than no report."
    echo
    echo "    extract_matrix   exit ${EXTRACT_RC:-unrun}"
    echo "    compute_verdict  exit ${VERDICT_RC:-unrun}"
    echo "    build_manifest   exit ${MANIFEST_RC:-unrun}"
    echo "    gen_result       exit ${RESULT_RC:-unrun}"
  } > "$RESULT"
fi

jj() { :; }
j() { python3 -c "
import json,sys
try: print(eval(sys.argv[1], {'d': json.load(open('$1'))}))
except Exception: print('unreadable')" "$2"; }

want 'the matrix extracted' 0 "${EXTRACT_RC:-1}"
want 'every declared row is present' \
     "$(python3 -c "
import json;print(len(json.load(open('$G/evidence_registry.json'))['rows']) + 1)")" \
     "$(j "$MATRIX" "len(d['matrix'])")"
want 'no row is NOT_ESTABLISHED' 0 "$(j "$MATRIX" "len(d['not_established'])")"
# The positive-category set lived in two places and drifted, so a positive
# finding (DECIDABLE_EXCLUSIONS = NAMED_AND_FAIL_CLOSED) was simultaneously
# counted as positive by the classifier and listed as a known GAP by the
# extractor. Both now read one definition in the registry; this asserts the
# consequence directly rather than trusting the wiring.
want 'no positive row is also listed as a known gap' 0 \
     "$(python3 -c "
import json
d=json.load(open('$MATRIX'))
pos=set(d['positive_categories'])
gaps={e['id'] for e in d['matrix']['KNOWN_GAPS']['entries']
      if e['source']=='matrix'}
print(len([r for r,v in d['matrix'].items()
           if v['category'] in pos and r in gaps]))")"
want 'the positive set came from the registry' True \
     "$(python3 -c "
import json
reg=json.load(open('$G/evidence_registry.json'))['positive_categories']['categories']
got=json.load(open('$MATRIX'))['positive_categories']
print(sorted(reg)==sorted(got))")"
want 'every positive category is in the declared vocabulary' 0 \
     "$(python3 -c "
import json
reg=json.load(open('$G/evidence_registry.json'))
print(len([c for c in reg['positive_categories']['categories']
           if c not in reg['category_vocabulary']]))")"
want 'every evidence file was readable' 0 \
     "$(j "$MATRIX" "len([k for k,v in d['access_log'].items() if not v['read']])")"
want 'the verdict computed' 0 "${VERDICT_RC:-1}"
want 'the verdict is one of the five allowed' True \
     "$(j "$VERDICT" "d['verdict'] in d['allowed_verdicts']")"
want 'the verdict was selected by a named predicate' True \
     "$(j "$VERDICT" "d['selected_by_predicate'] is not None")"
want 'exactly one ladder rung selected' 1 \
     "$(j "$VERDICT" "sum(1 for t in d['ladder_trace'] if t['selected'])")"
# The ORDER is asserted, not just the outcome. #58's precedence begins with
# MODIFY_ANALYZER and PROCEED is the fall-through; an earlier version put
# PROCEED first, which would ship over a known analyzer bug.
want "the ladder follows #58's precedence order" \
     'MODIFY_ANALYZER MODIFY_MAP_DESIGN REDUCE_SCOPE ABANDON_OR_REDESIGN PROCEED' \
     "$(j "$VERDICT" "' '.join(t['verdict'] for t in d['ladder_trace'])")"
want 'the selected rung is the FIRST true one' True \
     "$(python3 -c "
import json
t=json.load(open('$VERDICT'))['ladder_trace']
first=next((i for i,x in enumerate(t) if x['value']), None)
sel=next((i for i,x in enumerate(t) if x['selected']), None)
print(first == sel)")"
# STRUCTURAL, NOT TEXTUAL. The first version of these four asserted that a
# predicate's prose mentioned the right names -- `'NAMED_...' in p['from']` --
# which would pass unchanged if the predicate itself were rewritten and only
# the comment left behind. Each now compares published VALUES, so a predicate
# that stopped being the conjunction it claims to be fails here.
want 'each rung predicate is the conjunction it claims' 'True True True' \
     "$(python3 "$G/lib/_check_predicates.py" "$VERDICT")"
want 'PROCEED and REDUCE_SCOPE are mutually exclusive by construction' True \
     "$(python3 -c "
import json
P=json.load(open('$VERDICT'))['predicates']
print(not (P['ADMITTED_SET_IS_PROPER_SUBSET']['value']
           and P['ADMITTED_SET_IS_TOTAL']['value']))")"
want 'every predicate is published' True \
     "$(j "$VERDICT" "len(d['predicates']) >= len(d['ladder_trace'])")"
want 'the provenance manifest built' 0 "${MANIFEST_RC:-1}"
want 'every consumed input carries a digest' 0 \
     "$(j "$MANIFEST" "len([k for k,v in d['consumed_evidence'].items() if not v['sha256']])")"
want 'the input set equals the declared set' True \
     "$(j "$MANIFEST" "d['coverage']['equal']")"
want 'the manifest reports no findings' 0 \
     "$(j "$MANIFEST" "len(d['findings'])")"
want 'the manifest does not digest its own outputs' True \
     "$(python3 -c "
import json
d=json.load(open('$MANIFEST'))
outs=set(d['outputs_not_digested'])
keys=set(d['consumed_evidence']) | set(d['producing_scripts']) | set(d['assembler'])
print(not (outs & keys))")"
want 'RESULT.md generated' 0 "${RESULT_RC:-1}"
want 'RESULT.md is machine-generated, not authored' 1 \
     "$(grep -c 'GENERATED by final/lib/gen_result.py' "$RESULT" 2>/dev/null || echo 0)"
want 'RESULT.md carries the computed verdict' 1 \
     "$(grep -cx "    $(j "$VERDICT" "d['verdict']")" "$RESULT" 2>/dev/null || echo 0)"
want 'RESULT.md enumerates the non-proven claims' True \
     "$(python3 -c "
import json
n=len(json.load(open('$VERDICT'))['non_proven_claims'])
body=open('$RESULT').read()
print(body.count('\n- ') >= n)")"
if [ "${SM1_FINAL_NESTED:-0}" = 1 ]; then
  ASSERTIONS+=("  note  sensitivity controls SKIPPED -- nested invocation")
else
  want 'the sensitivity controls discriminate' 0 "${SENS_RC:-1}"
  # The nested guard exists for family D only. If it were set for a real run
  # the controls would be skipped, so a published transcript must never carry
  # the nested marker and RESULT.md must never be the failure notice.
  want 'this run is not a control-free nested invocation' 0 \
       "$(grep -c 'NESTED_INVOCATION_NO_CONTROLS' "$TRANSCRIPT")"
  want 'RESULT.md is a report, not a failure notice' 0 \
       "$(grep -c 'ASSEMBLY FAILED' "$RESULT")"
  want 'the published matrix is complete, so no PROVISIONAL verdict' 0 \
       "$(grep -c 'PROVISIONAL' "$RESULT")"
fi

if [ "${SM1_FINAL_NESTED:-0}" = 1 ]; then
  FINAL_LINE=NESTED_INVOCATION_NO_CONTROLS
elif [ "$rc" = 0 ]; then
  FINAL_LINE="$(j "$VERDICT" "d['verdict']")"
else
  FINAL_LINE=ASSEMBLY_INCOMPLETE
fi

{
  echo
  echo "ASSERTIONS (${#ASSERTIONS[@]} checked)"
  printf '%s\n' "${ASSERTIONS[@]}"
  echo
  echo "SM1_FINAL: $FINAL_LINE"
} >> "$TRANSCRIPT"
printf '%s\n' "${ASSERTIONS[@]}"
echo "SM1_FINAL: $FINAL_LINE"
exit "$rc"
