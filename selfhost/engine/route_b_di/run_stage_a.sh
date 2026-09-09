#!/usr/bin/env bash
# ROUTE-B-DI-1 / STAGE A (#61) -- does the EXISTING upstream validator close
# the three DYNAMIC_INTERFACE_POLICY failures when the module compile is
# actually given --validate?
#
# SEMANTIC-MAP-1 FINAL established mechanically that dart2bytecode exposes
# --validate, that it reaches the CFE, that validateDynamicModule is
# conditional on it, and that Route B omits it. That says where to test. It
# says nothing about whether passing it refuses anything, which is this stage.
#
# NOTHING IN ROUTE B IS TOUCHED HERE. Stage A changes only this harness.
#
# WHY THE ATTRIBUTION IS STRUCTURAL, NOT A MESSAGE MATCH. #61 requires proof
# that a refusal comes from the validation policy rather than a broken positive
# path, a missing import dill, a wrong platform or an unrelated compiler
# failure. A nonzero exit cannot show that, and neither can grepping the
# diagnostic. So every arm is the SAME module, the SAME host source, the SAME
# platform and import dill, built in the SAME work directory, differing only in
# the specification -- and three controls carry the attribution:
#
#   di_full            the identical compile SUCCEEDS and the module runs,
#                      so a refusal elsewhere is not a broken harness
#   di_full_plus       one entry the module does NOT use is ADDED and the
#                      compile still succeeds, so the validator is not
#                      refusing on arbitrary specification differences
#   no_validate_flag   the restricted specification with the flag OMITTED
#                      compiles, so the refusal is caused by the flag rather
#                      than by the specification breaking something else
#
# The message is banked as diagnostic evidence and is not what decides.
#
# usage: run_stage_a.sh [out-dir]
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
OUTDIR="${1:-$HERE}"
LANE=${LANE:-/Volumes/build/semantic-linker/sl1}
ARM=${ARM:-g3_on}
SRC="$LANE/flutter/engine/src"
OUT="$SRC/out/sl1_$ARM"
DART_TREE="$SRC/flutter/third_party/dart"
GK="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
D2B="$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart"
DART="$OUT/dart-sdk/bin/dart"
EVID="$OUTDIR/evidence"; mkdir -p "$EVID"
RAW="$EVID/stage_a_arms.json"
LOGF="$EVID/stage_a.txt"

[[ -d "$OUT" ]] || { echo "no build at $OUT" >&2; exit 2; }
for t in "$GK" "$D2B" "$DART"; do
  [[ -e "$t" ]] || { echo "missing tool $t" >&2; exit 2; }
done

# Delete before running. A previous arms file surviving a failed run would be
# read as this run's result -- the stale-input class that has cost this
# programme several cycles.
rm -f "$RAW" "$LOGF"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/lib" "$W/.dart_tool" "$W/specs"
cp "$HERE/probe/n_host.dart" "$W/lib/"
cp "$HERE"/probe/m_*.dart "$W/"
cat > "$W/.dart_tool/package_config.json" <<JSON
{"configVersion":2,"packages":[{"name":"dynamic_modules","rootUri":"file://$W/","packageUri":"lib/","languageVersion":"3.9"}]}
JSON
URI=package:dynamic_modules/n_host.dart

python3 "$HERE/lib/gen_specs.py" "$HERE/probe" "$W/specs" >"$W/specs.txt" 2>&1
SPECS_RC=$?
spec_path() { # <name> -> the file, from probe or the derived dir
  if [[ -f "$HERE/probe/$1" ]]; then echo "$HERE/probe/$1"; else echo "$W/specs/$1"; fi
}

ARMS_JSON="$W/arms.jsonl"; : > "$ARMS_JSON"

emit() { # emit <<'JSON' ... JSON  (one object per line)
  python3 -c 'import json,sys; json.dump(json.loads(sys.stdin.read()), sys.stdout); print()' \
    >> "$ARMS_JSON"
}

run_arm() { # <id> <spec> <expectation> <validate:yes|no> [module-src]
  local id=$1 spec=$2 expect=$3 use_validate=$4 msrc=${5:-m_ok.dart}
  local mpath="$W/$msrc"
  [[ -f "$mpath" ]] || mpath="$W/specs/$msrc"
  local sp; sp=$(spec_path "$spec")
  local sha="absent"
  [[ -f "$sp" ]] && sha=$(shasum -a 256 "$sp" | awk '{print $1}')

  # HOST compile, bound to the same specification as the module compile.
  local hk="$W/h_$id.dill" ha="$W/h_$id.aot"
  local herr="$W/h_$id.err" hrc=1
  if [[ -f "$sp" ]]; then
    "$DART" "$GK" --platform "$OUT/vm_platform.dill" --aot \
      --packages "$W/.dart_tool/package_config.json" \
      --dynamic-interface "$sp" -o "$hk" "$URI" >"$herr" 2>&1
    hrc=$?
  else
    echo "specification absent: $sp" > "$herr"
  fi
  local hsnap=1
  if [[ -f "$hk" ]]; then
    "$OUT/gen_snapshot" --snapshot_kind=app-aot-elf --elf="$ha" "$hk" \
      >>"$herr" 2>&1
    hsnap=$?
  fi

  # MODULE compile. The one variable across arms is the specification, plus
  # whether --validate is passed at all.
  local mout="$W/m_$id.bytecode" merr="$W/m_$id.err" mrc=1
  # `"${vflag[@]}"` on an EMPTY array is an unbound-variable error under
  # `set -u` in bash 3.2, which ships on macOS. The flag control needs an
  # empty expansion, so guard it.
  local -a vflag=()
  [[ "$use_validate" == yes ]] && vflag=(--validate "$sp")
  "$DART" "$D2B" --platform "$OUT/vm_platform.dill" \
    --import-dill "$W/import.dill" ${vflag[@]+"${vflag[@]}"} \
    -o "$mout" "$mpath" >"$merr" 2>&1
  mrc=$?
  local produced=false; [[ -s "$mout" ]] && produced=true

  # LOAD, only if a module was produced and a host snapshot exists.
  local lrc="null" lout="" dispatch="null"
  if [[ "$produced" == true && -f "$ha" ]]; then
    lout=$("$OUT/dartaotruntime" "$ha" "$mout" 2>&1); lrc=$?
    dispatch=$(sed -n 's/^DISPATCH: //p' <<<"$lout" | head -1)
    [[ -z "$dispatch" ]] && dispatch="null"
  fi

  ARM_ID="$id" SPEC="$spec" SPEC_PATH="$sp" SPEC_SHA="$sha" MSRC="$msrc" \
  EXPECT="$expect" USE_VALIDATE="$use_validate" \
  HRC="$hrc" HSNAP="$hsnap" MRC="$mrc" PRODUCED="$produced" \
  LRC="$lrc" DISPATCH="$dispatch" \
  MERR_FILE="$merr" HERR_FILE="$herr" LOUT="$lout" \
  python3 - <<'PY' >> "$ARMS_JSON"
import json, os
def txt(p, n=4000):
    try:
        return open(p, errors='replace').read()[-n:]
    except Exception:
        return ''
d = {
 'id': os.environ['ARM_ID'],
 'spec': os.environ['SPEC'],
 'spec_path': os.environ['SPEC_PATH'],
 'spec_sha256': os.environ['SPEC_SHA'],
 'expectation': os.environ['EXPECT'],
 'module_source': os.environ['MSRC'],
 'validate_flag_passed': os.environ['USE_VALIDATE'] == 'yes',
 'host_kernel_exit': int(os.environ['HRC']),
 'host_snapshot_exit': int(os.environ['HSNAP']),
 'module_compile_exit': int(os.environ['MRC']),
 'bytecode_produced': os.environ['PRODUCED'] == 'true',
 'load_exit': (None if os.environ['LRC'] == 'null'
               else int(os.environ['LRC'])),
 'dispatch': (None if os.environ['DISPATCH'] == 'null'
              else os.environ['DISPATCH']),
 'module_compile_message': txt(os.environ['MERR_FILE']),
 'host_build_message': txt(os.environ['HERR_FILE']),
 'load_output': os.environ['LOUT'][-4000:],
}
print(json.dumps(d))
PY
  printf '  %-26s spec=%-24s mod=%-11s validate=%-3s module=%s produced=%-5s load=%s dispatch=%s\n' \
    "$id" "$spec" "$msrc" "$use_validate" "$mrc" "$produced" "$lrc" "$dispatch"
}

{
echo "ROUTE-B-DI-1 / Stage A -- the existing validator, actually invoked"
echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by run_stage_a.sh"
echo "build $OUT"
echo
echo "############ 0. THE SPECIFICATIONS ############"
cat <<'TXT'
  The three restricted specifications are G6A's own, inherited byte-for-byte.
  The three added ones are DERIVED from di_full.yaml by the generator, because
  a hand-written specification could differ from di_full in more ways than its
  name claims -- which would make a refusal unattributable.
TXT
echo
cat "$W/specs.txt"
echo
echo "############ 1. THE IMPORT DILL (shared by every arm) ############"
"$DART" "$GK" --platform "$OUT/vm_platform.dill" --no-aot --no-link-platform \
  --packages "$W/.dart_tool/package_config.json" -o "$W/import.dill" "$URI" \
  2>&1 | tail -3 | sed 's/^/  /'
IMPORT_RC=${PIPESTATUS[0]}
echo "  import dill exit=$IMPORT_RC  bytes=$(wc -c < "$W/import.dill" 2>/dev/null || echo 0)"
echo
echo "############ 2. ARMS ############"
cat <<'TXT'
  Every arm: same module source, same host source, same platform, same import
  dill, same work directory. The specification is the only variable, except in
  the flag control where the specification is held fixed and the flag is
  dropped instead.
TXT
echo
echo "  -- positive controls, which must SUCCEED --"
run_arm positive_full          di_module_full.yaml     compile_and_load  yes
run_arm positive_full_plus     di_mf_plus.yaml         compile_and_load  yes
echo
echo "  -- the three policy arms this issue owns, which must REFUSE --"
run_arm policy_no_extendable   di_mf_no_extendable.yaml   refuse_at_compile yes
run_arm policy_no_type         di_mf_no_type.yaml         refuse_at_compile yes
run_arm policy_no_overridable  di_mf_no_overridable.yaml  refuse_at_compile yes
echo
echo "  -- adjacent arm, classified INDEPENDENTLY (not folded into policy) --"
run_arm adjacent_no_callable   di_no_callable.yaml     classify_only     yes
echo
echo "  -- the HOST specification, handed to the module validator as-is --"
cat <<'TXT'
    G6A's di_full.yaml was written for gen_kernel --dynamic-interface, which
    ANNOTATES rather than validates, so it never had to be complete. Handed to
    dart2bytecode --validate it refuses the POSITIVE module on dart:core
    grounds unrelated to any negative. That is a finding about specification
    completeness, banked as its own arm rather than hidden inside the choice
    of a different base.
TXT
run_arm host_spec_as_module_spec di_full.yaml          classify_only     yes
echo
echo "  -- specification INPUT integrity, a separate category from policy --"
run_arm input_empty            di_empty.yaml           refuse_at_compile yes
run_arm input_unparseable      di_broken.yaml          refuse_at_compile yes
run_arm input_missing          di_absent.yaml          refuse_at_compile yes
echo
echo "  -- is the can-be-used-as-type RULE enforced at all? --"
cat <<'TXT'
    m_ok.dart never uses Base as a TYPE -- it only EXTENDS it, which the
    validator governs under `extendable`. So G6A's no_type arm withdraws a
    permission the module does not exercise, and there is nothing to refuse.
    These two arms use m_type.dart, which is m_ok plus one type annotation, to
    settle whether the RULE is enforced. They are NEW arms and do not replace
    the historical one.
TXT
run_arm rule_type_positive     di_module_full.yaml     compile_and_load  yes m_type.dart
run_arm rule_type_withdrawn    di_mf_no_type.yaml      refuse_at_compile yes m_type.dart
echo
echo "  -- the flag control: same restricted spec, --validate OMITTED --"
run_arm control_no_validate    di_mf_no_extendable.yaml compile_unvalidated no
echo
echo "############ 3. CLASSIFICATION, DERIVED FROM THE RECORDS ############"
python3 "$HERE/lib/classify_stage_a.py" "$ARMS_JSON" "$RAW"
CLASSIFY_RC=$?
echo
echo "############ 4. THE CLASSIFIER, FALSIFIED ############"
cat <<'TXT'
  The arms take minutes each because they build a host AOT, so the classifier
  is falsified by MUTATING the recorded evidence rather than re-running them.
  A classifier that reported VALIDATOR_CLOSES_* regardless of its input would
  certify this prerequisite closed, which makes it the most expensive vacuous
  check in the lane.
TXT
echo
if [[ -f "$RAW" ]]; then
  python3 "$HERE/lib/falsify_stage_a.py" "$RAW" \
      "$HERE/lib/classify_stage_a.py" "$W/falsify"
  FALSIFY_RC=$?
else
  echo "  NO CLASSIFICATION TO FALSIFY -- the classifier wrote nothing."
  FALSIFY_RC=2
fi
echo
echo "############ 5. ASSERTIONS ############"
} > "$LOGF" 2>&1
rc=0
A=()
want() {
  if [[ "$2" == "$3" ]]; then A+=("  pass  $1")
  else A+=("  FAIL  $1 -- got '$3', expected '$2'"); rc=1; fi
}
j() { python3 -c "
import json,sys
try: print(eval(sys.argv[1], {'d': json.load(open('$1'))}))
except Exception: print('unreadable')" "$2"; }

want 'the specification generator ran' 0 "${SPECS_RC:-1}"
want 'the shared import dill built' 0 "${IMPORT_RC:-1}"
want 'every declared arm produced a record' 13 "$(j "$RAW" "len(d['arms'])")"
want 'the attribution preconditions hold' True \
     "$(j "$RAW" "d['attribution_established']")"
want 'the positive module ran and OVERRODE the host' PATCH-CHILD \
     "$(j "$RAW" "d['arms']['positive_full']['dispatch']")"
want 'no owned policy arm is still open' 0 \
     "$(j "$RAW" "len(d['policy_still_open'])")"
want 'the silent bypass does not survive' False \
     "$(j "$RAW" "d['silent_bypass_survives']")"
want 'every specification-input arm refuses' True \
     "$(j "$RAW" "d['specification_input_all_refused']")"
want 'the adjacent arm is not counted as policy' True \
     "$(j "$RAW" "'adjacent_no_callable' not in d['policy_closed'] + d['policy_still_open']")"
want 'every counted arm passed --validate' True \
     "$(j "$RAW" "all(v['validate_flag_passed'] for k,v in d['owned_policy_arms'].items() if v['closed_by_validator'])")"
want 'the classifier decided from structure, not prose' True \
     "$(j "$RAW" "'NOT the diagnostic text' in d['decides_from']")"
want 'the classifier is falsified' 0 "${FALSIFY_RC:-1}"
want 'the classification succeeded' 0 "${CLASSIFY_RC:-1}"
{
  printf '%s\n' "${A[@]}"
  echo
  echo "ASSERTIONS (${#A[@]} checked: $(printf '%s\n' "${A[@]}" | grep -c '^  pass  ') pass, $(printf '%s\n' "${A[@]}" | grep -c '^  FAIL  ') fail)"
  echo
  echo "STAGE_A_GATE: $([[ "$rc" == 0 ]] && j "$RAW" "d['stage_a_result']" || echo STAGE_A_INCOMPLETE)"
} >> "$LOGF"
cat "$LOGF"
echo "arms:       $RAW"
echo "transcript: $LOGF"
exit "$rc"
