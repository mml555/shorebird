#!/usr/bin/env bash
#
# run_collide.sh -- 2B.1c-SITE, the dangerous direction, measured.
#
# Release and patch are byte-aligned at the super site, so `close` sits at the
# same offset with the same member name in both source versions. The only thing
# that differs is the ARGUMENT LIST -- and 0015's argument check reads the
# RELEASE body, not the patched one.
#
# The producer's source gate would refuse this patch. This arm asks what the
# COMPILER does on its own, which is the whole claim of "an independent
# backstop": if the compiler is reading the wrong body, its independence does
# not survive a cross-version patch.
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
mkdir -p "$WORK"

BACKUP="$(mktemp)"; cp "$GENERATOR" "$BACKUP"
before=$(shasum -a 256 "$GENERATOR" | cut -d' ' -f1)
restore() { cp "$BACKUP" "$GENERATOR"
  after=$(shasum -a 256 "$GENERATOR" | cut -d' ' -f1); rm -f "$BACKUP"
  [ "$after" = "$before" ] || { echo "FATAL: generator not restored" >&2; exit 3; }
  echo; echo "dart2bytecode source restored, sha256 $after"; }
trap restore EXIT
python3 "$HERE/../s2b1/apply_0015.py" "$GENERATOR"

mkdir -p "$WORK/lib" "$WORK/.dart_tool"
cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$WORK/",
    "packageUri": "lib/", "languageVersion": "3.9" } ] }
JSON
cd "$WORK"

# The RELEASE is what ships and what the replacement compiles against.
cp "$HERE/collide_release.dart" lib/target.dart
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o discover.dill "$URI" >/dev/null
"$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
  "$HERE/../../gen_dynamic_interface.dart" --dill discover.dill --out di.yaml >/dev/null
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
  -o target.dill "$URI" >/dev/null
"$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
  --elf=target.aot target.dill
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
  --no-aot --no-link-platform \
  --packages .dart_tool/package_config.json -o host_import.dill "$URI" >/dev/null

OFFSET="${OFFSET:-1074}"
echo
echo "==> the intrinsic points at offset $OFFSET, which in the PATCHED source is"
echo "    super.close('x') and in the RELEASE source is super.close(   )"

cat > replacement.dart <<DART
import 'package:dynamic_modules/target.dart';

@pragma('shorebird:direct-super')
Object? routeBSuper(Object receiver, String originLibrary, String originClass,
        String originMember, String originMemberKind, int siteOffset,
        String member) =>
    throw StateError('not lowered');

@pragma('dyn-module:entry-point')
String go(Leaf self) => routeBSuper(
      self, '$URI', 'Leaf', 'original', 'Method', $OFFSET, 'close') as String;
DART

set +e
"$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" \
  --import-dill host_import.dill -o replacement.bytecode replacement.dart \
  > compile.log 2>&1
rc=$?
set -e
echo
if [ "$rc" -ne 0 ]; then
  echo "compiler REFUSED (exit $rc):"
  { grep -oE "Route B direct-super intrinsic refused: .*" compile.log || tail -2 compile.log; } | head -2 | sed 's/^/    /'
  echo
  echo "RESULT: the compiler caught it. The backstop reads a body in which this"
  echo "        site has arguments."
  exit 0
fi

echo "compiler ACCEPTED."
set +e
"$AOT_RUNTIME" target.aot replacement.bytecode "$URI" > run.log 2>&1
set -e
grep -E '^(release|virtual|attach|patched)' run.log | sed 's/^/    /' || true
got=$(grep -E '^patched' run.log | sed 's/.*: //' || true)
echo
echo "  the patch author wrote : super.close('x')   -> BASE:x:APP"
echo "  what actually executes : ${got:-<none>}"
echo
if [ "$got" = "BASE:NONE:APP" ]; then
  echo "RESULT: SILENT WRONG SEMANTICS. The compiler verified the RELEASE body's"
  echo "        argument list (empty) for a site the PATCH wrote with one"
  echo "        argument, emitted a receiver-only DirectCall, and the patch runs"
  echo "        and returns a different value than the source it stands in for."
  exit 1
fi
echo "RESULT: accepted, and produced $got. Investigate before concluding."
exit 1
