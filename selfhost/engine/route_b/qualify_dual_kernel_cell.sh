#!/usr/bin/env bash
# cspell:words dartaotruntime dynmod
#
# qualify_dual_kernel_cell.sh -- a candidate compiler cell may claim
# routeBDirectSuperDualKernelV1 only after its OWN dart2bytecode passes the
# dual-kernel probe.
#
# WHY THIS EXISTS RATHER THAN A METADATA LINE. The CLI asks the compiler binary
# what it advertises (`--patched-verification-dill`), which proves the CLI
# surface and not the BEHAVIOUR. This script proves the behaviour, once, before
# publication:
#
#   moved-site specimen, release binding kernel + patched verification kernel
#       -> ACCEPT, and execute the exact super target
#   the SAME specimen with the RELEASE kernel as verifier
#       -> REFUSE
#
# The negative arm is what makes it a qualification rather than a smoke test: a
# 0015/0016 cell reading the release body would accept the first and cannot
# refuse the second for the right reason.
#
# Nothing is stamped unless both arms hold. Run it against the cell's own
# dart2bytecode.aot, never against a source tree.
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
WORK="${WORK:-$(mktemp -d)}"
CELL="${CELL:?set CELL to an extracted candidate cell directory}"
STAMP="${STAMP:-0}"

DART_TREE="$SRC/flutter/third_party/dart"
DART="$OUT/dart-sdk/bin/dart"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
GEN_SNAPSHOT="$OUT/gen_snapshot"
AOT_RUNTIME="$OUT/dartaotruntime"
URI=package:dynamic_modules/target.dart
REL="$HERE/super0/s2b1f/c1_release.dart"
PAT="$HERE/super0/s2b1f/c1_patch.dart"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }
fail=0
check() { if [ "$2" = "$3" ]; then printf '  PASS  %-38s %s\n' "$1" "$2";
          else printf '  FAIL  %-38s got %s want %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

[ -d "$CELL" ] || die "no cell at $CELL"
CELL_RUNTIME="$CELL/dartaotruntime"
CELL_COMPILER="$CELL/dart2bytecode.aot"
CELL_PLATFORM="$CELL/vm_platform.dill"
for f in "$CELL_RUNTIME" "$CELL_COMPILER" "$CELL_PLATFORM"; do
  [ -f "$f" ] || die "cell is missing $(basename "$f")"
done
chmod +x "$CELL_RUNTIME" 2>/dev/null || true

note "surface: does the cell's compiler advertise the verification input?"
usage=$("$CELL_RUNTIME" "$CELL_COMPILER" --help 2>&1 || true)
if grep -q 'patched-verification-dill' <<<"$usage"; then
  echo "  advertises --patched-verification-dill"
else
  echo "  does NOT advertise --patched-verification-dill"
  echo
  echo "RESULT: NOT QUALIFIED — this cell predates 0017. Nothing stamped."
  exit 1
fi

mkdir -p "$WORK/lib" "$WORK/.dart_tool"
cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$WORK/",
    "packageUri": "lib/", "languageVersion": "3.9" } ] }
JSON
cd "$WORK"

note "building the moved-site specimen"
cp "$REL" lib/target.dart
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o discover.dill "$URI" >/dev/null
"$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
  "$HERE/gen_dynamic_interface.dart" --dill discover.dill --out di.yaml >/dev/null
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
  -o release_aot.dill "$URI" >/dev/null
"$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
  --elf=target.aot release_aot.dill
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
  --no-aot --no-link-platform \
  --packages .dart_tool/package_config.json -o release_import.dill "$URI" >/dev/null
cp "$PAT" lib/target.dart
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
  --no-aot --no-link-platform \
  --packages .dart_tool/package_config.json -o patched_import.dill "$URI" >/dev/null
cp "$REL" lib/target.dart

patOff=$("$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
  "$HERE/super0/s2b0/dump_sites.dart" "$PAT" "$OUT/vm_platform.dill" \
  package:dynamic_modules/ patched_import.dill | grep '^{' | python3 -c "
import sys,json
for l in sys.stdin:
    d=json.loads(l)
    if d['site']=='Leaf.target': print(d['fileOffset']); break
else: print('MISSING')")
fp=$("$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
  "$HERE/super0/s2b1f/super_targets.dart" --dill patched_import.dill \
  --platform "$OUT/vm_platform.dill" --class Leaf --method target | python3 -c "
import sys,json;print(json.load(sys.stdin)[0]['fingerprint'])")
IFS='|' read -r fUri fOff fName fKind <<< "$fp"

cat > replacement.dart <<DART
import 'package:dynamic_modules/target.dart';

@pragma('shorebird:direct-super')
Object? routeBSuper(Object receiver, String originLibrary, String originClass,
        String originMember, String originMemberKind, int siteOffset,
        String member, String expectedTargetFileUri,
        int expectedTargetFileOffset, String expectedTargetName,
        String expectedTargetKind) =>
    throw StateError('not lowered');

@pragma('dyn-module:entry-point')
String go(Leaf self) => 'WRAP:\${routeBSuper(
      self, '$URI', 'Leaf', 'target', 'Method', $patOff, 'close',
      '$fUri', $fOff, '$fName', '$fKind') as String}';
DART

compile() { # <label> <verificationDill>
  set +e
  "$CELL_RUNTIME" "$CELL_COMPILER" --platform "$CELL_PLATFORM" \
    --import-dill release_import.dill \
    --patched-verification-dill "$2" \
    -o "$1.bytecode" replacement.dart > "$1.log" 2>&1
  local rc=$?
  set -e
  return $rc
}

note "arm 1 — patched verification kernel"
if compile positive patched_import.dill; then
  set +e
  "$AOT_RUNTIME" target.aot positive.bytecode "$URI" > positive.run.log 2>&1
  set -e
  got=$(grep -E '^patched' positive.run.log | sed 's/.*: //' || true)
  check "compiles" "ACCEPTED" "ACCEPTED"
  check "executes the exact super target" "${got:-<none>}" 'WRAP:TICKER:APP-STATE'
else
  { grep -oE "refused: .*" positive.log || tail -2 positive.log; } | head -1 | sed 's/^/    /'
  check "compiles" "REFUSED" "ACCEPTED"
fi

note "arm 2 — RELEASE kernel as verifier (must refuse)"
if compile negative release_import.dill; then
  check "refuses the wrong verifier" "ACCEPTED" "REFUSED"
else
  { grep -oE "refused: .*" negative.log || tail -2 negative.log; } | head -1 | sed 's/^/    /'
  check "refuses the wrong verifier" "REFUSED" "REFUSED"
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "RESULT: NOT QUALIFIED — $fail check(s) failed. Nothing stamped."
  exit 1
fi
echo "RESULT: QUALIFIED for routeBDirectSuperDualKernelV1"
if [ "$STAMP" = "1" ]; then
  prov="$CELL/PROVENANCE.txt"
  [ -f "$prov" ] || die "no PROVENANCE.txt to stamp"
  if grep -q 'routeBDirectSuperDualKernelV1' "$prov"; then
    echo "  already stamped"
  else
    printf '\ncapability : routeBDirectSuperDualKernelV1 (qualified %s)\n' \
      "$(date -u +%FT%TZ)" >> "$prov"
    echo "  stamped into $prov"
  fi
  echo "  NOTE: the stamp records that this probe passed. What a consumer"
  echo "  actually relies on is the per-artifact SHA-256 check, which ties the"
  echo "  claim to the exact dart2bytecode that passed here."
fi
echo "work dir kept: $WORK"
