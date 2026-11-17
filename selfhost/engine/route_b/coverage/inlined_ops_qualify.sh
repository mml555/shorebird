#!/usr/bin/env bash
# cspell:words dartaotruntime tfa
#
# inlined_ops_qualify.sh -- does the analyzer's `inlined` flag (analysis 20)
# agree, in BOTH directions, with what the cell's dart2bytecode really emits?
#
# The analyzer decides `inlined` by calling dart2bytecode's own
# `RecognizedMethods`. This script does not trust that: it compiles
# inlined_ops_fixture.dart with the engine tree's dart2bytecode, dumps the
# bytecode, runs the BUILT analyzer artifact over the same fixture, and
# compares per function and per operator reference:
#
#   flagged   <=>  the bytecode has no InterfaceCall to that selector
#   flagged    =>  the opcode the analyzer names is in the function's bytecode
#   yes__<x>   =>  every operator reference is flagged (and there is one)
#   no__<x>    =>  not every operator reference is flagged
#
# ANY mismatch, in either direction, is a failure (exit 1): flagged-but-called
# would let a missing SDK member through; unflagged-but-inlined only loses an
# accepted patch, but it means the analyzer and the compiler have drifted.
#
# usage: inlined_ops_qualify.sh <route_b_analyze.aot> [OUT]
#   OUT  an engine out dir (dart_dynamic_modules build); default
#        $SRC/out/host_release_arm64_ddm
set -euo pipefail

ANALYZER=${1:?usage: inlined_ops_qualify.sh <route_b_analyze.aot> [OUT]}
SRC=${SRC:-$HOME/shorebird-engine/flutter/engine/src}
OUT=${2:-$SRC/out/host_release_arm64_ddm}
DT=$SRC/flutter/third_party/dart
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$ANALYZER" ] || die "no analyzer at $ANALYZER"
[ -x "$OUT/dart-sdk/bin/dart" ] || die "no host dart at $OUT/dart-sdk/bin/dart"
[ -x "$OUT/dartaotruntime" ] || die "no dartaotruntime at $OUT"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cp "$HERE/inlined_ops_fixture.dart" "$W/fixture.dart"
dart() { "$OUT/dart-sdk/bin/dart" --packages="$DT/.dart_tool/package_config.json" "$@"; }

echo "== dart2bytecode + dump =="
dart "$DT/pkg/dart2bytecode/bin/dart2bytecode.dart" \
  --platform "$OUT/vm_platform.dill" -o "$W/fixture.bc" "$W/fixture.dart"
dart "$DT/pkg/dart2bytecode/bin/dump_bytecode.dart" "$W/fixture.bc" > "$W/fixture.dump"

echo "== analyzer over the same fixture (every member carried) =="
# Not tree-shaken: a function nothing calls would otherwise be gone.
dart "$DT/pkg/vm/bin/gen_kernel.dart" --platform "$OUT/vm_platform.dill" \
  --aot --no-tfa -o "$W/fixture.dill" "$W/fixture.dart"
"$OUT/dartaotruntime" "$ANALYZER" --base-dill "$W/fixture.dill" \
  --patched-dill "$W/fixture.dill" --carry-all --include file: \
  --out "$W/coverage.json"

python3 -I - "$W/fixture.dump" "$W/coverage.json" <<'PY'
import json, re, sys

dump_path, cov_path = sys.argv[1:3]
OPS = {'+', '-', '*', '~/', '%', '/', '&', '|', '^', '<<', '>>', '>>>',
       '<', '<=', '>', '>=', 'unary-', '~'}
OPCODE = re.compile(
    r'^\s+((?:(?:Add|Sub|Mul|Div|TruncDiv|Mod|BitAnd|BitOr|BitXor|Shl|Shr|'
    r'Negate)(?:Int|Double)|Compare(?:Int|Double)(?:Gt|Lt|Ge|Le)))\b')
CALL = re.compile(r"InterfaceCall '(dart:core::\w+::[^']+)'")

# One entry per top-level Function; its closures' blocks follow it and belong
# to it, which is how the analyzer reports them (one body, one reference list).
funcs, cur = {}, None
for line in open(dump_path):
    m = re.match(r"Function '([^']+)'", line)
    if m:
        cur = funcs.setdefault(m.group(1), {'ops': set(), 'calls': set()})
        continue
    if line.startswith('Library'):
        cur = None
    if cur is None:
        continue
    m = OPCODE.match(line)
    if m:
        cur['ops'].add(m.group(1))
    m = CALL.search(line)
    if m and m.group(1).rsplit('::', 1)[1] in OPS:
        cur['calls'].add(m.group(1))

refs = {}
for target, rs in json.load(open(cov_path))['externalReferences'].items():
    name = target.rsplit('#', 1)[1]
    refs[name] = [r for r in rs
                  if r['kind'] == 'instance' and r['library'] == 'dart:core'
                  and r['member'] in OPS]

bad, checked = [], 0
for name, f in sorted(funcs.items()):
    if '__' not in name:
        continue
    if name not in refs:
        bad.append(f'{name}: the analyzer reported no entry for it')
        continue
    rs = refs[name]
    selectors = set()
    for r in rs:
        sel = f"dart:core::{r['class']}::{r['member']}"
        selectors.add(sel)
        flagged = 'inlined' in r
        called = sel in f['calls']
        checked += 1
        if flagged == called:
            bad.append(f'{name}: {sel} flagged={flagged} but the bytecode '
                       f'{"has an" if called else "has no"} InterfaceCall')
        if flagged and r['inlined'] not in f['ops']:
            bad.append(f"{name}: {sel} says {r['inlined']}, the bytecode has "
                       f"{sorted(f['ops'])}")
    for sel in sorted(f['calls'] - selectors):
        bad.append(f'{name}: the bytecode calls {sel}; the analyzer lists no '
                   f'reference to it')
    flags = ['inlined' in r for r in rs]
    if name.startswith('yes__') and not (rs and all(flags)):
        bad.append(f'{name}: expected every operator reference flagged, got '
                   f'{[(r["class"], r["member"], r.get("inlined")) for r in rs]}')
    if name.startswith('no__') and rs and all(flags):
        bad.append(f'{name}: expected an unflagged operator reference, '
                   f'every one is flagged')

n = len([k for k in funcs if '__' in k])
print(f'{n} functions, {checked} operator references compared')
if bad:
    print('\nMISMATCH (blocker):')
    print('\n'.join('  ' + b for b in bad))
    sys.exit(1)
print('QUALIFIED: the analyzer and dart2bytecode agree in both directions')
PY
