#!/usr/bin/env bash
# cspell:words dartaotruntime dill bytecode dynmod
# run_arms.sh -- SM1-G4 (#53): withhold each retention class in turn.
#
# #53 requires each withheld class to FAIL CLOSED at load with an attributable
# category. Whether it does is measured here, per class, and the answer is not
# uniform -- which is the gate's substantive finding rather than a harness
# defect. Nothing below is smoothed toward "fails closed".
#
# THE FIVE BUILDS DIFFER BY ONE CONTRACT ENTRY EACH. Every variant carries the
# complete contract minus exactly one class, so an outcome is attributable to
# the withheld class and not to compiler mood. `full` is the control: if it does
# not dispatch to the patch, no refusal below means anything.
#
# CATEGORIES, assigned from the observed pipeline and never guessed:
#   FAILS_CLOSED         the pipeline refused -- compile error, VM abort, or a
#                        throw out of loadDynamicModule
#   FAILS_OPEN           the module loaded and the call site still reached the
#                        AOT body. A silent wrong answer, which #53 designates a
#                        FINDING and never a pass
#   NO_OBSERVABLE_EFFECT indistinguishable from the full contract on this shape
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
G="$(cd -- "$HERE/.." >/dev/null 2>&1 && pwd)"
SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
DT=${DT:-$SRC/flutter/third_party/dart}
DART="$OUT/dart-sdk/bin/dart"
GK="$DT/pkg/vm/bin/gen_kernel.dart"
D2B="$DT/pkg/dart2bytecode/bin/dart2bytecode.dart"
JSON=${1:-$G/evidence/arms.json}

declare -a IDS=() CATS=() DETAILS=()
CONTROL_OK=0

for V in full no_callable no_extendable no_can_be_used_as_type no_can_be_overridden; do
  W=$(mktemp -d); mkdir -p "$W/lib" "$W/.dart_tool"
  cp "$G/probe/host.dart" "$W/lib/"
  cp "$G/probe/m_patch.dart" "$W/"
  printf '{"configVersion":2,"packages":[{"name":"dynamic_modules","rootUri":"file://%s/","packageUri":"lib/","languageVersion":"3.9"}]}' "$W" \
    > "$W/.dart_tool/package_config.json"
  URI=package:dynamic_modules/host.dart
  PKG="$W/.dart_tool/package_config.json"

  echo "──────── contract variant: $V ────────"
  "$DART" "$GK" --platform "$OUT/vm_platform.dill" --aot --packages "$PKG" \
    --dynamic-interface "$G/probe/di_$V.yaml" -o "$W/host.dill" "$URI" > "$W/gk.log" 2>&1
  GKRC=$?
  echo "  gen_kernel        exit=$GKRC"
  if [[ $GKRC != 0 ]]; then
    CAT=FAILS_CLOSED; DET="gen_kernel refused: $(head -1 "$W/gk.log" | tr -d '\n' | cut -c1-120)"
    echo "  -> $CAT ($DET)"
    IDS+=("$V"); CATS+=("$CAT"); DETAILS+=("$DET"); rm -rf "$W"; continue
  fi

  "$OUT/gen_snapshot" --snapshot_kind=app-aot-elf --elf="$W/host.aot" "$W/host.dill" > "$W/gs.log" 2>&1
  echo "  gen_snapshot      exit=$?  aot=$(stat -f%z "$W/host.aot" 2>/dev/null || echo -)"

  "$DART" "$GK" --platform "$OUT/vm_platform.dill" --no-aot --no-link-platform \
    --packages "$PKG" -o "$W/import.dill" "$URI" >/dev/null 2>&1
  "$DART" "$D2B" --platform "$OUT/vm_platform.dill" --import-dill "$W/import.dill" \
    -o "$W/m.bytecode" "$W/m_patch.dart" > "$W/d2b.log" 2>&1
  D2BRC=$?
  echo "  dart2bytecode     exit=$D2BRC"
  if [[ $D2BRC != 0 || ! -s "$W/m.bytecode" ]]; then
    CAT=FAILS_CLOSED; DET="dart2bytecode refused: $(head -1 "$W/d2b.log" | tr -d '\n' | cut -c1-120)"
    echo "  -> $CAT ($DET)"
    IDS+=("$V"); CATS+=("$CAT"); DETAILS+=("$DET"); rm -rf "$W"; continue
  fi

  "$OUT/dartaotruntime" "$W/host.aot" "$W/m.bytecode" "file://$W/m_patch.dart" > "$W/run.log" 2>&1
  RC=$?
  echo "  dartaotruntime    exit=$RC"
  sed 's/^/    | /' "$W/run.log" | head -5

  if grep -q DISPATCH_OK "$W/run.log"; then
    if [[ "$V" == full ]]; then
      CONTROL_OK=1; CAT=CONTROL_DISPATCH_OK; DET='the patch subtype answered'
    else
      CAT=NO_OBSERVABLE_EFFECT
      DET='loaded and dispatched to the patch exactly as the full contract did'
    fi
  elif grep -q DISPATCH_BYPASS "$W/run.log"; then
    CAT=FAILS_OPEN
    DET='the module loaded and the call site still reached the AOT body'
  elif grep -q LOAD_THREW "$W/run.log"; then
    CAT=FAILS_CLOSED
    DET="loadDynamicModule threw: $(grep -m1 LOAD_THREW "$W/run.log" | cut -c1-120)"
  elif [[ $RC != 0 ]]; then
    CAT=FAILS_CLOSED
    DET="runtime refused (exit $RC): $(grep -m1 -E 'error|Error' "$W/run.log" | tr -d '\n' | cut -c1-140)"
  else
    CAT=UNCLASSIFIED
    DET="exit 0 with no dispatch marker"
  fi
  echo "  -> $CAT"
  IDS+=("$V"); CATS+=("$CAT"); DETAILS+=("$DET")
  rm -rf "$W"
done

python3 - "$JSON" "$CONTROL_OK" "${IDS[@]}" -- "${CATS[@]}" -- "${DETAILS[@]}" <<'PY'
import json, sys
out, control = sys.argv[1], sys.argv[2] == '1'
rest = sys.argv[3:]
a = rest.index('--'); b = rest.index('--', a + 1)
ids, cats, dets = rest[:a], rest[a+1:b], rest[b+1:]
rows = [{'variant': i, 'category': c, 'detail': d}
        for i, c, d in zip(ids, cats, dets)]
# The contract class each variant withholds, so the map can key on it.
withheld = {
    'no_callable': 'callable',
    'no_extendable': 'extendable',
    'no_can_be_used_as_type': 'can-be-used-as-type',
    'no_can_be_overridden': 'can-be-overridden',
}
enforced = {withheld[r['variant']]: r['category']
            for r in rows if r['variant'] in withheld}
json.dump({
    'schema': 'semantic-map-1/g4-arms/1', 'gate': 'SM1-G4', 'issue': 53,
    'control_dispatch_ok': control,
    'rows': rows,
    'enforced_at_load': enforced,
}, open(out, 'w'), indent=2)
print()
print(f'  control (full contract) dispatched to the patch: {control}')
for r in rows:
    print(f'  {r["variant"]:24} {r["category"]}')
PY
