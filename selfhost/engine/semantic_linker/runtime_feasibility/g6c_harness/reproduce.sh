#!/usr/bin/env bash
# cspell:words dartaotruntime dill semantic linker devirtualization nodm KBC
# reproduce.sh -- SEMANTIC-LINKER-1 / G6C. One command that reproduces the whole
# evidence set, fail-closed.
#
# WHAT THIS HARNESS IS FOR, and it is not "make everything exit zero".
# The property under test is that the EVIDENCE AND THE FINDINGS reproduce. Two
# rules are therefore enforced in code rather than described in prose:
#
#   1. KNOWN FAIL-OPEN NEGATIVES STAY FAIL-OPEN. G6A found five failure modes
#      that do not fail closed. A clean run reproduces them faithfully -- and the
#      schema has no way to render that as a green safety result. `verdict` is
#      computed, and it cannot be PASS while `fail_open_findings` is non-empty.
#   2. THE UNRESOLVED PREREQUISITE IS STRUCTURED DATA. Module-side
#      dynamic-interface validation is emitted as a machine-readable entry in
#      `unresolved_prerequisites` for #46 to consume, not as a line in a log.
#
#   reproduce.sh [--mode full|reuse] [--iters N] [--reps N]
#
#     report-only
#            re-emits the structured result from evidence already on disk. It
#            runs no gate and cannot manufacture one; the record it writes is
#            stamped `regenerated_from_evidence`. falsify.sh uses this mode to
#            prove the reporting path REFUSES missing or mutated evidence.
#     full   (default) rebuilds every engine configuration from the banked
#            frozen source. This is the authoritative mode; it takes ~1 hour.
#     reuse  verifies existing build identities against the recorded manifests
#            instead of rebuilding. Faster, and the run is STAMPED as reused --
#            it is not a clean reproduction and the output says so.
#
# Exit: 0 evidence complete · 1 a required result missing/mutated · 2 environment
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
RF="$(cd -- "$HERE/.." >/dev/null 2>&1 && pwd)"
REPO="$(cd -- "$RF/../../../.." >/dev/null 2>&1 && pwd)"
LANE=${LANE:-/Volumes/build/semantic-linker/sl1}
SRC="$LANE/flutter/engine/src"
EVID="$HERE/evidence"; mkdir -p "$EVID"
LOG="$EVID/reproduce.txt"
JSON="$EVID/reproduction.json"
MODE=full; ITERS=${ITERS:-10000000}; REPS=${REPS:-5}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:?}"; shift 2 ;;
    --iters) ITERS="${2:?}"; shift 2 ;;
    --reps) REPS="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
STARTED=$(date -u +%FT%TZ)
REPORT_ONLY=0
[[ "$MODE" == report-only ]] && REPORT_ONLY=1
FAILS=0
PHASES=()

say()  { printf '\n=== %s\n' "$*" | tee -a "$LOG"; }
note() { printf '    %s\n' "$*" | tee -a "$LOG"; }
phase() { # <name> <status> <detail>
  PHASES+=("{\"phase\":\"$1\",\"status\":\"$2\",\"detail\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$3")}")
  printf '    [%s] %s -- %s\n' "$2" "$1" "$3" | tee -a "$LOG"
  [[ "$2" == OK || "$2" == FINDING || "$2" == REUSED ]] || FAILS=$((FAILS+1))
}
run() { # <phase> <cmd...>  -- OK on exit 0, FAILED otherwise
  local p=$1; shift
  if "$@" >>"$LOG" 2>&1; then phase "$p" OK "$*"; return 0
  else phase "$p" FAILED "$* (exit $?)"; return 1; fi
}

: > "$LOG"
say "SEMANTIC-LINKER-1 reproduction -- mode=$MODE started=$STARTED"
note "repo : $REPO"
note "lane : $LANE"
note "host : $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)"
[[ "$MODE" == reuse ]] && note "NOTE: reuse mode verifies build identity instead of rebuilding; this run is NOT a clean reproduction"

if [[ "$REPORT_ONLY" == 0 ]]; then
# ---- 1. the frozen manifest ------------------------------------------------
say "1. frozen baseline"
run freeze_verify bash "$RF/g0_freeze/freeze.sh" --verify

# ---- 2/3. substrate ---------------------------------------------------------
say "2. stage the frozen source into an isolated tree"
run stage bash "$RF/g1_substrate/stage_substrate.sh"

say "3. build Dynamic Modules OFF and ON, and the instrumented pair"
if [[ "$MODE" == full ]]; then
  # A CLEAN REPRODUCTION RE-CLONES. The lane tree in a working session carries
  # the G2 and G3 instruments, so building the G1 pair on top of it would NOT
  # reproduce G1 -- it would build something else and call it G1. Full mode
  # therefore re-clones pristine frozen source, builds the uninstrumented pair,
  # then APPLIES THE BANKED EXPERIMENT PATCHES and builds the instrumented pair.
  # That also exercises the banked patches, which is the only way to know they
  # still apply.
  run stage_force bash "$RF/g1_substrate/stage_substrate.sh" --force
  run build_matched bash "$RF/g1_substrate/build_matched.sh"
  DT="$SRC/flutter/third_party/dart"
  APPLY_OK=1
  for pt in "$RF/g2_execution/banked_experiment/0001-g2-function-execution-mode-instrument.patch" \
            "$RF/g3_types_gc/banked_experiment/0001-g3-expose-full-gc-for-testing.patch"; do
    git -C "$DT" apply -p1 "$pt" >>"$LOG" 2>&1 || { APPLY_OK=0; note "banked patch did not apply: $pt"; }
  done
  [[ "$APPLY_OK" == 1 ]] && phase banked_patches_apply OK "both experiment patches applied to pristine frozen source" \
                         || phase banked_patches_apply FAILED "a banked experiment patch no longer applies"
  run build_instrumented bash "$RF/g3_types_gc/build_g3.sh"
  # Did the uninstrumented rebuild reproduce G1's accepted artifacts? Recorded
  # as DATA, per artifact, not asserted -- linked executables are not expected
  # to be bit-reproducible across builds, and claiming otherwise would be false.
  python3 - "$RF/g1_substrate/g1_manifest.json" "$SRC/out" "$EVID/g1_rebuild_comparison.json" <<'G6CREPRO' >>"$LOG" 2>&1
import json,hashlib,sys,os
m=json.load(open(sys.argv[1])); out=sys.argv[2]; dest=sys.argv[3]
res={}
for arm in ('dm_off','dm_on'):
    for a,rec in m['arms'][arm]['artifacts'].items():
        p=os.path.join(out,'sl1_'+arm,a)
        h=hashlib.sha256(open(p,'rb').read()).hexdigest() if os.path.isfile(p) else None
        res[f'{arm}/{a}']={'recorded':rec['sha256'],'rebuilt':h,'byte_identical':h==rec['sha256']}
json.dump(res, open(dest,'w'), indent=2)
n=sum(1 for v in res.values() if v['byte_identical'])
print(f'G1 rebuild reproduced {n}/{len(res)} artifacts byte-for-byte')
G6CREPRO
  phase g1_rebuild_comparison OK "per-artifact reproducibility recorded in g1_rebuild_comparison.json"
else
  ok=1
  for d in sl1_dm_off sl1_dm_on sl1_g3_off sl1_g3_on; do
    [[ -x "$SRC/out/$d/dartaotruntime" ]] || { ok=0; note "missing build: $d"; }
  done
  # Identity, not mere presence: G1's artifacts must still hash to its manifest.
  python3 - "$RF/g1_substrate/g1_manifest.json" "$SRC/out" <<'PY' >>"$LOG" 2>&1 || ok=0
import json,hashlib,sys,os
m=json.load(open(sys.argv[1])); out=sys.argv[2]
for arm in ('dm_off','dm_on'):
    for a,rec in m['arms'][arm]['artifacts'].items():
        p=os.path.join(out,'sl1_'+arm,a)
        h=hashlib.sha256(open(p,'rb').read()).hexdigest()
        assert h==rec['sha256'], (arm,a,h,rec['sha256'])
print('G1 artifacts match the recorded manifest')
PY
  [[ "$ok" == 1 ]] && phase build_reuse REUSED "existing builds verified against g1_manifest.json" \
                   || phase build_reuse FAILED "a required build is missing or has drifted"
fi

# ---- 4-8. the gates ---------------------------------------------------------
say "4. positive mixed-execution gates (G1)"
for arm in dm_off dm_on g3_on; do
  run "g1_probe_$arm" bash "$RF/g1_substrate/run_probe.sh" --arm "$arm"
done

say "5. execution and identity gates (G2)"
ARM=g3_off bash "$RF/g2_execution/run_g2.sh" >>"$LOG" 2>&1 && phase g2_control OK "OFF arm: substrate correctly absent" || phase g2_control FAILED "OFF control"
ARM=g3_on  bash "$RF/g2_execution/run_g2.sh" >>"$LOG" 2>&1 && phase g2_subject OK "6/6" || phase g2_subject FAILED "subject arm"

say "6. class/type/generic/GC gates (G3)"
ARM=g3_off bash "$RF/g3_types_gc/run_g3.sh" >>"$LOG" 2>&1 && phase g3_control OK "OFF arm" || phase g3_control FAILED "OFF control"
ARM=g3_on  bash "$RF/g3_types_gc/run_g3.sh" >>"$LOG" 2>&1 && phase g3_subject OK "10/10" || phase g3_subject FAILED "subject arm"

say "7. optimizer adversity (G4)"
rm -f "$RF/g4_optimizer/evidence"/g4_*disassembly.txt
run g4 env ARM=g3_on bash "$RF/g4_optimizer/run_g4.sh"

say "8. categorized negative controls (G6A)"
# EXIT CODE IS NOT THE VERDICT HERE. G6A's own summary counts negatives that do
# not fail closed, and those are FINDINGS. The harness records them as such and
# refuses to let a later phase turn them green.
bash "$RF/g6a_negatives/run_negatives.sh" >>"$LOG" 2>&1
if [[ -f "$RF/g6a_negatives/evidence/negatives.json" ]]; then
  phase g6a FINDING "negatives reproduced; fail-open cases are recorded as findings"
else
  phase g6a FAILED "no structured negative-control output"
fi

say "9. cost families, including the allocation/GC addendum"
run g6b_costs env ITERS="$ITERS" REPS="$REPS" ARM=g3_on bash "$RF/g6b_cost/run_costs.sh"
run g6b_alloc env N=5000000 REPS="$REPS" ARM=g3_on bash "$RF/g6b_cost/run_alloc.sh"

# ---- 10. repository checks --------------------------------------------------
say "10. repository checks for this lane"
SH_BAD=0
while IFS= read -r f; do bash -n "$f" 2>>"$LOG" || { SH_BAD=$((SH_BAD+1)); note "shell syntax: $f"; }; done \
  < <(find "$RF" -name '*.sh' -not -path '*/evidence/*')
[[ "$SH_BAD" -eq 0 ]] && phase shell_syntax OK "every lane script parses" || phase shell_syntax FAILED "$SH_BAD script(s) fail bash -n"

JS_BAD=0
while IFS= read -r f; do python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$f" 2>>"$LOG" || { JS_BAD=$((JS_BAD+1)); note "bad json: $f"; }; done \
  < <(find "$RF" -name '*.json')
[[ "$JS_BAD" -eq 0 ]] && phase json_valid OK "every emitted record parses" || phase json_valid FAILED "$JS_BAD invalid"

YM_BAD=0
if python3 -c 'import yaml' 2>/dev/null; then
  while IFS= read -r f; do python3 -c 'import yaml,sys;yaml.safe_load(open(sys.argv[1]))' "$f" 2>>"$LOG" || { YM_BAD=$((YM_BAD+1)); note "bad yaml: $f"; }; done \
    < <(find "$RF" -name '*.yaml')
  [[ "$YM_BAD" -eq 0 ]] && phase yaml_valid OK "every dynamic interface parses" || phase yaml_valid FAILED "$YM_BAD invalid"
fi

# The lane must not have touched the product. This is the repository check that
# actually matters: if packages/ or the supported record moved, the whole
# feasibility argument is contaminated.
DIRTY=$(git -C "$REPO" status --porcelain -- packages bin selfhost/engine/route_b selfhost/compatibility.yaml | head)
[[ -z "$DIRTY" ]] && phase product_untouched OK "packages/, bin/, route_b/ and compatibility.yaml are unmodified" \
                  || phase product_untouched FAILED "the lane modified product files: $DIRTY"

fi   # end of the executing phases; report-only jumps straight here

# ---- 11. structured output --------------------------------------------------
say "11. structured results"
python3 - "$JSON" "$RF" "$SRC" "$MODE" "$STARTED" "$EVID" <<'G6CJSON'
import json,os,sys,hashlib,re,datetime
out, rf, src, mode, started, evid = sys.argv[1:7]

# A REGENERATED REPORT MUST NOT LOSE -- OR FORGE -- THE RUN IT DESCRIBES.
# report-only re-emits from evidence produced by an earlier run, so it carries
# that run's mode and start time forward and marks itself regenerated. Claiming
# `clean_reproduction` for a report-only invocation would be a lie; dropping it
# when the evidence really did come from a full run would be a different one.
prior = {}
if mode == 'report-only':
    try: prior = json.load(open(out))
    except Exception: prior = {}
source_run_mode = prior.get('source_run_mode', prior.get('mode', 'unknown')) if mode=='report-only' else mode
source_run_started = prior.get('source_run_started', prior.get('started', started)) if mode=='report-only' else started

def sha(p):
    try:
        h=hashlib.sha256()
        with open(p,'rb') as f:
            for c in iter(lambda: f.read(1<<20), b''): h.update(c)
        return h.hexdigest()
    except OSError: return None

# MANDATORY EVIDENCE. Missing OR unparseable is a refusal, not a lower score.
# This is the list falsify.sh mutates, and the reason it exists: a harness that
# announced a structured file it had never written is what G6C found.
MANDATORY_JSON = ['g0_freeze/freeze_manifest.json',
                  'g6a_negatives/evidence/negatives.json']
MANDATORY_TEXT = ['g1_substrate/evidence/probe_g3_on.txt',
                  'g2_execution/evidence/g2_g3_on.txt',
                  'g3_types_gc/evidence/g3_g3_on.txt',
                  'g4_optimizer/evidence/g4_solo_fenced.txt',
                  'g4_optimizer/evidence/g4_solo_unfenced.txt',
                  'g6b_cost/evidence/costs.txt',
                  'g6b_cost/evidence/alloc_gc.txt']
MANDATORY_BLOB = ['g0_freeze/banked_source/dart/9999-worktree-uncommitted.patch',
                  'g2_execution/banked_experiment/0001-g2-function-execution-mode-instrument.patch',
                  'g3_types_gc/banked_experiment/0001-g3-expose-full-gc-for-testing.patch']
missing_evidence = []
loaded = {}
for rel in MANDATORY_JSON:
    fp = os.path.join(rf, rel)
    try:
        loaded[rel] = json.load(open(fp))
    except Exception as e:
        missing_evidence.append({'evidence': rel, 'problem': f'{type(e).__name__}: {e}'})
for rel in MANDATORY_TEXT:
    fp = os.path.join(rf, rel)
    if not os.path.isfile(fp) or os.path.getsize(fp) < 64:
        missing_evidence.append({'evidence': rel, 'problem': 'missing or truncated'})
for rel in MANDATORY_BLOB:
    fp = os.path.join(rf, rel)
    if not os.path.isfile(fp) or not open(fp, 'rb').read(4).startswith(b'diff') and b'---' not in open(fp,'rb').read(4096):
        missing_evidence.append({'evidence': rel, 'problem': 'missing or not a patch'})

freeze = loaded.get('g0_freeze/freeze_manifest.json', {})
negs   = loaded.get('g6a_negatives/evidence/negatives.json', {})
g1     = {}
try: g1 = json.load(open(os.path.join(rf,'g1_substrate/g1_manifest.json')))
except Exception: pass

def transcript(rel):
    try: return open(os.path.join(rf, rel)).read()
    except OSError: return ''

def gate(rel, needle):
    t = transcript(rel)
    return {'evidence': rel, 'present': bool(t),
            'status': 'PASS' if needle in t else ('MISSING' if not t else 'FAIL')}

gates = {
  'G1_substrate': gate('g1_substrate/evidence/probe_g3_on.txt','LOAD: returned=NEW'),
  'G2_execution': gate('g2_execution/evidence/g2_g3_on.txt','G2 ARM PASS'),
  'G3_types_gc' : gate('g3_types_gc/evidence/g3_g3_on.txt','G3 ARM PASS'),
  'G4_optimizer': gate('g4_optimizer/evidence/g4_solo_fenced.txt','bypass           NO'),
}
g4u = transcript('g4_optimizer/evidence/g4_solo_unfenced.txt')
gates['G4_optimizer']['bypass_reproduced'] = 'bypass           YES' in g4u

cost_t  = transcript('g6b_cost/evidence/costs.txt')
alloc_t = transcript('g6b_cost/evidence/alloc_gc.txt')
# re.M: without it ^ and $ anchor to the whole string, not each line, and
# every cost row silently failed to match while PERFORMANCE read NOT_MEASURED.
def rows(t, pat): return {m: float(v) for m,v in re.findall(pat, t, re.M)}
costs = {
  'execution_ns_per_call': rows(cost_t, r'^(\w+)\s+([\d.]+)\s+[\d.]+\s+[\d.]+\s+[\d.]+x$'),
  'allocation_ns_per_alloc': rows(alloc_t, r'^(alloc_\w+)\s+([\d.]+)\s+[\d.]+\s+[\d.]+\s+[\d.]+x'),
  'measurement_semantics': ('Timings are not required to reproduce byte-identically. '
      'What must reproduce is that the measurement RAN, that raw samples and '
      'methodology are retained, and that the qualitative distinctions hold: '
      'interpreted execution ~10-12x a direct AOT call, all three interpreted '
      'modes within noise of each other, and full-GC cost flat across modes.'),
  'raw_samples': ['g6b_cost/evidence/raw_samples.txt','g6b_cost/evidence/alloc_raw_samples.txt'],
}

fail_open = [n for n in negs.get('negatives',[]) if n.get('outcome')=='FAIL_OPEN']

# REPRODUCIBILITY, SPLIT. The lane's own builds and the historical supported
# cell are different claims and are never merged into one number.
rebuild = {}
try: rebuild = json.load(open(os.path.join(evid,'g1_rebuild_comparison.json')))
except Exception: pass
def arm_score(arm):
    rows_ = {k:v for k,v in rebuild.items() if k.startswith(arm+'/')}
    return {'byte_identical': sum(1 for v in rows_.values() if v.get('byte_identical')),
            'total': len(rows_)}
lane_repro = {
  'dm_off': arm_score('dm_off'), 'dm_on': arm_score('dm_on'),
  'verdict': ('REPRODUCIBLE' if rebuild and all(v.get('byte_identical') for v in rebuild.values())
              else ('NOT_REPRODUCIBLE' if rebuild else 'NOT_MEASURED_IN_THIS_MODE')),
  'claim': ('The SEMANTIC-LINKER-1 G1 host toolchain builds are byte-reproducible '
            'from the G0-banked frozen source lineage.'),
  'evidence': 'g6c_harness/evidence/g1_rebuild_comparison.json',
}
cell_repro = {
  'verdict': 'NOT_ESTABLISHED_BY_THIS_GATE',
  'prior_evidence': {'vm_platform.dill': 'reproduced', 'full_cell': 'not reproduced'},
  'note': ('This gate reproduces the LANE\'s builds, not the historical supported '
           'cell. NEXT_LANES.md\'s "nothing reproduces the cell" is narrowed by '
           'new evidence, not retracted.'),
}

prereqs = [{
  'id': 'MODULE_SIDE_DYNAMIC_INTERFACE_VALIDATION', 'status': 'UNRESOLVED',
  'severity': 'BLOCKING_FOR_PRODUCTION',
  'statement': ('Patch compilation must invoke the CFE with the dynamic-interface '
                'specification so a violating module is refused before it reaches the runtime.'),
  'why': ('KernelTarget.validateDynamicModule runs only when the CFE is given '
          'dynamicInterfaceSpecificationUri while compiling the MODULE. dart2bytecode has no '
          'such option and gen_kernel consumes --dynamic-interface on the host compile, where '
          'it annotates rather than validates.'),
  'observed_consequence': ('All four DYNAMIC_INTERFACE_POLICY negatives load silently; '
                           'member_not_overridable additionally produces silently wrong behaviour.'),
  'evidence': ['g6a_negatives/RESULT.md','g6a_negatives/evidence/negatives.json'], 'consumed_by': 46,
},{
  'id': 'PATCHABILITY_CONTRACT_INVARIANT', 'status': 'CARRY_FORWARD',
  'severity': 'DESIGN_CONSTRAINT',
  'statement': ('Every member intended to remain patchable must be emitted as can-be-overridden '
                'by the release-time contract generator.'),
  'why': ('G4: with a single closed-world implementation the precompiler devirtualizes every '
          'call site and inlines one outright. extendable plus callable are not sufficient.'),
  'evidence': ['g4_optimizer/RESULT.md'], 'consumed_by': 46,
},{
  'id': 'CORRUPT_KBC_MISCLASSIFIES_AS_IMPORT_FAILURE', 'status': 'CARRY_FORWARD',
  'severity': 'TOOLING_CONSTRAINT',
  'statement': 'Explain tooling must not classify a module failure from the VM error string alone.',
  'evidence': ['g6a_negatives/RESULT.md'], 'consumed_by': 46,
}]

artifacts = {}
for arm in ('dm_off','dm_on','g3_off','g3_on'):
    for a in ('dartaotruntime','gen_snapshot','vm_platform.dill'):
        fp=os.path.join(src,'out','sl1_'+arm,a)
        if os.path.isfile(fp): artifacts[f'out/sl1_{arm}/{a}']=sha(fp)
for rel in MANDATORY_BLOB:
    fp=os.path.join(rf,rel)
    if os.path.isfile(fp): artifacts[rel]=sha(fp)

gates_bad = [k for k,v in gates.items() if v['status']!='PASS']
blocking  = [p for p in prereqs if p['status']=='UNRESOLVED']

# THE NAMED MACHINE-READABLE STATE. Deliberately NOT an "all tests pass" line:
# that would contradict G6A, which found five failure modes that do not fail
# closed. Reproduction can pass while the evidence it faithfully reproduces
# includes unsafe behaviour.
state = {
  'RUNTIME_SUBSTRATE':  'PASS' if gates['G1_substrate']['status']=='PASS' else 'FAIL',
  'MIXED_EXECUTION':    'PASS' if gates['G2_execution']['status']=='PASS' else 'FAIL',
  'TYPE_AND_GC':        'PASS' if gates['G3_types_gc']['status']=='PASS' else 'FAIL',
  'OPTIMIZER_CONTRACT': ('PASS_IF_CAN_BE_OVERRIDDEN'
                         if gates['G4_optimizer']['status']=='PASS'
                         and gates['G4_optimizer']['bypass_reproduced'] else 'FAIL'),
  'NEGATIVE_CONTROLS':  'FINDINGS_PRESENT' if fail_open else 'NO_FINDINGS',
  'PERFORMANCE':        'MEASURED' if costs['execution_ns_per_call'] else 'NOT_MEASURED',
  'REPRODUCIBILITY':    'PASS' if lane_repro['verdict']=='REPRODUCIBLE' else lane_repro['verdict'],
  'UNRESOLVED_PREREQUISITES': [p['id'] for p in blocking],
}

result = {
  'REPRODUCTION': 'FAIL' if (missing_evidence or gates_bad) else 'PASS',
  'FEASIBILITY_EVIDENCE': 'REPRODUCED' if not gates_bad else 'NOT_REPRODUCED',
  'KNOWN_FAIL_OPEN_FINDINGS': 'REPRODUCED' if fail_open else 'ABSENT',
  'PRODUCTION_PREREQUISITES': 'UNRESOLVED' if blocking else 'RESOLVED',
}

doc = {
 'schema':'semantic-linker-1/g6c-reproduction/3','gate':'SL1-G6C','issue':45,'tracker':36,
 'mode':mode,
 'source_run_mode': source_run_mode,
 'source_run_started': source_run_started,
 'clean_reproduction': source_run_mode=='full',
 'regenerated_from_evidence': mode=='report-only',
 'started':started,
 'finished':datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
 'result':result,
 'machine_readable_state':state,
 'frozen_baseline':freeze.get('distribution',{}),
 'record_at_tag':freeze.get('record_at_tag',{}),
 'source_identity':freeze.get('producing_source',{}),
 'builds':{k:{'dart_dynamic_modules':v.get('dart_dynamic_modules'),
              'artifacts':{a:r.get('sha256') for a,r in v.get('artifacts',{}).items()}}
           for k,v in (g1.get('arms') or {}).items()},
 'LANE_BUILD_REPRODUCIBILITY': lane_repro,
 'SUPPORTED_CELL_REPRODUCIBILITY': cell_repro,
 'gates':gates,
 'negative_controls':{'total':len(negs.get('negatives',[])),
    'closed_expected':sum(1 for n in negs.get('negatives',[]) if n.get('outcome')=='CLOSED_EXPECTED'),
    'closed_other_category':sum(1 for n in negs.get('negatives',[]) if n.get('outcome')=='CLOSED_OTHER_CATEGORY'),
    'fail_open':len(fail_open),'evidence':'g6a_negatives/evidence/negatives.json'},
 'fail_open_findings':fail_open,
 'costs':costs,'artifacts':artifacts,'unresolved_prerequisites':prereqs,
 'missing_or_mutated_evidence':missing_evidence,
 'verdict_rule':('REPRODUCTION cannot be PASS while mandatory evidence is missing or '
                 'unparseable, or while a positive gate did not reproduce. Reproducing a '
                 'known fail-open negative is a reproduced FINDING and is never rendered '
                 'as a safety result.'),
}
json.dump(doc, open(out,'w'), indent=2)
print(json.dumps({'result':result,'state':state,
                  'missing_or_mutated':len(missing_evidence)}, indent=2))
sys.exit(1 if (missing_evidence or gates_bad) else 0)
G6CJSON
rc=$?
[[ "$rc" -eq 0 ]] && phase structured_output OK "$JSON" || phase structured_output FAILED "could not emit structured results"

python3 - "$JSON" "${PHASES[@]}" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d['phases']=[json.loads(x) for x in sys.argv[2:] if x.strip()]
json.dump(d, open(p,'w'), indent=2)
PY

say "RESULT"
R=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]))["result"];print(" ".join(f"{k}={v}" for k,v in d.items()))' "$JSON" 2>/dev/null || echo "REPRODUCTION=UNKNOWN")
note "result : $R"
note "failed phases : $FAILS"
note "structured : $JSON"
note "log : $LOG"
REPRO=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["result"]["REPRODUCTION"])' "$JSON" 2>/dev/null || echo FAIL)
# report-only judges the reporting path alone; phase failures belong to a run
# that actually executed phases.
if [[ "$REPORT_ONLY" == 1 ]]; then
  [[ "$REPRO" == PASS ]] || exit 1
else
  [[ "$FAILS" -eq 0 && "$REPRO" == PASS ]] || exit 1
fi
exit 0
