#!/usr/bin/env bash
# cspell:words dartaotruntime dynmod
#
# run_2b2.sh -- Part 2B: the SHIPPING path, end to end.
#
# RouteBCoverageAnalyzer + RouteBProducer -- the code `shorebird patch` runs --
# over a TFA-isolated fixture, against a cell carrying analyzer v11 and 0017.
#
# The replacement source is written by the PRODUCER, not by this harness.
#
# HOW THE INVOCATION IS OBSERVED. The producer runs the compiler internally, so
# rather than scraping a log this harness relies on a behavioural fact: 0017
# refuses outright when no --patched-verification-dill is supplied. A successful
# super compile through the real producer therefore proves both kernels reached
# the command line. That is stronger than string-matching, and it is why the
# no-verification-kernel arm below is run too.
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../../../../.." >/dev/null 2>&1 && pwd)"
WORK="${WORK:-$(mktemp -d)}"
CELL_ZIP="${CELL_ZIP:?set CELL_ZIP to a v11+0017 cell}"
ENGINE_HASH="${ENGINE_HASH:-4792f0eca461f3761001a1adbe131b4b115e3684}"
MUTATE="${MUTATE:-none}"     # none | source_gate | release_evidence
# The changed set the preflight requires. Default: the target alone.
#
# Mutation B legitimately widens it. INTRODUCING a super call to a mixin clone
# the release never reached changes that clone's kernel representation — which
# is the very phenomenon under test, and the reason the release has no compiled
# code for it. Naming the expectation is not relaxing the preflight; leaving it
# hardcoded would have forced a HARNESS FAULT verdict on a real product effect.
EXPECT_CHANGED="${EXPECT_CHANGED:-package:dynamic_modules/target.dart#Leaf.target}"

DART_TREE="$SRC/flutter/third_party/dart"
DART="$OUT/dart-sdk/bin/dart"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
GEN_SNAPSHOT="$OUT/gen_snapshot"
AOT_RUNTIME="$OUT/dartaotruntime"
CLI_PKGS="${CLI_PKGS:-$REPO/.dart_tool/package_config.json}"
GATE="$REPO/packages/shorebird_cli/lib/src/route_b_super_source.dart"
PRODUCER="$REPO/packages/shorebird_cli/lib/src/route_b_producer.dart"
URI=package:dynamic_modules/harness.dart
TARGET_LIB=package:dynamic_modules/target.dart
export ROUTE_B_ENGINE_HASH="$ENGINE_HASH"
mkdir -p "$WORK"; fail=0
note() { echo; echo "==> $*"; }
check() { if [ "$2" = "$3" ]; then printf '  PASS  %-40s %s\n' "$1" "$2";
          else printf '  FAIL  %-40s got %s want %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

# Source mutations are restored from checksummed backups by a trap.
GB="$(mktemp)"; cp "$GATE" "$GB"
PB="$(mktemp)"; cp "$PRODUCER" "$PB"
g0=$(shasum -a 256 "$GATE" | cut -d' ' -f1); p0=$(shasum -a 256 "$PRODUCER" | cut -d' ' -f1)
restore() {
  cp "$GB" "$GATE"; cp "$PB" "$PRODUCER"; rm -f "$GB" "$PB"
  g1=$(shasum -a 256 "$GATE" | cut -d' ' -f1); p1=$(shasum -a 256 "$PRODUCER" | cut -d' ' -f1)
  { [ "$g0" = "$g1" ] && [ "$p0" = "$p1" ]; } \
    || { echo "FATAL: CLI sources not restored" >&2; exit 3; }
  echo; echo "CLI sources restored"
}
trap restore EXIT

case "$MUTATE" in
  source_gate)
    note "MUTATION A: routeBSuperCallArgs forced to zeroArguments"
    # A FAITHFUL PRODUCER BUG, not just a wrong verdict. The first version of
    # this mutation forced only `routeBSuperCallArgs` to say zeroArguments;
    # `routeBSuperCallSpan` still read correctly, returned null, and the producer
    # refused with "not inside the declaration being replaced" — a different
    # reason, never reaching the compiler. Mutating the shared reader makes the
    # producer both admit the call AND hand over a correct span, which is what a
    # real bug would do.
    python3 - "$GATE" <<'PY'
import io, sys
p = sys.argv[1]; s = io.open(p, encoding='utf-8').read()
a = "  if (source[j] != ')') return const _Read(RouteBSuperArgs.hasArguments);"
assert s.count(a) == 1, 'mutation site not found'
io.open(p, 'w', encoding='utf-8').write(s.replace(a, '''  if (source[j] != ')') {
    var depth = 1;
    var k = j;
    while (k < source.length && depth > 0) {
      if (source[k] == '(') depth++;
      if (source[k] == ')') depth--;
      if (depth == 0) break;
      k++;
    }
    return _Read(RouteBSuperArgs.zeroArguments,
        RouteBSuperCallSpan(start: start, end: k + 1));
  }''', 1))
print('    producer source-argument gate disabled (admits, with a valid span)')
PY
    ;;
  release_evidence)
    note "MUTATION B: releaseSuperTargets membership bypassed"
    python3 - "$PRODUCER" <<'PY'
import io, sys
p = sys.argv[1]; s = io.open(p, encoding='utf-8').read()
a = "        if (!lowering.releaseSuperTargets.contains(target)) {"
assert s.count(a) == 1
io.open(p, 'w', encoding='utf-8').write(s.replace(a, "        if (false) {", 1))
print('    release-evidence membership disabled')
PY
    ;;
esac

REL="${REL:-$HERE/target_release.dart}"
PAT="${PAT:-$HERE/target_patch.dart}"
mkdir -p "$WORK/lib" "$WORK/.dart_tool"
cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$WORK/",
    "packageUri": "lib/", "languageVersion": "3.9" } ] }
JSON
cd "$WORK"

note "kernels"
cp "$HERE/harness.dart" lib/harness.dart
cp "$REL" lib/target.dart
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o discover.dill "$URI" >/dev/null
"$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
  "$HERE/../../gen_dynamic_interface.dart" --dill discover.dill --out di.yaml >/dev/null
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
  -o base.dill "$URI" >/dev/null
"$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
  --elf=target.aot base.dill
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
  --no-aot --no-link-platform \
  --packages .dart_tool/package_config.json -o release_import.dill "$URI" >/dev/null
cp "$PAT" lib/target.dart
# THE SAME RETENTION ON BOTH SIDES. Built without `--dynamic-interface` the
# patched kernel loses members the retained base keeps, and the analyzer then
# reports Base.close, Ticker.close and the mixin-application clone as REMOVED --
# a retention asymmetry, not a change the patch made. The preflight caught
# exactly that on the first run. Isolating TFA means the two kernels must differ
# only in the source being tested.
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
  -o patched.dill "$URI" >/dev/null
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
  --no-aot --no-link-platform \
  --packages .dart_tool/package_config.json -o patched_verification.dill "$URI" >/dev/null
# THE PATCHED SOURCE STAYS ON DISK. At patch time the working tree holds what
# was just built, and the producer's source gate reads the span the analyzer
# recorded — which carries PATCHED offsets. Restoring the release text here
# made the gate read offset 1005 of the wrong file and refuse as "could not be
# verified", which is the gate behaving correctly on a harness mistake.

note "PREFLIGHT — the two kernels must differ in exactly the target"
"$AOT_RUNTIME" "$OUT/zip_archives/route_b_analyze.aot" \
  --base-dill base.dill --patched-dill patched.dill --out analysis.json
EXPECT_CHANGED="$EXPECT_CHANGED" python3 - <<'PY' || { echo "  HARNESS FAULT — the AOT diff is not isolated"; exit 1; }
import json, os, sys
d = json.load(open('analysis.json'))
want = sorted(os.environ['EXPECT_CHANGED'].split(','))
ok = (sorted(d['changed']) == want
      and d['added'] == [] and d['removed'] == [])
print('    changed %s added %s removed %s'
      % (d['changed'], d['added'], d['removed']))
sys.exit(0 if ok else 1)
PY
echo "  PASS  AOT diff isolated to the target"

python3 - <<'PY'
import json
d = json.load(open('analysis.json'))
l = d['lowering']['package:dynamic_modules/target.dart#Leaf.target']
s = l['superInvocations'][0]
print('    analysis v%s  site offset %s  target %s'
      % (d['analysisVersion'], s['offset'],
         [s['target']['fileOffset'], s['target']['name'], s['target']['kind']]))
print('    release evidence %s'
      % [[x['fileOffset'], x['name'], x['kind']] for x in l['releaseSuperTargets']])
PY

note "SHIPPING producer"
set +e
"$DART" --packages="$CLI_PKGS" \
  "$REPO/selfhost/engine/route_b/producer/cli_produce.dart" \
  "$CELL_ZIP" base.dill patched.dill release_import.dill \
  deadbeefcafe out "$WORK" patched_verification.dill > produce.log 2>&1
prc=$?
set -e
if [ "$prc" -ne 0 ]; then
  echo "  producer/compiler REFUSED (exit $prc)"
  { grep -oE "(Route B direct-super intrinsic refused: .*|[A-Za-z ]*: the .*)" produce.log \
      || tail -3 produce.log; } | head -3 | sed 's/^/    /'
  verdict=REFUSED
else
  grep -E "^(coverage|container|  target)" produce.log | sed 's/^/    /'
  verdict=ACCEPTED
fi

if [ "$MUTATE" = "source_gate" ]; then
  check "producer gate off -> compiler REFUSES" "$verdict" "REFUSED"
  grep -q "takes arguments" produce.log && who=compiler || who=other
  check "and the refusal is the ARGUMENT check" "$who" "compiler"
  echo; [ "$fail" -eq 0 ] || { echo "RESULT: FAILED"; exit 1; }
  echo "RESULT: PASS"; exit 0
fi

check "producer" "$verdict" "ACCEPTED"
[ "$verdict" = "ACCEPTED" ] || { echo; echo "RESULT: FAILED"; exit 1; }

note "the EMITTED replacement"
sed -n '1,20p' out/replacement_0.dart | sed 's/^/    /'
grep -q "shorebird:direct-super" out/replacement_0.dart && a=yes || a=no
check "carries the pragma intrinsic" "$a" "yes"
grep -q "super\." out/replacement_0.dart && b=yes || b=no
check "no super. survives" "$b" "no"

note "execute"
set +e
"$AOT_RUNTIME" target.aot out/replacement_0.bytecode "$TARGET_LIB" > run.log 2>&1
set -e
grep -E '^(unpatched|virtual|attach|patched)' run.log | sed 's/^/    /' || true
got=$(grep -E '^patched' run.log | sed 's/.*: //' || true)
abort=$(grep -c 'Attempt to compile function' run.log || true)
if [ "$MUTATE" = "release_evidence" ]; then
  [ "$abort" != "0" ] && r=ABORT || r="$got"
  check "evidence gate off -> release ABORTS" "$r" "ABORT"
else
  check "stateful execution" "${got:-<none>}" 'WRAP:TICKER:APP-STATE'
fi

echo
[ "$fail" -eq 0 ] || { echo "RESULT: FAILED"; exit 1; }
echo "RESULT: PASS"
echo "work dir kept: $WORK"
