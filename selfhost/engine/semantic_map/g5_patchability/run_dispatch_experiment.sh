#!/usr/bin/env bash
# SM1-G5 -- the Base.work virtual/instance-dispatch experiment.
#
# The narrow question: can the exact release mechanically determine that a
# NON-INLINED declaration nevertheless has stale AOT call sites?
#
# Discipline this run enforces:
#   * the reader and the behavioural demonstration use the SAME EXACT AOT SHA;
#   * the replacement body is proven to attach INDEPENDENTLY of any call site;
#   * the shipped machine code is inspected for the ordinary call site;
#   * a compiler-devirtualizable receiver shape is compared against a
#     runtime-polymorphic, dispatch-preserving one.
#
# THE SUBJECT IS NOT BUILT HERE. run_route2.sh builds app_release.aot from
# release3.dill and banks the reader against it; this script consumes that exact
# file unchanged. Whole-AOT output is not byte-reproducible, so rebuilding here
# would silently give the demonstration a different artifact from the one the
# reader was banked against -- which is the entire discipline being enforced.
#
# usage: run_dispatch_experiment.sh <clone-src> <workdir>
set -uo pipefail
SRC="${1:?usage: run_dispatch_experiment.sh <clone-src> <workdir>}"
W="${2:?usage: run_dispatch_experiment.sh <clone-src> <workdir>}"
G="$(cd "$(dirname "$0")" && pwd)"
S="$SRC/out/host_release_arm64"
OD=/opt/homebrew/opt/llvm/bin/llvm-objdump
rc=0
SUBJ="$W/app_release.aot"
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

# DELETE EVERY DERIVED OUTPUT FIRST. A producer that fails leaves the previous
# run's bytecode, container or reader state in place, and a later assertion
# then consumes a stale artifact and passes. Same defect the reader
# falsification harness had.
rm -f "$W/basework.bytecode" "$W/patch_basework.sbrb" "$W/rel.json" \
      "$W/weak_predictor.dart" "$W/patched_run.txt" "$W/shapes.txt"

# EVERY PRODUCER'S EXIT STATUS IS LOAD-BEARING. Checking only that an output
# file is non-empty accepts a producer that failed after writing a partial
# file, and accepts a stale file from a previous run. Each step below is run
# through `must`, which records the failure and marks the run failed.
must() { # must <what> <cmd...>
  local what="$1"; shift
  if ! "$@"; then
    echo "  PRODUCER FAILED: $what"
    PRODUCER_FAILED="${PRODUCER_FAILED}$what; "
    rc=1
    return 1
  fi
}
PRODUCER_FAILED=""
ASSERTIONS=()
want() {
  if [ "$2" = "$3" ]; then ASSERTIONS+=("  pass  $1")
  else ASSERTIONS+=("  FAIL  $1 -- got '$3', expected '$2'"); rc=1; fi
}

{
echo "SM1-G5 -- Base.work virtual/instance dispatch"
echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by run_dispatch_experiment.sh"
echo
echo "THE QUESTION"
cat <<'TXT'
  Can the exact release mechanically determine that a non-inlined declaration
  nevertheless has stale AOT call sites?

  Base.work is reported NOT_INLINED by the route-2 reader. That is an
  inlining-specific fact: it says no covered body-copy mechanism was witnessed.
  It is NOT a claim that every call site observes an attached patch. This run
  puts both statements on ONE artifact so they cannot be argued past each other.
TXT
echo

# ---------------------------------------------------------------- the release
echo "############ 1. THE CANONICAL RELEASE, TAKEN NOT REBUILT ############"
if [ ! -f "$SUBJ" ]; then
  echo "  MISSING $SUBJ -- run run_route2.sh first; this script does not"
  echo "  build the subject, because a rebuild would not be the same bytes."
  exit 2
fi
AOT_SHA=$(sha "$SUBJ")
echo "  gen_snapshot     $(sha "$S/gen_snapshot")"
echo "  release3.dill    $(sha "$W/release3.dill")"
echo "  app_release.aot  $AOT_SHA"
echo "  banked reader state was produced from this same file:"
echo "                   $(python3 -c "import json;print(json.load(open('$G/evidence/inlining_state.json'))['diagnostics']['aot_sha256'])")"
cat <<'TXT'

  WHY release3.dill AND NOT prepass3.dill. The route-2 reader was banked
  against an AOT built from prepass3.dill. That artifact runs and reports a
  build id, so it looks like a release -- but prepass3.dill is the PRE-PASS
  kernel from which gen_dynamic_interface derives di3.yaml, compiled WITHOUT
  --dynamic-interface. A patch against it fails at attach with "Unable to find
  function DateTime.now", because the dynamic-module retention the interface
  drives is absent. Only the kernel compiled WITH the interface is the
  patchable release, so the whole experiment moves onto it -- reader included.
TXT
echo

# --------------------------------------------------- the reader, on THAT AOT
echo "############ 2. THE READER, ON THAT EXACT AOT ############"
must reader python3 "$G/lib/read_inlining.py" "$SUBJ" "$W/g2_r.json" - \
    "$W/rel.json"
python3 - "$W/rel.json" "$AOT_SHA" <<'PY' | sed 's/^/  /'
import json, sys
d = json.load(open(sys.argv[1]))
assert d['diagnostics']['aot_sha256'] == sys.argv[2], 'reader read another file'
print(f"subject sha256 {d['diagnostics']['aot_sha256']}")
print(f"validated={d['note_validated']} complete={d['note_complete_projection']}")
for s in d['states']:
    if s['name'] in ('work', 'viaVirtual', 'viaDirect', 'viaInlined'):
        owner = (s['owner'] + '.') if s['owner'] else ''
        print(f"  {owner + s['name']:14} {s['state']:12} {s['code']}")
PY
echo

# ------------------------------------------------------------- the patch
echo "############ 3. THE PATCH, AND AN INDEPENDENT ATTACH PROOF ############"
must dart2bytecode "$S/dartaotruntime" "$S/gen/dart2bytecode.dart.snapshot" \
    --platform "$S/vm_platform.dill" \
    --packages "$W/.dart_tool/package_config.json" \
    --import-dill "$W/import.dill" \
    -o "$W/basework.bytecode" "$G/probe/repl_basework.dart"
[ -s "$W/basework.bytecode" ] \
  || { echo "  dart2bytecode wrote no bytecode"; rc=1; }

# The build-id read is a producer too: an empty id would silently pack a
# container that can never match the release.
if ! ID=$("$S/dartaotruntime" "$SUBJ" | awk '/BUILD_ID/{print $2}'); then
  echo "  PRODUCER FAILED: release build-id read"
  PRODUCER_FAILED="${PRODUCER_FAILED}build-id read; "; rc=1
fi
case "$ID" in
  '' | '<none>') echo "  the release reported no usable build id"; rc=1 ;;
esac
must pack_patch "$S/dart" "$G/../../route_b/packaging/pack_patch.dart" \
    --release-build-id "$ID" --out "$W/patch_basework.sbrb" \
    --target "package:dynamic_modules/callsite_target.dart#Base.work=$W/basework.bytecode"
[ -s "$W/patch_basework.sbrb" ] || { echo "  pack_patch wrote no container"; rc=1; }
echo "  running build id  $ID"
echo "  bytecode          $(sha "$W/basework.bytecode")"
echo "  container         $(sha "$W/patch_basework.sbrb")"
cat <<'TXT'

  The receiver is typed `Object`, not `Base`. The release's dynamic interface
  grants this library's members as CALLABLE, which is not the same capability
  as can-be-used-as-type; naming `Base` as a parameter type fails attach with
  "Unable to find class Base". The body does not need the type, so it does not
  ask for it.
TXT
echo
# The patched run must SUCCEED. It previously only had its output captured, so
# a runtime abort would have been read as "the arm reported OLD".
if "$S/dartaotruntime" "$SUBJ" "$W/patch_basework.sbrb" > "$W/patched_run.txt" 2>&1
then :; else
  echo "  PRODUCER FAILED: patched dartaotruntime run"
  PRODUCER_FAILED="${PRODUCER_FAILED}patched run; "; rc=1
fi
RUN=$(cat "$W/patched_run.txt")
echo "$RUN" | sed 's/^/  /'
echo
cat <<'TXT'
  THE ATTACH IS PROVEN INDEPENDENTLY OF ANY CALL SITE. IsInterpreted goes 0->1
  and HasBytecode 0->1 on the target function, and the C++ invoke of the target
  returns PATCHED-w. So a call site that still reads OLD-w is not a failed
  attach: the replacement body exists, is installed, and computes the new value
  when invoked directly.
TXT
echo

# ------------------------------------------------------- the machine code
echo "############ 4. THE SHIPPED MACHINE CODE AT EACH CALL SITE ############"
for s in viaDirect viaVirtual viaInlined; do
  echo "  --- $s ---"
  "$OD" -d --disassemble-symbols=$s --no-show-raw-insn "$SUBJ" \
    2>/dev/null | sed -n '6,26p' | sed 's/^/  /'
done
cat <<'TXT'

  REGISTER ROLES ARE FROM SOURCE, NOT INFERRED. constants_arm64.h:144-145 gives
  PP = R27 (object pool) and DISPATCH_TABLE_REG = R21.
  FlowGraphCompiler::EmitDispatchTableCall (flow_graph_compiler_arm64.cc) emits
  AddImmediate(LR, cid_reg, selector_offset) then Call([R21, LR, UXTX, Scaled])
  -- exactly the pair seen in viaVirtual. UntaggedCode is header(8) then
  entry_point_ at 8 and monomorphic_entry_point_ at 16 (raw_object.h:2014-2019),
  so a tagged `ldur x30,[x0,#0x7]` reads the NORMAL entry and `#0xf` the
  MONOMORPHIC entry.
TXT
echo

echo "############ 5. MECHANICAL CLASSIFICATION OF EVERY CALL SITE ############"
must shape-scanner python3 "$G/lib/scan_dispatch_calls.py" "$SUBJ" \
  --symbol viaVirtual --symbol viaDirect --symbol viaInlined
cat <<'TXT'

  Pool offsets are RELATIVE TO THE CALLING CODE'S OWN POOL and are NOT
  comparable across functions: the same offset appears in _state and inside
  viaInlined, which cannot be the same object. They are reported as evidence of
  shape only. This run deliberately makes no claim about WHICH function a pool
  slot holds -- that needs the pool decoded, which it does not do.
TXT
echo

echo "############ 6. WHAT THE ARMS SHOW ############"
V=$(echo "$RUN" | awk '/^after /{for(i=1;i<=NF;i++) if($i ~ /^virtual=/) print substr($i,9)}')
DIR=$(echo "$RUN" | awk '/^after /{for(i=1;i<=NF;i++) if($i ~ /^direct=/) print substr($i,8)}')
INL=$(echo "$RUN" | awk '/^after /{for(i=1;i<=NF;i++) if($i ~ /^inlined=/) print substr($i,9)}')
OTH=$(echo "$RUN" | awk '/^after /{for(i=1;i<=NF;i++) if($i ~ /^other=/) print substr($i,7)}')
printf '  %-38s %-14s %s\n' 'call site' 'after patch' 'shipped shape'
printf '  %-38s %-14s %s\n' 'viaDirect  Base().work()  bindable' "$DIR" 'POOL_INDIRECT, monomorphic entry'
printf '  %-38s %-14s %s\n' 'viaVirtual b.work()      polymorphic' "$V" 'DISPATCH_TABLE, cid-indexed'
printf '  %-38s %-14s %s\n' 'viaInlined _inlineHelper inlined away' "$INL" 'POOL_INDIRECT, normal entry'
printf '  %-38s %-14s %s\n' 'Other.work untargeted control' "$OTH" '(different declaration)'
cat <<'TXT'

  1. A DECLARATION THE READER CALLS NOT_INLINED HAS A STALE CALL SITE IN THE
     SAME RELEASE. Base.work is NOT_INLINED, its replacement is attached and
     verified by direct invoke, and viaVirtual still reads OLD-w. The two
     statements do not conflict: NOT_INLINED is about body copies, and this
     staleness is about dispatch.

  2. THE POLYMORPHIC SITE IS NOT REDIRECTED, AND THE MECHANISM IS VISIBLE.
     viaVirtual reads the entry point out of the dispatch table indexed by the
     receiver's class id. It never consults the callee's pool entry, so
     attaching a body to Base.work cannot move it.

  3. THE DEVIRTUALIZABLE SITE IS REDIRECTED. viaDirect constructs its receiver
     in place, calls through the object pool, and reads PATCHED-w.

  4. BUT POOL-INDIRECT IS NOT SUFFICIENT FOR REDIRECTABILITY. viaInlined
     contains NO dispatch-table call -- only a pool-indirect one -- and is
     still stale. The two pool-indirect sites differ in which entry point they
     read (monomorphic vs normal). That is a HYPOTHESIS for the difference, not
     a demonstrated cause; nothing here proves the entry kind is what decides.

  SO THE ANSWER IS ASYMMETRIC:

     presence of staleness   MECHANICALLY DETECTABLE. A dispatch-table call
                             site is never redirected by attaching a body, and
                             this release has 491 of them across 198 functions.
     absence of staleness    NOT DETERMINABLE from call-site shape as
                             characterised here, because arm 4 shows a
                             pool-indirect site that stayed stale.

  Attributing a dispatch-table site to the DECLARATIONS it can reach needs the
  precompiler's selector map (dispatch_table_generator.cc assigns the selector
  ids that EmitDispatchTableCall folds into its offset). That map is not in the
  ELF, so per-declaration attribution is not available from the release today.
  Recovering it would be new instrumentation, and is NOT proposed here.
TXT
echo "############ 7. THE POLICY CONSEQUENCE, AND ITS FALSIFICATION ############"
cat <<'TXT'
  #54 permits REDUCE_SCOPE when an unsafe declaration class can be mechanically
  excluded. G1 already retains `static` as authoritative declaration metadata,
  so the predicate the finding licenses is:

      replaceable callable AND static is not exactly true  =>  refuse

  "Cannot tell" is kept as its OWN refusal rather than folded into "not
  static": absent, null, or non-boolean metadata is an unusable fact, not a
  permission, and merging the two would let a missing input read as a
  measurement.

  THE CONVERSE IS NOT ASSERTED. static == true only avoids THIS refusal; the
  inbound call mechanism for static declarations is not closed, and every arm
  below still carries CALL_SITE_SHAPE_UNPROVEN.
TXT
echo
python3 "$G/lib/falsify_dispatch_predicate.py" "$S/dart" "$W" 2>&1 | sed 's/^/  /'
echo "  exit=$?  (asserted: 0)"
echo
cat <<'TXT'
  POSITIVE CONTROL. The same arms run against a copy of the predictor with the
  predicate block deleted. The eight arms that depend on it must flip; the two
  that must NOT depend on it -- a static declaration, and a field, which is not
  a replaceable callable -- must keep passing.
TXT
echo
must weaken-predictor python3 "$G/lib/weaken_predictor.py" \
    "$G/lib/predict_patchable.dart" "$W/weak_predictor.dart"
SM1_PREDICTOR="$W/weak_predictor.dart" python3 \
    "$G/lib/falsify_dispatch_predicate.py" "$S/dart" "$W" 2>&1 | sed 's/^/  /'
echo "  exit=$?  (asserted: non-zero)"
} > "$G/evidence/dispatch_experiment.txt" 2>&1

# ------------------------------------------------------------- assertions
AOT_SHA=$(sha "$SUBJ")
want 'reader read the same artifact the demo ran' "$AOT_SHA" \
     "$(python3 -c "import json;print(json.load(open('$W/rel.json'))['diagnostics']['aot_sha256'])")"
want 'reader validated the note on the release AOT' True \
     "$(python3 -c "import json;print(json.load(open('$W/rel.json'))['note_validated'])")"
want 'reader reports Base.work NOT_INLINED there' NOT_INLINED \
     "$(python3 -c "
import json
d=json.load(open('$W/rel.json'))
print(next(s['state'] for s in d['states'] if s['name']=='work' and s['owner']=='Base'))")"
T="$G/evidence/dispatch_experiment.txt"
want 'the replacement attached (IsInterpreted 0 -> 1)' 1 \
     "$(grep -c 'ATTACH: after  -> IsInterpreted=1 HasBytecode=1' "$T")"
want 'direct invoke of the target returns the patched value' 1 \
     "$(grep -c 'C++ invoke of target returned: PATCHED-w' "$T")"
want 'the container applied' 1 "$(grep -c 'APPLY ok' "$T")"
# Read the AFTER line specifically. Counting occurrences in the whole file
# matched the `before` line too, so "OLD-w appears" was not the same claim as
# "OLD-w after the patch".
AFTER=$(grep -m1 '^  after ' "$T")
field() { echo "$AFTER" | tr ' ' '\n' | grep "^$1=" | head -1; }
want 'devirtualizable site observed the patch' direct=PATCHED-w "$(field direct)"
want 'polymorphic site did NOT observe the patch' virtual=OLD-w "$(field virtual)"
want 'inlined-helper site did NOT observe the patch' inlined=OLD-w "$(field inlined)"
want 'the untargeted control is unchanged' other=OTHER-w "$(field other)"
want 'viaVirtual carries a dispatch-table call site' 1 \
     "$(python3 "$G/lib/scan_dispatch_calls.py" "$SUBJ" --symbol viaVirtual \
        | grep -c 'viaVirtual.*DISPATCH_TABLE')"
want 'viaDirect carries no dispatch-table call site' 0 \
     "$(python3 "$G/lib/scan_dispatch_calls.py" "$SUBJ" --symbol viaDirect \
        | grep -c 'viaDirect.*DISPATCH_TABLE')"
# LOAD-BEARING. The claim is that absence of a dispatch-table shape does NOT
# imply the site is redirectable; viaInlined is the witness, so its dispatch
# count must be asserted to be zero rather than assumed.
want 'viaInlined carries NO dispatch-table call site, yet stayed stale' 0 \
     "$(python3 "$G/lib/scan_dispatch_calls.py" "$SUBJ" --symbol viaInlined \
        | grep -c 'viaInlined.*DISPATCH_TABLE')"
BASE_OUT=$(python3 "$G/lib/falsify_dispatch_predicate.py" "$S/dart" "$W" 2>&1)
want 'the dispatch predicate is fail-closed on every arm' 0 "$?"
want 'predicate baseline is exactly 10/10' 'arms=10 passed=10 failed=0' \
     "$(echo "$BASE_OUT" | grep -o 'arms=10 passed=10 failed=0')"

# THE CONTROL'S OUTCOME IS EXACT, NOT MERELY NON-ZERO. A weakened predictor
# that failed only one arm would otherwise satisfy "the control failed".
CTL_OUT=$(SM1_READER= SM1_PREDICTOR="$W/weak_predictor.dart" python3 \
    "$G/lib/falsify_dispatch_predicate.py" "$S/dart" "$W" 2>&1)
want 'deleting the predicate makes those arms fail' 1 "$?"
want 'weakened predicate is exactly 2 pass / 8 fail' 'arms=10 passed=2 failed=8' \
     "$(echo "$CTL_OUT" | grep -o 'arms=10 passed=2 failed=8')"
want 'the two survivors are exactly the arms that must not depend on it' \
     'top-level static function | a field, which is not a replaceable callable' \
     "$(echo "$CTL_OUT" | sed -n 's/^SURVIVORS: //p')"
want 'no producer in this run failed' '' "$PRODUCER_FAILED"
want 'the predicate transcript records FAIL_CLOSED' 1 \
     "$(grep -c 'SM1_G5_DISPATCH_PREDICATE: FAIL_CLOSED' "$T")"
want 'the reader bank and this demonstration used one artifact' "$AOT_SHA" \
     "$(python3 -c "import json;print(json.load(open('$G/evidence/inlining_state.json'))['diagnostics']['aot_sha256'])")"

{
  echo
  echo "ASSERTIONS (${#ASSERTIONS[@]} checked)"
  printf '%s\n' "${ASSERTIONS[@]}"
  echo
  echo "SM1_G5_DISPATCH_EXPERIMENT: $([ "$rc" = 0 ] && echo COMPLETE || echo FAILED)"
} >> "$G/evidence/dispatch_experiment.txt"
printf '%s\n' "${ASSERTIONS[@]}"
echo "SM1_G5_DISPATCH_EXPERIMENT: $([ "$rc" = 0 ] && echo COMPLETE || echo FAILED)"
exit "$rc"
