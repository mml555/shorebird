#!/usr/bin/env bash
# cspell:words dartaotruntime dynmod
#
# run_2b1.sh -- D-SUPER-2B.1 host matrix for the COMPILER BACKSTOP.
#
# The intrinsic carries only origin/site identity. dart2bytecode rediscovers the
# original SuperMethodInvocation in its own import kernel and establishes the
# shape itself, so the producer cannot vouch for its own correctness.
#
# The replacement source is written HERE rather than by the producer, on purpose:
# this arm tests the compiler gate in isolation, including the case where a
# producer bug would have emitted an intrinsic for a super call that has
# arguments. `argGo` is exactly that case, and the AOT kernel reports zero
# arguments for it, so only the import kernel can catch it.
#
# 0015 is applied to the engine tree's dart2bytecode source and restored from a
# checksummed backup by a trap. No cell artifact is touched.
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
WORK="${WORK:-$(mktemp -d)}"
NO_BACKSTOP="${NO_BACKSTOP:-0}"

DART_TREE="$SRC/flutter/third_party/dart"
DART="$OUT/dart-sdk/bin/dart"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
DART2BC="$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart"
GENERATOR="$DART_TREE/pkg/dart2bytecode/lib/bytecode_generator.dart"
GEN_SNAPSHOT="$OUT/gen_snapshot"
AOT_RUNTIME="$OUT/dartaotruntime"
TARGET_URI="package:dynamic_modules/target_2b1.dart"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }
mkdir -p "$WORK"
fail=0
check() { if [ "$2" = "$3" ]; then printf '  PASS  %-42s %s\n' "$1" "$2";
          else printf '  FAIL  %-42s got %s want %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

BACKUP="$(mktemp)"; cp "$GENERATOR" "$BACKUP"
before=$(shasum -a 256 "$GENERATOR" | cut -d' ' -f1)
restore() {
  cp "$BACKUP" "$GENERATOR"
  after=$(shasum -a 256 "$GENERATOR" | cut -d' ' -f1); rm -f "$BACKUP"
  [ "$after" = "$before" ] || { echo "FATAL: generator not restored" >&2; exit 3; }
  echo; echo "dart2bytecode source restored, sha256 $after"
}
trap restore EXIT

note "applying 0015"
python3 "$HERE/apply_0015.py" "$GENERATOR"
if [ "$NO_BACKSTOP" = "1" ]; then
  # ADVERSARIAL ARM. Disable ONLY the independent shape check, leaving everything
  # else. The argument case must then become reachable — which is what shows the
  # shape check is the thing refusing it, rather than some other clause.
  note "ADVERSARIAL: disabling the independent shape check"
  python3 - "$GENERATOR" <<'PY'
import io, sys
p = sys.argv[1]; s = io.open(p, encoding='utf-8').read()
a = """    if (siteArgs.positional.isNotEmpty ||
        siteArgs.named.isNotEmpty ||
        siteArgs.types.isNotEmpty) {"""
assert s.count(a) == 1, 'shape check not found'
io.open(p, 'w', encoding='utf-8').write(
    s.replace(a, "    if (false) {", 1))
print('    shape check disabled')
PY
fi

mkdir -p "$WORK/lib" "$WORK/.dart_tool"
cp "$HERE/target_2b1.dart" "$WORK/lib/target_2b1.dart"
cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$WORK/",
    "packageUri": "lib/", "languageVersion": "3.9" } ] }
JSON
cd "$WORK"

note "release kernel + AOT snapshot"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o discover.dill "$TARGET_URI" >/dev/null
"$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
  "$HERE/../../gen_dynamic_interface.dart" --dill discover.dill --out di.yaml >/dev/null
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json \
  --dynamic-interface di.yaml -o target.dill "$TARGET_URI" >/dev/null
"$GEN_SNAPSHOT" --patchable_static_calls \
  --snapshot_kind=app-aot-elf --elf=target.aot target.dill
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
  --no-aot --no-link-platform \
  --packages .dart_tool/package_config.json -o host_import.dill "$TARGET_URI" >/dev/null

# The site offsets come from the kernel, never from a guess.
note "super-site offsets, read from the import kernel"
"$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
  "$HERE/../s2b0/dump_sites.dart" "$WORK/lib/target_2b1.dart" \
  "$OUT/vm_platform.dill" package:dynamic_modules/ "$WORK/host_import.dill" \
  | tee sites.txt | sed 's/^/    /'
offset_of() { python3 -c "
import json,sys
for l in open('sites.txt'):
    l=l.strip()
    if l.startswith('{'):
        d=json.loads(l)
        if d['site']=='$1': print(d['fileOffset']); break
else: print('MISSING')
"; }

# arm <entry> <originClass> <member> <site>
arm() {
  local entry=$1 cls=$2 member=$3 site=$4
  local off; off=$(offset_of "$site")
  note "arm $entry  (origin $cls.original, member $member, offset $off)"
  cat > replacement.dart <<DART
import 'package:dynamic_modules/target_2b1.dart';

@pragma('shorebird:direct-super')
Object? routeBSuper(Object receiver, String originLibrary, String originClass,
        String originMethod, int siteOffset, String member) =>
    throw StateError('Route B super intrinsic was not lowered');

@pragma('dyn-module:entry-point')
String $entry($cls self) => routeBSuper(
      self,
      '$TARGET_URI',
      '$cls',
      'original',
      $off,
      '$member',
    ) as String;
DART
  set +e
  "$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" \
    --import-dill host_import.dill -o "$entry.bytecode" replacement.dart \
    > "$entry.compile.log" 2>&1
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "    compiler REFUSED (exit $rc):"
    { grep -oE "Route B direct-super intrinsic refused: .*" \
        "$entry.compile.log" || tail -3 "$entry.compile.log"; } \
      | head -3 | sed 's/^/      /' || true
    echo "REFUSED" > "$entry.result"
    return
  fi
  set +e
  "$AOT_RUNTIME" target.aot "$entry.bytecode" "$entry" "$TARGET_URI" \
    > "$entry.run.log" 2>&1
  set -e
  { grep -E '^(unpatched|virtual|patched)' "$entry.run.log" || true; } \
    | sed 's/^/      /'
  { grep -E '^patched' "$entry.run.log" || true; } | sed 's/.*: //' \
    > "$entry.result"
}

arm lifeGo LifeState close LifeState.original
arm deepGo DeepLeaf close DeepLeaf.original
arm argGo  ArgLeaf  tag   ArgLeaf.original

note "verdict"
life=$(cat lifeGo.result 2>/dev/null || echo MISSING)
deep=$(cat deepGo.result 2>/dev/null || echo MISSING)
argr=$(cat argGo.result  2>/dev/null || echo MISSING)
if [ "$NO_BACKSTOP" = "1" ]; then
  check "mixin lifecycle    -> TICKER"        "$life" "TICKER:APP-STATE"
  check "deep hierarchy     -> DEEP-BASE"     "$deep" "DEEP-BASE:APP-STATE"
  # The observable here is COMPILER ACCEPTANCE, not a return value. With the
  # shape check disabled the emitted DirectCall passes only the receiver while
  # the target expects two more arguments, so the process aborts. That abort is
  # the consequence being prevented, not the measurement.
  if [ "$argr" = "REFUSED" ]; then
    echo "  FAIL  argument case still refused with the shape check disabled --"
    echo "        something OTHER than the shape check is refusing it, so this"
    echo "        harness does not show what the shape check is responsible for."
    fail=$((fail+1))
  else
    echo "  PASS  compiler ACCEPTED the argument case with the shape check"
    echo "        disabled, so that check is what refuses it. Consequence:"
    if grep -qE 'Abort trap|CRASH|error' argGo.run.log 2>/dev/null; then
      echo "          the replacement compiled and then ABORTED at run time"
    else
      echo "          ran and returned: ${argr:-<no value>}"
    fi
  fi
else
  check "mixin lifecycle    -> TICKER"        "$life" "TICKER:APP-STATE"
  check "deep hierarchy     -> DEEP-BASE"     "$deep" "DEEP-BASE:APP-STATE"
  check "super WITH ARGS    -> REFUSED"       "$argr" "REFUSED"
fi

echo
[ "$fail" -eq 0 ] || { echo "RESULT: $fail check(s) FAILED"; exit 1; }
echo "RESULT: PASS"
echo "work dir kept: $WORK"
