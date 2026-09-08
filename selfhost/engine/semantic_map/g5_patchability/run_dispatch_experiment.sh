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
# usage: run_dispatch_experiment.sh <clone-src> <workdir>
set -uo pipefail
SRC="${1:?usage: run_dispatch_experiment.sh <clone-src> <workdir>}"
W="${2:?usage: run_dispatch_experiment.sh <clone-src> <workdir>}"
G="$(cd "$(dirname "$0")" && pwd)"
S="$SRC/out/host_release_arm64"
OD=/opt/homebrew/opt/llvm/bin/llvm-objdump
rc=0
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
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
echo "############ 1. ONE RELEASE, BUILT FROM THE RELEASE KERNEL ############"
"$S/gen_snapshot" --snapshot_kind=app-aot-elf --patchable_static_calls \
    --elf="$W/app_s6rel.aot" "$W/release3.dill" 2>&1 | sed 's/^/  /'
AOT_SHA=$(sha "$W/app_s6rel.aot")
echo "  gen_snapshot   $(sha "$S/gen_snapshot")"
echo "  release3.dill  $(sha "$W/release3.dill")"
echo "  app_s6rel.aot  $AOT_SHA"
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
python3 "$G/lib/read_inlining.py" "$W/app_s6rel.aot" "$W/g2_r.json" - \
    "$W/rel.json" | sed 's/^/  /'
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
"$S/dartaotruntime" "$S/gen/dart2bytecode.dart.snapshot" \
    --platform "$S/vm_platform.dill" \
    --packages "$W/.dart_tool/package_config.json" \
    --import-dill "$W/import.dill" \
    -o "$W/basework.bytecode" "$G/probe/repl_basework.dart" 2>&1 | sed 's/^/  /'
ID=$("$S/dartaotruntime" "$W/app_s6rel.aot" | awk '/BUILD_ID/{print $2}')
"$S/dart" "$G/../../route_b/packaging/pack_patch.dart" \
    --release-build-id "$ID" --out "$W/patch_basework.sbrb" \
    --target "package:dynamic_modules/callsite_target.dart#Base.work=$W/basework.bytecode" \
    2>&1 | sed 's/^/  /'
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
RUN=$("$S/dartaotruntime" "$W/app_s6rel.aot" "$W/patch_basework.sbrb" 2>&1)
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
  "$OD" -d --disassemble-symbols=$s --no-show-raw-insn "$W/app_s6rel.aot" \
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
python3 "$G/lib/scan_dispatch_calls.py" "$W/app_s6rel.aot" \
  --symbol viaVirtual --symbol viaDirect --symbol viaInlined | sed 's/^/  /'
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
} > "$G/evidence/dispatch_experiment.txt" 2>&1

# ------------------------------------------------------------- assertions
AOT_SHA=$(sha "$W/app_s6rel.aot")
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
     "$(python3 "$G/lib/scan_dispatch_calls.py" "$W/app_s6rel.aot" --symbol viaVirtual \
        | grep -c 'viaVirtual.*DISPATCH_TABLE')"
want 'viaDirect carries no dispatch-table call site' 0 \
     "$(python3 "$G/lib/scan_dispatch_calls.py" "$W/app_s6rel.aot" --symbol viaDirect \
        | grep -c 'viaDirect.*DISPATCH_TABLE')"

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
