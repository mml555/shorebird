#!/usr/bin/env bash
# MAOT-T0 (#64) -- the universal patchability corpus and adversarial gate.
#
# Produces evidence/t0.json (the record), evidence/rows/<ROW>.json (per row),
# evidence/t0_adversarial.json (the controls) and evidence/t0.txt (this log).
# Exits non-zero on any blocking finding or any failed control.
#
# The row set comes from ../maot0/matrix.json. This harness keeps no second
# list, and the corpus check fails in BOTH directions.
#
#   usage: run_t0.sh
#   env:   DART_SDK=<path to a dart-sdk>   (optional; else Flutter's cache)
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
MATRIX="$HERE/../maot0/matrix.json"
EVID="$HERE/evidence"; mkdir -p "$EVID"
RAW="$EVID/t0.json"
CTRL="$EVID/t0_adversarial.json"
LOG_FILE="$EVID/t0.txt"
rm -f "$LOG_FILE"

{
echo "MAOT-T0 (#64) -- the universal patchability corpus and adversarial gate"
echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by run_t0.sh"
echo "repo revision $(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
echo
echo "############ 1. WHAT RUNS TODAY, AND WHAT DOES NOT ############"
cat <<'TXT'
  The Mutable-AOT mechanism does not exist yet -- #65 through #70 build it.
  So the `none` backend refuses every installation and every row reports
  UNMODELED. No row is PROVEN and none can be.

  What DOES run is real and already useful. Every executable fixture is
  compiled in both optimizer modes, executed cold and hot, and every dispatch
  mode's observation is checked against the value the fixture declares for the
  release program. That catches a fixture that does not compile, one that does
  not behave as declared, and one whose pre and post expectations are equal --
  which could never tell a patched program from an unpatched one.

  The ten false-positive paths #64 names are exercised against a mock backend
  through the SAME classifier the real run uses. A control that drove a
  parallel code path would measure that other path.
TXT
echo
echo "############ 2. THE CORPUS, AGAINST #63'S MATRIX ############"
} > "$LOG_FILE" 2>&1

python3 "$HERE/lib/corpus.py" "$HERE" "$MATRIX" >>"$LOG_FILE" 2>&1
CORPUS_RC=$?

{
echo
echo "############ 3. THE RUN ############"
} >> "$LOG_FILE"
python3 "$HERE/lib/gate_t0.py" "$HERE" "$MATRIX" "$RAW" >>"$LOG_FILE" 2>&1
GATE_RC=$?

{
echo
echo "############ 4. EVIDENCE IS REGENERATED, NOT MERGED ############"
cat <<'TXT'
  Deleted and corrupted row records must not survive a run. evidence/rows/ is
  cleared before every run and each record carries this run's id; a record
  stamped with any other run is refused. Proven here by destroying evidence
  and re-running, rather than by asserting the policy.
TXT
} >> "$LOG_FILE"

# Destructive regeneration test, in both directions: a deleted record and a
# corrupted one must both come back correct from source.
REGEN=unknown
ROWS="$EVID/rows"
if [[ -d "$ROWS" ]]; then
  BEFORE=$(ls "$ROWS" | wc -l | tr -d ' ')
  rm -f "$ROWS/EB-01.json"
  echo '{"schema":"corrupt","row_id":"EB-03","result":"PROVEN"}' > "$ROWS/EB-03.json"
  python3 "$HERE/lib/gate_t0.py" "$HERE" "$MATRIX" "$RAW" >/dev/null 2>&1
  REGEN_RC=$?
  AFTER=$(ls "$ROWS" | wc -l | tr -d ' ')
  EB3=$(python3 -c "
import json
d=json.load(open('$ROWS/EB-03.json'))
print(d.get('result'), d.get('schema'))" 2>/dev/null)
  if [[ "$BEFORE" == "$AFTER" && "$REGEN_RC" == "0" && "$EB3" == "UNMODELED maot.t0.row/1" ]]; then
    REGEN=regenerated
  else
    REGEN="FAILED before=$BEFORE after=$AFTER rc=$REGEN_RC eb3=$EB3"
  fi
fi
{
echo
echo "  deleted EB-01.json and replaced EB-03.json with a forged PROVEN record"
echo "  outcome: $REGEN"
echo
echo "############ 5. THE TEN ADVERSARIAL CONTROLS ############"
} >> "$LOG_FILE"

python3 "$HERE/lib/adversarial.py" "$HERE" "$MATRIX" "$CTRL" >>"$LOG_FILE" 2>&1
CTRL_RC=$?

echo >> "$LOG_FILE"
echo "############ 6. ASSERTIONS ############" >> "$LOG_FILE"

# A brace literal carrying a top-level comma is BRACE-EXPANDED by bash inside
# $(...), silently splitting one Python expression into several shell words.
# zsh does not do this, so the bug survives interactive testing and appears
# only under the CI shell. Refuse rather than produce wrong answers.
if grep -nE "\\$\\(([jc]) \"[^\"]*\\{[^}]*,[^}]*\\}" "$0" >/dev/null 2>&1; then
  echo "run_t0.sh contains a bash-expandable brace literal in a shell-passed" >&2
  echo "Python expression. Use set([...]) instead of {...}." >&2
  grep -nE "\\$\\(([jc]) \"[^\"]*\\{[^}]*,[^}]*\\}" "$0" >&2
  exit 2
fi

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
c() { python3 -c "
import json,sys
try: print(eval(sys.argv[1], {'d': json.load(open('$CTRL'))}))
except Exception: print('unreadable')" "$1"; }

want 'the corpus check ran clean' 0 "${CORPUS_RC:-1}"
want 'the gate ran' 0 "${GATE_RC:-1}"
want 'the record was written' 0 "$([[ -s "$RAW" ]] && echo 0 || echo 1)"
want 'no blocking finding stands' 0 \
     "$(j "sum(1 for f in d['findings'] if f['severity']=='blocking')")"

# --- the harness keeps no second list
want 'the row set comes from the matrix' \
     'maot0/matrix.json -- the harness keeps no second list' \
     "$(j "d['matrix_identity']['source']")"
want 'every in-scope matrix row has a fixture' True \
     "$(j "d['corpus']['fixtures_present'] == d['matrix_identity']['in_scope_rows']")"
want 'every in-scope matrix row has a result' True \
     "$(j "len(d['row_results']) == d['matrix_identity']['in_scope_rows']")"

# --- #64's minimum fixture families are executable, not placeholders
want "the minimum fixture families are executable" True \
     "$(j "set(d['corpus']['executable_fixtures']) >= set(['EB-01','EB-02','EB-03','EB-04','EB-05','EB-06','EB-07','EB-08','EB-11','EB-12','EB-13','EB-14','EB-15','EB-19'])")"
want 'every placeholder is explicit, never an absence' True \
     "$(j "len(d['corpus']['executable_fixtures']) + len(d['corpus']['placeholder_fixtures']) == d['matrix_identity']['in_scope_rows']")"

# --- modes
want 'both optimizer modes are supported' "['jit', 'aot']" \
     "$(j "d['corpus']['modes']['optimizer']")"
want 'both heat modes are supported' "['cold', 'hot']" \
     "$(j "d['corpus']['modes']['heat']")"
want 'the hot mode is actually hot' True \
     "$(j "d['corpus']['modes']['heat_iterations']['hot'] >= 10000")"
want 'every dispatch form is a mode of one row, not a row of its own' True \
     "$(j "set(['direct','virtual','interface','super','dynamic','tearoff_pre','tearoff_post']) == set(d['corpus']['modes']['dispatch'])")"
want 'the executable rows really ran in all four mode combinations' True \
     "$(python3 -c "
import json
d=json.load(open('$EVID/rows/EB-03.json'))
print(len(set([(o['optimizer_mode'],o['heat_mode']) for o in d['pre_observation']]))==4)")"

# --- the toolchain is named by revision, not by path
want 'the toolchain is identified by revision' True \
     "$(j "bool(d['toolchain'] and len(d['toolchain']['sdk_revision'])==40)")"

# --- honest state: nothing is proven, and the reason is named
want 'the aggregate refuses' NOT_PROVEN \
     "$(j "d['aggregate']['universal_dart_patchability']")"
want 'no row is proven' 0 "$(j "len(d['aggregate']['rows_proven'])")"
want 'every row is UNMODELED for a named reason' True \
     "$(j "set(d['aggregate']['result_counts']) == set(['UNMODELED'])")"
want 'no row failed for infrastructure reasons' 0 \
     "$(j "len(d['aggregate']['rows_infra_failed'])")"
want 'the backend in use is the real one, and says why it refuses' none \
     "$(j "d['mechanism_backend']['name']")"
want 'the verdict rule is a conjunction, not a threshold' True \
     "$(j "'every in-scope row' in d['aggregate']['verdict_rule'] and 'threshold' not in d['aggregate']['verdict_rule']")"
want 'counts are labelled diagnostic' True \
     "$(j "'DIAGNOSTIC' in d['aggregate']['diagnostic_only']")"

# --- evidence hygiene
want 'evidence regenerates after deletion and corruption' regenerated "$REGEN"
want 'every row record belongs to this run' True \
     "$(python3 -c "
import json,os,glob
d=json.load(open('$RAW'))
ids=set([json.load(open(p))['run_id'] for p in glob.glob('$EVID/rows/*.json')])
print(ids=={d['run_id']})")"

# --- the controls, in both directions
want 'every adversarial control passes' 0 "${CTRL_RC:-1}"
want 'all ten of #64 controls are present' True \
     "$(c "set(['A01','A02','A03','A04','A05','A06','A07','A08','A09','A10']) <= set([x['id'] for x in d['controls']])")"
want 'the mock double demonstrably works (else the controls are vacuous)' pass \
     "$(c "[x['result'] for x in d['controls'] if x['id']=='P0'][0]")"
want 'the verdict PROVEN is reachable by the shared classifier' pass \
     "$(c "[x['result'] for x in d['controls'] if x['id']=='P1'][0]")"
want 'a test double can never produce proof' pass \
     "$(c "[x['result'] for x in d['controls'] if x['id']=='P2'][0]")"
want 'a restart cannot make a run appear to pass' pass \
     "$(c "[x['result'] for x in d['controls'] if x['id']=='A09'][0]")"
want 'the rebuilt-program baseline cannot stand in for a patch' pass \
     "$(c "[x['result'] for x in d['controls'] if x['id']=='A09b'][0]")"

# --- the stop boundary: T0 builds a harness, not the mechanism
want 'no implementation subsystem is modified in the working tree' 0 \
     "$(git -C "$REPO" status --porcelain -- packages bin scripts \
        selfhost/engine/route_b selfhost/engine/route_b_di \
        selfhost/engine/dart-fork selfhost/engine/semantic_map \
        2>/dev/null | wc -l | tr -d ' ')"

{
  printf '%s\n' "${A[@]}"
  echo
  echo "ASSERTIONS (${#A[@]} checked: $(printf '%s\n' "${A[@]}" | grep -c '^  pass  ') pass, $(printf '%s\n' "${A[@]}" | grep -c '^  FAIL  ') fail)"
  echo
  echo "T0: $([[ "$rc" == 0 ]] && echo "HARNESS_ESTABLISHED / universal_dart_patchability=$(j "d['aggregate']['universal_dart_patchability']")" || echo GATE_FAILED)"
} >> "$LOG_FILE"

cat "$LOG_FILE"
echo "record:   $RAW"
echo "controls: $CTRL"
exit "$rc"
