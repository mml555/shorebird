#!/usr/bin/env bash
# cspell:words dartaotruntime dynmod
#
# run_2b1d.sh -- can a DirectCall derived from a PATCHED no-AOT import kernel
# bind against the already-built RELEASE AOT?
#
# D-SUPER-1 proved binding with a RELEASE-derived import graph. Changing the
# import component to the patched source changes what the reference is resolved
# against, and that is a different fact. 0015's lookup CODE is unchanged here --
# only which dill it reads -- which is exactly why this must be proven rather
# than declared.
#
# 0015 stays UNSOUND AS DESIGNED. This probe does not repair it.
#
# Harness note: the replacement's entry point is the top-level `go`, because
# `attachBytecodeToFunction` locates a top-level name. The ORIGIN identity still
# names `<Class>.target`, the method whose body the patch changed, which is what
# the compiler rediscovers. The mechanism does not require the two to coincide;
# in production they would.
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
WORK="${WORK:-$(mktemp -d)}"
MUTATE_VIRTUAL="${MUTATE_VIRTUAL:-0}"

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
check() { if [ "$2" = "$3" ]; then printf '    PASS  %-36s %s\n' "$1" "$2";
          else printf '    FAIL  %-36s got %s want %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

BACKUP="$(mktemp)"; cp "$GENERATOR" "$BACKUP"
before=$(shasum -a 256 "$GENERATOR" | cut -d' ' -f1)
restore() { cp "$BACKUP" "$GENERATOR"
  after=$(shasum -a 256 "$GENERATOR" | cut -d' ' -f1); rm -f "$BACKUP"
  [ "$after" = "$before" ] || { echo "FATAL: generator not restored" >&2; exit 3; }
  echo; echo "dart2bytecode source restored, sha256 $after"; }
trap restore EXIT
python3 "$HERE/../s2b1/apply_0015.py" "$GENERATOR"
if [ "$MUTATE_VIRTUAL" = "1" ]; then
  note "MUTATION: direct call -> ordinary virtual dispatch"
  python3 - "$GENERATOR" <<'PY'
import io, sys
p = sys.argv[1]; s = io.open(p, encoding='utf-8').read()
a = """    _genDirectCallWithArgs(resolved, noArgs,
        hasReceiver: true, isUnchecked: true, node: node);"""
assert s.count(a) == 1
io.open(p, 'w', encoding='utf-8').write(s.replace(a, """    _genInstanceCall(node, InvocationKind.method, null,
        Name(memberName), receiver, 1, objectTable.getArgDescHandle(1));""", 1))
print('    direct call replaced')
PY
fi

# arm <name> <releaseSrc> <patchSrc> <originClass> <member> <expected>
arm() {
  local name=$1 rel=$2 pat=$3 cls=$4 member=$5 want=$6
  local W="$WORK/$name"; mkdir -p "$W/lib" "$W/.dart_tool"
  cat > "$W/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$W/",
    "packageUri": "lib/", "languageVersion": "3.9" } ] }
JSON
  note "arm $name"

  # RELEASE: the app that ships, and the thing the DirectCall must bind against.
  cp "$HERE/$rel" "$W/lib/target.dart"
  ( cd "$W" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
      --packages .dart_tool/package_config.json -o discover.dill "$URI" ) >/dev/null
  ( cd "$W" && "$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
      "$HERE/../../gen_dynamic_interface.dart" --dill discover.dill --out di.yaml ) >/dev/null
  ( cd "$W" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
      --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
      -o target.dill "$URI" ) >/dev/null
  "$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
    --elf="$W/target.aot" "$W/target.dill"

  # PATCH: both kernels, so observable 1 can compare them.
  cp "$HERE/$pat" "$W/lib/target.dart"
  ( cd "$W" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
      --packages .dart_tool/package_config.json -o patched_aot.dill "$URI" ) >/dev/null
  ( cd "$W" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
      --no-aot --no-link-platform \
      --packages .dart_tool/package_config.json -o patched_noaot.dill "$URI" ) >/dev/null
  # The RELEASE source stays on disk: it is what shipped.
  cp "$HERE/$rel" "$W/lib/target.dart"

  offs() { "$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
      "$HERE/../s2b0/dump_sites.dart" "$HERE/$pat" "$OUT/vm_platform.dill" \
      package:dynamic_modules/ "$W/$1" | grep '^{' \
      | python3 -c "
import sys,json
for l in sys.stdin:
    d=json.loads(l)
    if d['site']=='$cls.target' and d['member']=='$member':
        print(d['fileOffset']); break
else: print('MISSING')"; }
  local aotOff noaotOff
  aotOff=$(offs patched_aot.dill); noaotOff=$(offs patched_noaot.dill)
  echo "    patched AOT offset $aotOff / patched no-AOT offset $noaotOff"
  check "obs1 analyzer offset == import offset" "$aotOff" "$noaotOff"
  [ "$aotOff" != "MISSING" ] || { fail=$((fail+1)); return; }

  cat > "$W/replacement.dart" <<DART
import 'package:dynamic_modules/target.dart';

@pragma('shorebird:direct-super')
Object? routeBSuper(Object receiver, String originLibrary, String originClass,
        String originMember, String originMemberKind, int siteOffset,
        String member) =>
    throw StateError('not lowered');

@pragma('dyn-module:entry-point')
String go($cls self) => routeBSuper(
      self, '$URI', '$cls', 'target', 'Method', $aotOff, '$member') as String;
DART

  set +e
  ( cd "$W" && "$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" \
      --import-dill patched_noaot.dill -o replacement.bytecode replacement.dart ) \
    > "$W/compile.log" 2>&1
  local rc=$?
  set -e
  sed -n 's/^ROUTE_B_SUPER: /    /p' "$W/compile.log" || true
  if [ "$rc" -ne 0 ]; then
    echo "    compiler REFUSED (exit $rc)"
    { grep -oE "Route B direct-super intrinsic refused: .*" "$W/compile.log" \
        || tail -2 "$W/compile.log"; } | head -2 | sed 's/^/      /'
    check "obs2 rediscovered in patched import" "no" "yes"
    return
  fi
  grep -q 'rediscovered site' "$W/compile.log" && r2=yes || r2=no
  grep -q 'selected ' "$W/compile.log" && r3=yes || r3=no
  grep -q 'emitting receiver-taking direct call' "$W/compile.log" && r4=yes || r4=no
  check "obs2 rediscovered in patched import" "$r2" "yes"
  check "obs3 target identity recorded" "$r3" "yes"
  check "obs4 direct-call path taken" "$r4" "yes"

  set +e
  ( cd "$W" && "$AOT_RUNTIME" target.aot replacement.bytecode "$URI" ) \
    > "$W/run.log" 2>&1
  set -e
  grep -E '^(unpatched|virtual|attach|patched)' "$W/run.log" | sed 's/^/      /' || true
  local att got
  att=$(grep -E '^attach' "$W/run.log" | sed 's/.*: //' || true)
  got=$(grep -E '^patched' "$W/run.log" | sed 's/.*: //' || true)
  check "obs5 release AOT binds it" "${att:-<none>}" "true"
  check "obs6 stateful execution" "${got:-<none>}" "$want"
}

if [ "$MUTATE_VIRTUAL" = "1" ]; then
  arm armA armA_release.dart armA_patch.dart AChild read  'CHILD:APP-STATE'
  arm armB armB_release.dart armB_patch.dart Leaf   close 'LEAF:APP-STATE'
  arm armC armC_release.dart armC_patch.dart Leaf   close 'LEAF:APP-STATE'
  arm armD armD_release.dart armD_patch.dart AChild read  'CHILD:APP-STATE'
else
  arm armA armA_release.dart armA_patch.dart AChild read  'PARENT:APP-STATE'
  arm armB armB_release.dart armB_patch.dart Leaf   close 'TICKER:APP-STATE'
  arm armC armC_release.dart armC_patch.dart Leaf   close 'TICKER:APP-STATE'
  arm armD armD_release.dart armD_patch.dart AChild read  'PARENT:APP-STATE'
fi

echo
[ "$fail" -eq 0 ] || { echo "RESULT: $fail check(s) FAILED"; exit 1; }
echo "RESULT: PASS"
echo "work dir kept: $WORK"
