#!/usr/bin/env bash
# cspell:words dartaotruntime dynmod
#
# run_import_control.sh -- the durable assertion against regressing to 0015
# semantics: the corrected compiler must REFUSE a release import kernel and
# ACCEPT the patched one, for the same patch.
#
# The moved-site specimen makes this impossible to pass by accident:
#
#   release site  988
#   patch site   1005
#   target       identical in both
#
# so a compiler that looked the site up in the release body finds nothing at
# 1005, and one that matched on the target alone would still be reading the
# wrong body's argument list.
#
# 0016 = 0015 + target fingerprint agreement. 0015 stays UNSOUND AS DESIGNED.
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
WORK="${WORK:-$(mktemp -d)}"
DART_TREE="$SRC/flutter/third_party/dart"
DART="$OUT/dart-sdk/bin/dart"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
DART2BC="$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart"
GENERATOR="$DART_TREE/pkg/dart2bytecode/lib/bytecode_generator.dart"
GEN_SNAPSHOT="$OUT/gen_snapshot"
AOT_RUNTIME="$OUT/dartaotruntime"
URI=package:dynamic_modules/target.dart
REL="$HERE/../s2b1f/c1_release.dart"
PAT="$HERE/../s2b1f/c1_patch.dart"
mkdir -p "$WORK/lib" "$WORK/.dart_tool"; fail=0
note() { echo; echo "==> $*"; }
check() { if [ "$2" = "$3" ]; then printf '  PASS  %-38s %s\n' "$1" "$2";
          else printf '  FAIL  %-38s got %s want %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

BACKUP="$(mktemp)"; cp "$GENERATOR" "$BACKUP"
before=$(shasum -a 256 "$GENERATOR" | cut -d' ' -f1)
restore() { cp "$BACKUP" "$GENERATOR"
  after=$(shasum -a 256 "$GENERATOR" | cut -d' ' -f1); rm -f "$BACKUP"
  [ "$after" = "$before" ] || { echo "FATAL: generator not restored" >&2; exit 3; }
  echo; echo "dart2bytecode source restored, sha256 $after"; }
trap restore EXIT
python3 "$HERE/../s2b1/apply_0016.py" "$GENERATOR"

cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$WORK/",
    "packageUri": "lib/", "languageVersion": "3.9" } ] }
JSON
cd "$WORK"

cp "$REL" lib/target.dart
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o discover.dill "$URI" >/dev/null
"$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
  "$HERE/../../gen_dynamic_interface.dart" --dill discover.dill --out di.yaml >/dev/null
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
  -o release_aot.dill "$URI" >/dev/null
"$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
  --elf=target.aot release_aot.dill
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
  --no-aot --no-link-platform \
  --packages .dart_tool/package_config.json -o release_import.dill "$URI" >/dev/null

cp "$PAT" lib/target.dart
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o patched_aot.dill "$URI" >/dev/null
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
  --no-aot --no-link-platform \
  --packages .dart_tool/package_config.json -o patched_import.dill "$URI" >/dev/null
cp "$REL" lib/target.dart

sites() { "$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
    "$HERE/../s2b0/dump_sites.dart" "$1" "$OUT/vm_platform.dill" \
    package:dynamic_modules/ "$2" | grep '^{' | python3 -c "
import sys,json
for l in sys.stdin:
    d=json.loads(l)
    if d['site']=='Leaf.target': print(d['fileOffset']); break
else: print('MISSING')"; }
relOff=$(sites "$REL" release_import.dill)
patOff=$(sites "$PAT" patched_import.dill)
targets() { "$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
    "$HERE/../s2b1f/super_targets.dart" --dill "$1" \
    ${2:+--platform "$2"} --class Leaf --method target; }
fp=$(targets patched_import.dill "$OUT/vm_platform.dill" | python3 -c "
import sys,json;print(json.load(sys.stdin)[0]['fingerprint'])")
echo
echo "  release site offset $relOff / patch site offset $patOff"
echo "  target fingerprint  ${fp##*/}"
check "the site MOVED between versions" "$([ "$relOff" != "$patOff" ] && echo yes || echo no)" "yes"

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

arm() { # <label> <importDill> <wantCompile>
  note "$1"
  set +e
  "$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" \
    --import-dill "$2" -o "$1.bytecode" replacement.dart > "$1.log" 2>&1
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    { grep -oE "Route B direct-super intrinsic refused: .*" "$1.log" \
        || tail -2 "$1.log"; } | head -2 | sed 's/^/    /'
    check "compile" "REFUSED" "$3"
  else
    sed -n 's/^ROUTE_B_SUPER: /    /p' "$1.log" || true
    check "compile" "ACCEPTED" "$3"
    set +e
    "$AOT_RUNTIME" target.aot "$1.bytecode" "$URI" > "$1.run.log" 2>&1
    set -e
    local got; got=$(grep -E '^patched' "$1.run.log" | sed 's/.*: //' || true)
    check "execution" "${got:-<none>}" 'WRAP:TICKER:APP-STATE'
  fi
}

arm release_import release_import.dill REFUSED
arm patched_import patched_import.dill ACCEPTED

echo
[ "$fail" -eq 0 ] || { echo "RESULT: $fail check(s) FAILED"; exit 1; }
echo "RESULT: PASS — the corrected compiler refuses the release import kernel"
echo "        and accepts the patched one, on a specimen whose site moved."
echo "work dir kept: $WORK"
