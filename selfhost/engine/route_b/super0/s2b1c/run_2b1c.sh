#!/usr/bin/env bash
# cspell:words dartaotruntime dynmod
#
# run_2b1c.sh -- the SHIPPING producer, end to end, over a real changed method.
#
#   analyzer v10  ->  superInvocations + origin
#   producer      ->  source gate, then the pragma intrinsic with site identity
#   dart2bytecode ->  independent import-kernel recheck, local hierarchy, DirectCall
#
# The replacement source is written by the PRODUCER here, not by this harness --
# that is the difference from `s2b1/run_2b1.sh`, which isolated the compiler.
#
# Uses a THROWAWAY cell (mint_throwaway_cell.sh). Never a published one.
#
# STATUS: WORK IN PROGRESS. The producer and compiler halves are proven
# separately (s2b1/, and the unit tests in route_b_producer_test.dart). This
# harness does not yet pass: the specimen's base and patched kernels differ in
# FOUR members rather than one, because TFA specialises the super targets
# differently on the two sides, and the producer then fails compiling an
# unrelated changed member. Building a specimen where only the target's body
# differs under `--aot --tfa` is the remaining work. Kept in-tree because the
# plumbing (throwaway cell, producer invocation, observables) is correct and the
# failure is specimen-shaped.
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../../../../.." >/dev/null 2>&1 && pwd)"
WORK="${WORK:-$(mktemp -d)}"
CELL_ZIP="${CELL_ZIP:?set CELL_ZIP to the throwaway cell}"
ENGINE_HASH="${ENGINE_HASH:-4792f0eca461f3761001a1adbe131b4b115e3684}"
MUTATE_SOURCE_GATE="${MUTATE_SOURCE_GATE:-0}"
PATCHED="${PATCHED:-$HERE/patched.dart}"

DART_TREE="$SRC/flutter/third_party/dart"
DART="$OUT/dart-sdk/bin/dart"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
GEN_SNAPSHOT="$OUT/gen_snapshot"
AOT_RUNTIME="$OUT/dartaotruntime"
CLI_PKGS="${CLI_PKGS:-$REPO/.dart_tool/package_config.json}"
GATE="$REPO/packages/shorebird_cli/lib/src/route_b_super_source.dart"
TARGET_URI="package:dynamic_modules/target.dart"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }
mkdir -p "$WORK"; fail=0
check() { if [ "$2" = "$3" ]; then printf '  PASS  %-40s %s\n' "$1" "$2";
          else printf '  FAIL  %-40s got %s want %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

[ -f "$CELL_ZIP" ] || die "no throwaway cell at $CELL_ZIP"
export ROUTE_B_ENGINE_HASH="$ENGINE_HASH"

BACKUP="$(mktemp)"; cp "$GATE" "$BACKUP"
before=$(shasum -a 256 "$GATE" | cut -d' ' -f1)
restore() {
  cp "$BACKUP" "$GATE"
  after=$(shasum -a 256 "$GATE" | cut -d' ' -f1); rm -f "$BACKUP"
  [ "$after" = "$before" ] || { echo "FATAL: source gate not restored" >&2; exit 3; }
  echo; echo "source gate restored, sha256 $after"
}
trap restore EXIT

if [ "$MUTATE_SOURCE_GATE" = "1" ]; then
  # CROSS-GATE MUTATION. Break the PRODUCER's admission gate so it emits an
  # intrinsic for a super call that has arguments. The compiler must still
  # refuse, from the import kernel, with no help from anything here.
  note "MUTATION: routeBSuperCallArgs forced to zeroArguments"
  python3 - "$GATE" <<'PY'
import io, sys
p = sys.argv[1]; s = io.open(p, encoding='utf-8').read()
a = """}) => _read(source: source, offset: offset, member: member).args;"""
assert s.count(a) == 1, 'gate body not found'
io.open(p, 'w', encoding='utf-8').write(
    s.replace(a, """}) => RouteBSuperArgs.zeroArguments; // MUTATION -- restored by trap""", 1))
print('    producer source gate disabled')
PY
fi

mkdir -p "$WORK/lib" "$WORK/.dart_tool"
cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$WORK/",
    "packageUri": "lib/", "languageVersion": "3.9" } ] }
JSON

kernel() { ( cd "$WORK" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
    "${@:2}" --packages .dart_tool/package_config.json -o "$1" "$TARGET_URI" ) >/dev/null 2>&1; }

note "release kernel + AOT snapshot"
cp "$HERE/base.dart" "$WORK/lib/target.dart"
kernel "$WORK/discover.dill" --aot || die "discovery kernel failed"
"$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
  "$HERE/../../gen_dynamic_interface.dart" --dill discover.dill --out "$WORK/di.yaml" >/dev/null 2>&1 \
  || ( cd "$WORK" && "$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
        "$HERE/../../gen_dynamic_interface.dart" --dill discover.dill --out di.yaml >/dev/null )
( cd "$WORK" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
    --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
    -o base.dill "$TARGET_URI" ) >/dev/null 2>&1 || die "release kernel failed"
"$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
  --elf="$WORK/target.aot" "$WORK/base.dill"
kernel "$WORK/import.dill" --no-aot --no-link-platform || die "import kernel failed"

note "patched kernel, from the CHANGED application source"
cp "$PATCHED" "$WORK/lib/target.dart"
kernel "$WORK/patched.dill" --aot || die "patched kernel failed"
cp "$HERE/base.dart" "$WORK/lib/target.dart"   # the release's source stays on disk

note "SHIPPING producer"
set +e
"$DART" --packages="$CLI_PKGS" \
  "$REPO/selfhost/engine/route_b/producer/cli_produce.dart" \
  "$CELL_ZIP" "$WORK/base.dill" "$WORK/patched.dill" "$WORK/import.dill" \
  deadbeefcafe "$WORK/out" "$WORK" > "$WORK/produce.log" 2>&1
prc=$?
set -e
if [ "$prc" -ne 0 ]; then
  echo "  producer REFUSED (exit $prc)"
  grep -oE "(RouteBUnsupportedTarget|Route B [^\\\"]*)" "$WORK/produce.log" | head -2 | sed 's/^/    /' || true
  grep -oE "Route B direct-super intrinsic refused: .*" "$WORK/produce.log" | head -1 | sed 's/^/    /' || true
  tail -3 "$WORK/produce.log" | sed 's/^/    /'
  echo "REFUSED" > "$WORK/verdict"
else
  sed 's/^/    /' "$WORK/produce.log"
  echo "ACCEPTED" > "$WORK/verdict"
fi

verdict=$(cat "$WORK/verdict")
repl="$WORK/out/replacement_0.dart"

if [ "$MUTATE_SOURCE_GATE" = "1" ]; then
  note "cross-gate verdict"
  check "producer gate disabled -> still REFUSED" "$verdict" "REFUSED"
  if grep -q "takes arguments" "$WORK/produce.log"; then
    echo "  PASS  and the refusal came from the COMPILER's own import-kernel check"
  else
    echo "  FAIL  refused, but not by the compiler's argument check"; fail=$((fail+1))
  fi
  echo; [ "$fail" -eq 0 ] || { echo "RESULT: $fail check(s) FAILED"; exit 1; }
  echo "RESULT: PASS"; echo "work dir kept: $WORK"; exit 0
fi

note "the EMITTED replacement source"
[ -f "$repl" ] || die "no replacement emitted"
sed 's/^/    /' "$repl"

note "verdict"
check "producer" "$verdict" "ACCEPTED"
grep -q "shorebird:direct-super" "$repl" && r1=yes || r1=no
check "emits the pragma intrinsic" "$r1" "yes"
grep -q "super\." "$repl" && r2=yes || r2=no
check 'no super. survives in the replacement' "$r2" "no"
n=$(grep -c 'routeBSuper(' "$repl" || true)
check "both super calls rewritten" "$n" "3"   # 1 declaration + 2 call sites

note "execute"
set +e
"$AOT_RUNTIME" "$WORK/target.aot" "$WORK/out/replacement_0.bytecode" \
  "$TARGET_URI" > "$WORK/run.log" 2>&1
set -e
grep -E '^(virtual|before|attach|patched)' "$WORK/run.log" | sed 's/^/    /' || true
got=$(grep -E '^patched' "$WORK/run.log" | sed 's/.*: //' || true)
check "executes the exact super targets" "$got" "TICKER:APP-STATE|QUIET:APP-STATE"

echo
[ "$fail" -eq 0 ] || { echo "RESULT: $fail check(s) FAILED"; exit 1; }
echo "RESULT: PASS"
echo "work dir kept: $WORK"
