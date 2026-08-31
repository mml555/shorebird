#!/usr/bin/env bash
# cspell:words dartaotruntime dynmod
#
# run_2b1f.sh -- narrow-v1 admission: a patched super site is allowed only when
# the RELEASE VERSION OF THE SAME METHOD already direct-called a target with the
# same semantic provenance.
#
# The causal argument, and why it is same-method rather than program-wide:
#
#   release method M is compiled
#     -> M contains an exact super call to T
#     -> AOT had to emit code for T
#     -> patched M wants T
#     -> T has release AOT code
#
# Evidence from an UNRELATED release method would not support that chain, and
# that broader sufficiency claim has not been established.
#
# The comparison is on the target's PROVENANCE FINGERPRINT
# (fileUri|fileOffset|name|kind), never on the site offset -- 2B.1c-SITE is
# exactly why. Control 1 demonstrates the difference: its site offset moves
# 988 -> 1005 while the target fingerprint is unchanged.
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
WORK="${WORK:-$(mktemp -d)}"
MUTATE_GATE="${MUTATE_GATE:-0}"
CORRUPT_EVIDENCE="${CORRUPT_EVIDENCE:-0}"

DART_TREE="$SRC/flutter/third_party/dart"
DART="$OUT/dart-sdk/bin/dart"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
DART2BC="$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart"
GENERATOR="$DART_TREE/pkg/dart2bytecode/lib/bytecode_generator.dart"
GEN_SNAPSHOT="$OUT/gen_snapshot"
AOT_RUNTIME="$OUT/dartaotruntime"
URI=package:dynamic_modules/target.dart
mkdir -p "$WORK"; fail=0
note() { echo; echo "==> $*"; }
check() { if [ "$2" = "$3" ]; then printf '    PASS  %-34s %s\n' "$1" "$2";
          else printf '    FAIL  %-34s got %s want %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

BACKUP="$(mktemp)"; cp "$GENERATOR" "$BACKUP"
before=$(shasum -a 256 "$GENERATOR" | cut -d' ' -f1)
restore() { cp "$BACKUP" "$GENERATOR"
  after=$(shasum -a 256 "$GENERATOR" | cut -d' ' -f1); rm -f "$BACKUP"
  [ "$after" = "$before" ] || { echo "FATAL: generator not restored" >&2; exit 3; }
  echo; echo "dart2bytecode source restored, sha256 $after"; }
trap restore EXIT
python3 "$HERE/../s2b1/apply_0015.py" "$GENERATOR" >/dev/null

# control <name> <releaseSrc> <patchSrc> <class> <method> <member> <wantGate> <wantExec>
control() {
  local name=$1 rel=$2 pat=$3 cls=$4 meth=$5 member=$6 wantGate=$7 wantExec=${8:-}
  local W="$WORK/$name"; mkdir -p "$W/lib" "$W/.dart_tool"
  cat > "$W/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$W/",
    "packageUri": "lib/", "languageVersion": "3.9" } ] }
JSON
  note "$name"
  cp "$rel" "$W/lib/target.dart"
  ( cd "$W" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
      --packages .dart_tool/package_config.json -o discover.dill "$URI" ) >/dev/null
  ( cd "$W" && "$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
      "$HERE/../../gen_dynamic_interface.dart" --dill discover.dill --out di.yaml ) >/dev/null
  ( cd "$W" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
      --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
      -o release_aot.dill "$URI" ) >/dev/null
  "$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
    --elf="$W/target.aot" "$W/release_aot.dill"
  cp "$pat" "$W/lib/target.dart"
  ( cd "$W" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
      --no-aot --no-link-platform \
      --packages .dart_tool/package_config.json -o patched_noaot.dill "$URI" ) >/dev/null
  ( cd "$W" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
      --packages .dart_tool/package_config.json -o patched_aot.dill "$URI" ) >/dev/null
  cp "$rel" "$W/lib/target.dart"

  targets() { "$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
      "$HERE/super_targets.dart" --dill "$W/$1" ${2:+--platform "$2"} \
      --class "$cls" --method "$meth"; }
  targets release_aot.dill > "$W/release.json"
  targets patched_noaot.dill "$OUT/vm_platform.dill" > "$W/patched.json"
  echo "    release evidence : $(python3 -c "
import json;d=json.load(open('$W/release.json'))
print([x['fingerprint'].split('|')[1:] if x['fingerprint'] else None for x in d])")"
  echo "    patched resolves : $(python3 -c "
import json;d=json.load(open('$W/patched.json'))
print([x['fingerprint'].split('|')[1:] if x['fingerprint'] else None for x in d])")"

  local admit
  admit=$(CORRUPT="$CORRUPT_EVIDENCE" python3 -c "
import json, os, sys
rel = {x['fingerprint'] for x in json.load(open('$W/release.json')) if x['fingerprint']}
pat = [x['fingerprint'] for x in json.load(open('$W/patched.json'))]
if os.environ.get('CORRUPT') == '1':
    # Control 4: change only the RECORDED release target, leaving the release
    # itself untouched. If the gate still admits, it is comparing something
    # other than the target.
    rel = {f.replace('|672|', '|9999|') for f in rel}
print('ADMIT' if pat and all(f in rel for f in pat) else 'REFUSE')")
  if [ "$MUTATE_GATE" = "1" ]; then
    echo "    GATE MUTATION    : membership check bypassed"
    admit=ADMIT
  fi
  # CONTROL 4 inverts the expectation for the one case it touches: with the
  # RECORDED release target corrupted and the release itself untouched, an
  # admit would mean the gate is comparing something other than the target.
  if [ "$CORRUPT_EVIDENCE" = "1" ] && [ "$wantGate" = "ADMIT" ]; then
    wantGate=REFUSE
    echo "    EVIDENCE CORRUPTED: recorded target offset 672 -> 9999"
  fi
  check "gate" "$admit" "$wantGate"
  [ "$admit" = "ADMIT" ] || return 0

  local off
  off=$(python3 -c "
import json;d=json.load(open('$W/patched.json'));print(d[0]['offset'])")
  cat > "$W/replacement.dart" <<DART
import 'package:dynamic_modules/target.dart';

@pragma('shorebird:direct-super')
Object? routeBSuper(Object receiver, String originLibrary, String originClass,
        String originMember, String originMemberKind, int siteOffset,
        String member) =>
    throw StateError('not lowered');

@pragma('dyn-module:entry-point')
String go($cls self) => 'WRAP:\${routeBSuper(
      self, '$URI', '$cls', '$meth', 'Method', $off, '$member') as String}';
DART
  set +e
  ( cd "$W" && "$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" \
      --import-dill patched_noaot.dill -o replacement.bytecode replacement.dart ) \
    > "$W/compile.log" 2>&1
  local crc=$?
  ( cd "$W" && "$AOT_RUNTIME" target.aot replacement.bytecode "$URI" ) \
    > "$W/run.log" 2>&1
  set -e
  local got abort
  got=$(grep -E '^patched' "$W/run.log" | sed 's/.*: //' || true)
  abort=$(grep -c 'Attempt to compile function' "$W/run.log" || true)
  [ "$abort" = "0" ] || echo "    runtime          : ABORT — Attempt to compile function"
  echo "    execution        : ${got:-<none>}"
  [ -z "$wantExec" ] || check "execution" "${got:-<none>}" "$wantExec"
  if [ "$MUTATE_GATE" = "1" ] && [ "$abort" != "0" ]; then
    echo "    the gate is LOAD-BEARING: bypassing it reaches the release abort"
  fi
}

if [ "$MUTATE_GATE" = "1" ]; then
  control c2_introduced_mixin "$HERE/../s2b1d/armC_release.dart" \
    "$HERE/../s2b1d/armC_patch.dart" Leaf target close ADMIT
else
  control c1_existing_call "$HERE/c1_release.dart" "$HERE/c1_patch.dart" \
    Leaf target close ADMIT 'WRAP:TICKER:APP-STATE'
  control c2_introduced_mixin "$HERE/../s2b1d/armC_release.dart" \
    "$HERE/../s2b1d/armC_patch.dart" Leaf target close REFUSE
  control c3_introduced_plain "$HERE/../s2b1d/armD_release.dart" \
    "$HERE/../s2b1d/armD_patch.dart" AChild target read REFUSE
fi

echo
[ "$fail" -eq 0 ] || { echo "RESULT: $fail check(s) FAILED"; exit 1; }
echo "RESULT: PASS"
echo "work dir kept: $WORK"
