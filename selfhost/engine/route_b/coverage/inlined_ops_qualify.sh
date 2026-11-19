#!/usr/bin/env bash
# cspell:words dartaotruntime tfa
#
# inlined_ops_qualify.sh -- does the analyzer's `inlined` flag (analysis 21)
# agree with what the shipped compiler really emits for the PRODUCER'S output?
#
# The flag is a claim about the bytecode of the slice the producer hands to
# dart2bytecode, not about the patched source: the producer lowers an instance
# member to a static taking `self`, rewrites `super.x` to
# `$routeBSuper(...) as dynamic`, and so on. So this script runs the REAL
# producer (`RouteBProducer.produce`, through tool/route_b_lower_fixture.dart)
# over every member of inlined_ops_fixture.dart, with the real dart2bytecode
# behind it, dumps each target's bytecode, and compares it with the BUILT
# analyzer's references for the same member:
#
#   flagged   =>  the bytecode has NO InterfaceCall / DynamicCall to that selector
#   flagged   =>  every opcode the analyzer names is one that selector can have,
#                 and is in that target's bytecode
#   unflagged =>  the bytecode has a call to that selector (else the analyzer
#                 and the compiler have drifted and a patch is lost for nothing)
#                 -- except `conservative__` targets, which must be unflagged
#                 and may compile either way (a body with a `super.` anywhere)
#   yes__<x>  =>  every operator reference is flagged, and there is at least one
#   no__<x>   =>  there is an operator reference and it is not flagged
#
# It FAILS (exit 1) on any mismatch in either direction, and on a run that
# compared nothing: fewer than MIN_TARGETS targets, no flagged and no unflagged
# reference, or a target the producer refused that is not listed as expected.
#
# The fixture is compiled the way a release is: flutter target, --aot --tfa.
#
# usage: inlined_ops_qualify.sh <route_b_analyze.aot> [--compiler-aot <dart2bytecode.aot> --runtime <dartaotruntime>] [--out <engine out dir>] [--require-v21]
#   With --compiler-aot the CELL's shipped compiler is the one compared against
#   (the check that matters: the analyzer's imported RecognizedMethods may have
#   drifted from it). Without it the engine tree's dart2bytecode source runs
#   under JIT, which only proves the two trees agree. The cell mint runs it with
#   the cell's own files (mint_route_b_cell.sh); do not publish a v21 cell that
#   has not passed it.
#   An analyzer older than analysis 21 is not qualified: that is "nothing to
#   qualify" (exit 0) unless --require-v21.
#
# NOT COVERED (so a pass is not over-read): a private MEMBER of a lowered class
# (the fixture tool has no capability manifest, so one is refused: only a
# private receiver CLASS with public members is exercised), a super call in a
# private class, mixins/extensions/enums as receivers, the analyzer's
# treatment of a TFA-shaken program other than this fixture's, and a generic
# class's member whose body uses its type parameter (the producer refuses it,
# so `Gen.no__gen_t` and `Box.yes__box_len` count as expected refusals).
#
# RUNTIME: one producer compile per target (~170 targets). Under the tree's JIT
# dart2bytecode that is ~10 s each (about 40 minutes on a shared host); with
# --compiler-aot (what the mint passes) it is a few seconds each. Run it with
# the cell's compiler whenever a cell is being minted. ONLY=<substring> narrows
# the targets for a quick look (the floor then fails, by design: a narrowed run
# qualifies nothing).
set -euo pipefail

ANALYZER=${1:?usage: inlined_ops_qualify.sh <route_b_analyze.aot> [options]}
shift
SRC=${SRC:-$HOME/shorebird-engine/flutter/engine/src}
OUT=$SRC/out/host_release_arm64_ddm
COMPILER_AOT=; RUNTIME=; REQUIRE=0; PLATFORM=
while [ $# -gt 0 ]; do
  case "$1" in
    --compiler-aot) COMPILER_AOT=$2; shift 2 ;;
    --runtime) RUNTIME=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --flutter-platform) PLATFORM=$2; shift 2 ;;
    --require-v21) REQUIRE=1; shift ;;
    *) echo "ERROR: unknown argument $1" >&2; exit 1 ;;
  esac
done
DT=$SRC/flutter/third_party/dart
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }

# The Dart CI runs (tool/find_dart.sh; DART_BIN names one), not whatever is first.
if [ -z "${DART_BIN:-}" ]; then
  source "$REPO/tool/find_dart.sh"
  find_dart "$REPO"
  DART_BIN=$dart_bin
fi
[ -n "$DART_BIN" ] && [ -x "$DART_BIN" ] || die "no Dart of the version CI runs (tool/find_dart.sh); set DART_BIN"
[ -f "$ANALYZER" ] || die "no analyzer at $ANALYZER"
[ -x "$OUT/dart-sdk/bin/dart" ] || die "no host dart at $OUT/dart-sdk/bin/dart"
[ -x "$OUT/dartaotruntime" ] || die "no dartaotruntime at $OUT"
FLUTTER_PLATFORM=${PLATFORM:-$OUT/flutter_patched_sdk/platform_strong.dill}
[ -f "$FLUTTER_PLATFORM" ] || die "no flutter platform at $FLUTTER_PLATFORM"
if [ -n "$COMPILER_AOT" ]; then
  [ -f "$COMPILER_AOT" ] || die "no compiler at $COMPILER_AOT"
  [ -n "$RUNTIME" ] || RUNTIME=$OUT/dartaotruntime
  COMPILER_ARGS=(--compiler-aot "$COMPILER_AOT" --runtime "$RUNTIME")
  COMPILER_NAME="the cell's $COMPILER_AOT"
else
  COMPILER_ARGS=(--compiler-jit "$DT/pkg/dart2bytecode/bin/dart2bytecode.dart"
    --dart "$OUT/dart-sdk/bin/dart" --packages "$DT/.dart_tool/package_config.json")
  COMPILER_NAME="the tree's dart2bytecode source (JIT)"
fi

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
dart_tree() { "$OUT/dart-sdk/bin/dart" --packages="$DT/.dart_tool/package_config.json" "$@"; }

echo "== fixture: top-level functions, plus the same shapes as instance methods =="
python3 -I - "$HERE/inlined_ops_fixture.dart" "$W/fixture.dart" <<'PY'
import sys
src = open(sys.argv[1]).read()
begin = src.index('// BEGIN-FUNCTIONS')
end = src.index('// END-FUNCTIONS')
region = src[begin:end].split('\n')[3:]  # drop the marker comment lines
funcs = [l for l in region if l.strip() and not l.lstrip().startswith('//')]
pragma = "@pragma('vm:entry-point')"
head = src[:begin]
top = ''.join(f'{pragma}\n{l}\n' for l in funcs)
inst = ''.join(f'  {pragma}\n  {l}\n' for l in funcs)
tail = src[end:]
open(sys.argv[2], 'w').write(
    head + top + tail + f"\n{pragma}\nclass F {{\n  F();\n{inst}}}\n")
PY
FX=file://$W/fixture.dart

echo "== analysis kernel (flutter target, --aot --tfa) and the pre-AOT kernel the compiler imports =="
dart_tree "$DT/pkg/vm/bin/gen_kernel.dart" --platform "$FLUTTER_PLATFORM" \
  --target flutter --aot --tfa -o "$W/release.dill" "$W/fixture.dart"
dart_tree "$DT/pkg/vm/bin/gen_kernel.dart" --platform "$FLUTTER_PLATFORM" \
  --target flutter --no-aot --no-link-platform -o "$W/import.dill" "$W/fixture.dart"
cp "$W/import.dill" "$W/verification.dill"

echo "== the BUILT analyzer, every member carried =="
"$OUT/dartaotruntime" "$ANALYZER" --base-dill "$W/release.dill" \
  --patched-dill "$W/release.dill" --carry-all --include file: \
  --out "$W/coverage.json"
VER=$(python3 -I -c "import json,sys;print(json.load(open(sys.argv[1]))['analysisVersion'])" "$W/coverage.json")
if [ "$VER" -lt 21 ] && [ "$REQUIRE" = 0 ]; then
  echo "analyzer is analysis $VER: it is below 21, whose \`inlined\` flag is the one qualified, nothing to qualify"
  exit 0
fi

echo "== the real producer, compiling with $COMPILER_NAME =="
(cd "$REPO/packages/shorebird_cli" && "$DART_BIN" run tool/route_b_lower_fixture.dart \
  --coverage "$W/coverage.json" --release-dill "$W/import.dill" \
  --verification-dill "$W/verification.dill" \
  --flutter-platform "$FLUTTER_PLATFORM" --work "$W/lowered" \
  --only-containing "${ONLY:-__}" "${COMPILER_ARGS[@]}")

echo "== dump =="
while IFS=$'\t' read -r n key status; do
  [ "$status" = ok ] || continue
  dart_tree "$DT/pkg/dart2bytecode/bin/dump_bytecode.dart" "$W/lowered/$n.bytecode" \
    > "$W/lowered/$n.dump"
  # What the patcher itself reads after compiling (the fail-closed check in the
  # producer): the cell analyzer's bytecode scan. It must agree with the dump.
  "$OUT/dartaotruntime" "$ANALYZER" --scan-bytecode "$W/lowered/$n.bytecode" \
    > "$W/lowered/$n.scan"
done < "$W/lowered/index.tsv"

# The floor is fixed here and not read from the environment: a caller's
# MIN_TARGETS could otherwise lower it and let a run that compared little pass.
MIN_TARGETS=140
python3 -I - "$W/lowered" "$W/coverage.json" "$MIN_TARGETS" <<'PY'
import json, re, sys

work, cov_path, min_targets = sys.argv[1], sys.argv[2], int(sys.argv[3])
# selector -> the opcodes it can have (RecognizedMethods.binaryIntOps,
# binaryDoubleOps, the negations). `==` is in OPS so a call to it is seen, but
# has no opcode: `a == b` is never specialized.
OPCODES = {
    '+': {'AddInt', 'AddDouble'}, '-': {'SubInt', 'SubDouble'},
    '*': {'MulInt', 'MulDouble'}, '~/': {'TruncDivInt'}, '%': {'ModInt'},
    '/': {'DivDouble'}, '&': {'BitAndInt'}, '|': {'BitOrInt'},
    '^': {'BitXorInt'}, '<<': {'ShlInt'}, '>>': {'ShrInt'},
    '>': {'CompareIntGt', 'CompareDoubleGt'},
    '<': {'CompareIntLt', 'CompareDoubleLt'},
    '>=': {'CompareIntGe', 'CompareDoubleGe'},
    '<=': {'CompareIntLe', 'CompareDoubleLe'},
    'unary-': {'NegateInt', 'NegateDouble'}, '==': set(), '>>>': set(),
    '~': set(),
}
ALL_OPCODES = set().union(*OPCODES.values())
CALL = re.compile(r"(Interface|Dynamic)Call '(?:dart:core::\w+::)?([^']+)'")

refs_by_target = {}
any_selectors = {}  # every member the analyzer lists for a target, any kind
for target, rs in json.load(open(cov_path))['externalReferences'].items():
    any_selectors[target.split('#', 1)[1]] = {r['member'] for r in rs}
    refs_by_target[target.split('#', 1)[1]] = [
        r for r in rs if r['kind'] == 'instance' and r['library'] == 'dart:core'
        and r['member'] in OPCODES and r['class'] in ('int', 'double', 'num')]

bad, targets, refused = [], 0, []
TPARAM_REFUSALS = {'Gen.no__gen_t', 'Box.yes__box_len'}
tparam_refused = set()
expected_refusals = 0
flagged_n = unflagged_n = 0
for line in open(f'{work}/index.tsv'):
    n, key, status = line.rstrip('\n').split('\t')
    name = key.split('#', 1)[1]
    short = re.sub(r'^get:', '', name.split('.')[-1])
    if '__' not in short:
        continue
    if short.startswith('refused__') and name.startswith('UB.'):
        # A type the replacement library cannot name: the producer must refuse
        # the target, loudly, and never lower it to `dynamic`.
        if status == 'ok' or 'has no written type' not in status:
            bad.append(f'{name}: expected the producer to refuse an inferred '
                       f'parameter type it cannot write, got {status}')
        else:
            expected_refusals += 1
        continue
    if status != 'ok' and 'super' in short and 'reads `super.' in status:
        # The producer refuses a `super` property read outright (only a method
        # call is lowered): fail-closed, and nothing to compare.
        expected_refusals += 1
        continue
    if status != 'ok':
        # A generic function is not a valid replacement entry point; the
        # producer refuses it before any bytecode exists, so it is not compared.
        if 'generic' in short and 'generic' in status:
            expected_refusals += 1
            continue
        # A member of a generic class whose body uses the class's type
        # parameter: a top-level replacement cannot name it, so the producer
        # refuses it (fail-closed). Only these exact targets may; each must be
        # seen refused (checked after the loop).
        if name in TPARAM_REFUSALS and 'uses the class type parameter' in status:
            tparam_refused.add(name)
            expected_refusals += 1
            continue
        refused.append(f'{name}: {status}')
        continue
    text = open(f'{work}/{n}.dump').read()
    ops = set(re.findall(r'^\s+([A-Z]\w+(?:Int|Double)\w*)\b', text, re.M)) & ALL_OPCODES
    calls = {m.group(2) for m in CALL.finditer(text)} & set(OPCODES)
    scan = json.loads(open(f'{work}/{n}.scan').read().strip().splitlines()[-1])
    if scan['functions'] < 1 or set(scan['calls']) & set(OPCODES) != calls:
        bad.append(f'{name}: the analyzer\'s bytecode scan disagrees with the '
                   f'dump (scan {sorted(set(scan["calls"]) & set(OPCODES))}, '
                   f'dump {sorted(calls)})')
    rs = refs_by_target.get(name)
    if rs is None:
        bad.append(f'{name}: the analyzer reported no entry for it')
        continue
    targets += 1
    for r in rs:
        sel = r['member']
        flagged = 'inlined' in r
        called = sel in calls
        if flagged:
            flagged_n += 1
            if called:
                bad.append(f'{name}: {sel} is flagged inlined but the producer\'s '
                           f'bytecode still calls it (FAIL-OPEN)')
            for op in r['inlined'].split('|'):
                if op not in OPCODES[sel]:
                    bad.append(f'{name}: {sel} names {op}, which that selector '
                               f'cannot have')
                elif op not in ops:
                    bad.append(f'{name}: {sel} names {op}, the bytecode has {sorted(ops)}')
        else:
            unflagged_n += 1
            if not called and not short.startswith('conservative__'):
                bad.append(f'{name}: {sel} is not flagged but the bytecode has no '
                           f'call to it (analyzer and compiler have drifted)')
    selectors = {r['member'] for r in rs}
    for sel in sorted(calls - selectors - any_selectors.get(name, set())):
        bad.append(f'{name}: the bytecode calls {sel}; the analyzer lists no '
                   f'reference to it')
    flags = ['inlined' in r for r in rs]
    if short.startswith('yes__') and not (rs and all(flags)):
        bad.append(f'{name}: expected every operator reference flagged, got '
                   f'{[(r["class"], r["member"], r.get("inlined")) for r in rs]}')
    if short.startswith(('no__', 'conservative__')) and any(flags) and (
            short.startswith('conservative__') or all(flags)):
        bad.append(f'{name}: expected an unflagged operator reference')
    if short.startswith('no__') and not rs and not name.startswith('A.') and not (
            calls and any_selectors.get(name)):
        bad.append(f'{name}: a no__ target with no operator reference (or '
                   f'dynamic call) proves nothing')
    if short.startswith(('no__equals', 'no__not_equals')) and any(flags):
        bad.append(f'{name}: == / != must never be flagged')

for t in sorted(TPARAM_REFUSALS - tparam_refused):
    bad.append(f'{t}: expected the producer to refuse it for using the class '
               f'type parameter, and it did not (or the target is gone)')
for r in refused:
    bad.append(f'the producer refused {r}')
if targets < min_targets:
    bad.append(f'only {targets} targets were compared (need {min_targets}): '
               f'the run proved nothing')
if not flagged_n or not unflagged_n:
    bad.append(f'{flagged_n} flagged and {unflagged_n} unflagged references: '
               f'the run proved nothing')

print(f'{targets} targets, {flagged_n} flagged and {unflagged_n} unflagged '
      f'operator references compared against the producer\'s bytecode '
      f'({expected_refusals} targets refused by the producer, not compared)')
if bad:
    print('\nMISMATCH (blocker):')
    print('\n'.join('  ' + b for b in bad))
    sys.exit(1)
print('QUALIFIED: the analyzer and the compiler agree on the producer\'s output')
PY
