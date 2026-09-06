#!/usr/bin/env bash
# cspell:words dartaotruntime dill semantic linker KBC oldpos
# run_negatives.sh -- SEMANTIC-LINKER-1 / G6A. Every failure mode, forced, and
# classified into the narrowest category the evidence actually supports.
#
# NON-VACUITY IS ENFORCED, NOT ASSERTED. The positive path is built and run
# FIRST from the same work directory with the same inputs, and if it does not
# succeed the whole run aborts -- because a negative that "fails" in a harness
# where nothing works proves nothing at all.
#
# EVERY NEGATIVE IS THE POSITIVE WITH EXACTLY ONE THING WRONG, so a failure is
# attributable to the mutation. The contract variants are generated from
# di_full.yaml by removing one entry.
#
# CLASSIFICATION IS FROM THE OBSERVED MESSAGE, and the message is banked beside
# the verdict. A negative that does NOT fail is recorded as FAIL_OPEN -- never
# quietly counted as covered.
#
#   run_negatives.sh            # one command, clean work dir
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LANE=${LANE:-/Volumes/build/semantic-linker/sl1}
SRC="$LANE/flutter/engine/src"
ARM=${ARM:-g3_on}
ALT=${ALT:-dm_on}                 # a DIFFERENT build of the same lineage
OUT="$SRC/out/sl1_$ARM"
OUT_ALT="$SRC/out/sl1_$ALT"
EVID="$HERE/evidence"; mkdir -p "$EVID"
JSON="$EVID/negatives.json"
LOGF="$EVID/negatives.txt"
DART_TREE="$SRC/flutter/third_party/dart"
GK="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
D2B="$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart"
DART="$OUT/dart-sdk/bin/dart"

[[ -d "$OUT" ]] || { echo "no build at $OUT" >&2; exit 2; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/lib" "$W/.dart_tool"
cp "$HERE/probe/n_host.dart" "$W/lib/"
cp "$HERE"/probe/m_*.dart "$W/"
cat > "$W/.dart_tool/package_config.json" <<JSON
{"configVersion":2,"packages":[{"name":"dynamic_modules","rootUri":"file://$W/","packageUri":"lib/","languageVersion":"3.9"}]}
JSON
URI=package:dynamic_modules/n_host.dart
RESULTS=()
FAILED=0

kernel() { # <di.yaml> <out.dill> [extra args...]
  local di=$1 out=$2; shift 2
  "$DART" "$GK" --platform "$OUT/vm_platform.dill" --aot \
    --packages "$W/.dart_tool/package_config.json" --dynamic-interface "$di" \
    -o "$out" "$URI" "$@" 2>&1
}
import_kernel() {
  "$DART" "$GK" --platform "$OUT/vm_platform.dill" --no-aot --no-link-platform \
    --packages "$W/.dart_tool/package_config.json" -o "$1" "$URI" 2>&1
}
bytecode() { # <src.dart> <out> [platform] [importdill]
  local s=$1 o=$2 plat=${3:-$OUT/vm_platform.dill} imp=${4:-$W/import.dill}
  "$DART" "$D2B" --platform "$plat" --import-dill "$imp" -o "$o" "$s" 2>&1
}

classify() { # <text> -> category
  local t=$1
  if   grep -qiE 'wrong full snapshot version|snapshot version|incompatible.*snapshot' <<<"$t"; then echo HOST_IDENTITY
  elif grep -qiE 'unable to find (function|class|field)|not found in library'          <<<"$t"; then echo IMPORT_RESOLUTION
  elif grep -qiE 'dynamic interface|not extendable|dyn-module|dynamic_module_validator|can only be|is not exposed' <<<"$t"; then echo DYNAMIC_INTERFACE_POLICY
  elif grep -qiE 'bytecode|kbc|magic|invalid.*version|unexpected tag|corrupt'          <<<"$t"; then echo MODULE_INTEGRITY
  elif grep -qiE 'invalid kernel binary|dill|is already loaded'                        <<<"$t"; then echo HOST_IDENTITY
  else echo UNCLASSIFIED; fi
}

record() { # <name> <expected> <observed> <exit> <evidence-line>
  local name=$1 exp=$2 obs=$3 rc=$4 ev=$5
  # FOUR OUTCOMES, never collapsed into pass/fail. "Did not fail" is the one
  # that matters most and must never be scored the same as "failed with a
  # different category".
  local ok
  if   [[ "$rc" -eq 0 ]];        then ok=FAIL_OPEN
  elif [[ "$obs" == "$exp" ]];   then ok=CLOSED_EXPECTED
  elif [[ "$obs" == UNCLASSIFIED ]]; then ok=CLOSED_UNCLASSIFIED
  else                                ok=CLOSED_OTHER_CATEGORY
  fi
  [[ "$ok" == CLOSED_EXPECTED ]] || FAILED=$((FAILED+1))
  printf '  %-26s exit=%-4s expected=%-24s observed=%-24s %s\n' "$name" "$rc" "$exp" "$obs" "$ok"
  printf '    evidence: %s\n' "${ev:0:200}"
  RESULTS+=("{\"name\":\"$name\",\"expected\":\"$exp\",\"observed\":\"$obs\",\"exit\":$rc,\"outcome\":\"$ok\",\"evidence\":$(python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()[:600]))' <<<"$ev")}")
}

{
echo "SL1-G6A negative controls"
echo "arm  : $ARM   alt build for identity negatives: $ALT"
echo "date : $(date -u +%FT%TZ)"
echo

echo "== NON-VACUITY: the positive path must work first =="
kernel "$HERE/probe/di_full.yaml" "$W/host.dill" | sed 's/^/   /'
"$OUT/gen_snapshot" --snapshot_kind=app-aot-elf --elf="$W/host.aot" "$W/host.dill" 2>&1 | sed 's/^/   /'
import_kernel "$W/import.dill" | sed 's/^/   /'
bytecode "$W/m_ok.dart" "$W/m_ok.bytecode" | sed 's/^/   /'
POS=$("$OUT/dartaotruntime" "$W/host.aot" "$W/m_ok.bytecode" 2>&1); PRC=$?
sed 's/^/   /' <<<"$POS"
if [[ "$PRC" -ne 0 ]] || ! grep -q 'DISPATCH: PATCH-CHILD' <<<"$POS"; then
  echo "ABORT: the positive path does not work; no negative below would mean anything"
  exit 1
fi
echo "   POSITIVE OK (exit 0, dispatch reached the patch override)"
echo

echo "== MODULE_INTEGRITY =="
cp "$W/m_ok.bytecode" "$W/malformed.bytecode"
python3 -c "
import sys
p=sys.argv[1]; b=bytearray(open(p,'rb').read())
for i in range(len(b)//3, len(b)//3+64): b[i]^=0xFF
open(p,'wb').write(b)" "$W/malformed.bytecode"
T=$("$OUT/dartaotruntime" "$W/host.aot" "$W/malformed.bytecode" 2>&1); RC=$?
record malformed_kbc MODULE_INTEGRITY "$(classify "$T")" "$RC" "$T"

head -c $(( $(wc -c < "$W/m_ok.bytecode") / 2 )) "$W/m_ok.bytecode" > "$W/truncated.bytecode"
T=$("$OUT/dartaotruntime" "$W/host.aot" "$W/truncated.bytecode" 2>&1); RC=$?
record truncated_kbc MODULE_INTEGRITY "$(classify "$T")" "$RC" "$T"

cp "$W/m_ok.bytecode" "$W/badversion.bytecode"
python3 -c "
import sys
p=sys.argv[1]; b=bytearray(open(p,'rb').read())
b[4]^=0x7F; b[5]^=0x7F   # the version word follows the magic
open(p,'wb').write(b)" "$W/badversion.bytecode"
T=$("$OUT/dartaotruntime" "$W/host.aot" "$W/badversion.bytecode" 2>&1); RC=$?
record wrong_bytecode_version MODULE_INTEGRITY "$(classify "$T")" "$RC" "$T"

echo "  corrupt_digest             NOT APPLICABLE AT THIS LAYER"
echo "    loadDynamicModule takes raw bytes and carries no digest; integrity of"
echo "    a delivered patch is the cell/patch layer's contract (verify_cell_members.sh,"
echo "    the signing model), not the runtime substrate's. Exercising it here would"
echo "    be testing a mechanism this gate does not contain."
RESULTS+=('{"name":"corrupt_digest","expected":"MODULE_INTEGRITY","observed":"NOT_APPLICABLE_AT_THIS_LAYER","exit":null,"matched":"n/a","evidence":"loadDynamicModule takes raw bytes; no digest exists at this layer"}')
echo

echo "== HOST_IDENTITY =="
# A module compiled against a DIFFERENT build's platform dill.
if [[ -f "$OUT_ALT/vm_platform.dill" ]]; then
  bytecode "$W/m_ok.dart" "$W/altplat.bytecode" "$OUT_ALT/vm_platform.dill" "$W/import.dill" > "$W/altplat.err" 2>&1
  if [[ -f "$W/altplat.bytecode" ]]; then
    T=$("$OUT/dartaotruntime" "$W/host.aot" "$W/altplat.bytecode" 2>&1); RC=$?
  else
    T=$(cat "$W/altplat.err"); RC=1
  fi
  record wrong_platform_dill HOST_IDENTITY "$(classify "$T")" "$RC" "$T"
fi
# The host snapshot run by a DIFFERENT build's runtime.
if [[ -x "$OUT_ALT/dartaotruntime" ]]; then
  T=$("$OUT_ALT/dartaotruntime" "$W/host.aot" "$W/m_ok.bytecode" 2>&1); RC=$?
  record wrong_runtime_build HOST_IDENTITY "$(classify "$T")" "$RC" "$T"
fi
# A module compiled against an unrelated import dill.
bytecode "$W/m_ok.dart" "$W/badimport.bytecode" "$OUT/vm_platform.dill" "$OUT/vm_platform.dill" > "$W/badimport.err" 2>&1
if [[ -f "$W/badimport.bytecode" ]]; then
  T=$("$OUT/dartaotruntime" "$W/host.aot" "$W/badimport.bytecode" 2>&1); RC=$?
else T=$(cat "$W/badimport.err"); RC=1; fi
record wrong_import_dill HOST_IDENTITY "$(classify "$T")" "$RC" "$T"
echo

echo "== IMPORT_RESOLUTION =="
bytecode "$W/m_shaken.dart" "$W/shaken.bytecode" > "$W/shaken.err" 2>&1
if [[ -f "$W/shaken.bytecode" ]]; then
  T=$("$OUT/dartaotruntime" "$W/host.aot" "$W/shaken.bytecode" 2>&1); RC=$?
else T=$(cat "$W/shaken.err"); RC=1; fi
record tree_shaken_target IMPORT_RESOLUTION "$(classify "$T")" "$RC" "$T"

# retained() is called by m_ok but withdrawn from `callable`, so it is not kept
# for load-time resolution.
kernel "$HERE/probe/di_no_callable.yaml" "$W/h_nc.dill" > "$W/nc.err" 2>&1
if [[ -f "$W/h_nc.dill" ]]; then
  "$OUT/gen_snapshot" --snapshot_kind=app-aot-elf --elf="$W/h_nc.aot" "$W/h_nc.dill" >/dev/null 2>&1
  T=$("$OUT/dartaotruntime" "$W/h_nc.aot" "$W/m_ok.bytecode" 2>&1); RC=$?
else T=$(cat "$W/nc.err"); RC=1; fi
record missing_retained_import IMPORT_RESOLUTION "$(classify "$T")" "$RC" "$T"
echo

echo "== DYNAMIC_INTERFACE_POLICY =="
for v in no_extendable no_type; do
  kernel "$HERE/probe/di_$v.yaml" "$W/h_$v.dill" > "$W/$v.err" 2>&1
  if [[ -f "$W/h_$v.dill" ]]; then
    "$OUT/gen_snapshot" --snapshot_kind=app-aot-elf --elf="$W/h_$v.aot" "$W/h_$v.dill" >/dev/null 2>&1
    B=$(bytecode "$W/m_ok.dart" "$W/m_$v.bytecode" 2>&1)
    if [[ -f "$W/m_$v.bytecode" ]]; then
      T=$("$OUT/dartaotruntime" "$W/h_$v.aot" "$W/m_$v.bytecode" 2>&1); RC=$?
    else T=$B; RC=1; fi
  else T=$(cat "$W/$v.err"); RC=1; fi
  record "$v" DYNAMIC_INTERFACE_POLICY "$(classify "$T")" "$RC" "$T"
done

# member_not_overridable. G4 established this does NOT fail: the module loads,
# the call devirtualizes, and the host implementation answers. It is exercised
# here precisely so the FAIL-OPEN is on the record rather than absent from it.
kernel "$HERE/probe/di_no_overridable.yaml" "$W/h_no.dill" >/dev/null 2>&1
"$OUT/gen_snapshot" --snapshot_kind=app-aot-elf --elf="$W/h_no.aot" "$W/h_no.dill" >/dev/null 2>&1
T=$("$OUT/dartaotruntime" "$W/h_no.aot" "$W/m_ok.bytecode" 2>&1); RC=$?
if [[ "$RC" -eq 0 ]] && grep -q 'DISPATCH: AOT-BASE' <<<"$T"; then
  OBS=FAIL_OPEN_SILENT_BYPASS
else
  OBS=$(classify "$T")
fi
record member_not_overridable DYNAMIC_INTERFACE_POLICY "$OBS" "$RC" "$T"

echo
echo "SUMMARY negatives=${#RESULTS[@]} not-closed-with-expected-category=$FAILED"
} > "$LOGF" 2>&1

# The rows are JSON, so they are parsed as JSON -- not pasted into a Python
# literal. The first version did the latter and died on `null` in the
# corrupt_digest row, and the script still printed "structured: ..." because
# nothing checked. Missing evidence announcing itself as present is exactly the
# failure this lane refuses everywhere else, so the write is now verified.
printf '%s\n' "[$(IFS=,; echo "${RESULTS[*]}")]" > "$W/rows.json"
python3 - "$JSON" "$W/rows.json" "$ARM" <<'G6AJSON'
import json,sys
out, rowsfile, arm = sys.argv[1:4]
rows = json.load(open(rowsfile))
json.dump({"schema":"semantic-linker-1/g6a-negatives/2","gate":"SL1-G6A","issue":43,
           "arm":arm,"negatives":rows}, open(out,"w"), indent=2)
G6AJSON
if [[ ! -s "$JSON" ]]; then
  echo "FAILED to write structured results to $JSON" >&2
  exit 1
fi

tail -3 "$LOGF"; echo "transcript: $LOGF"; echo "structured: $JSON"
