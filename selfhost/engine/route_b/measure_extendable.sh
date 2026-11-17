#!/usr/bin/env bash
# cspell:words dynmod prepass npplat untabled funcs
#
# measure_extendable.sh -- what does declaring StatelessWidget, StatefulWidget
# and State `extendable` + `can-be-overridden` cost a REAL Flutter app's AOT
# snapshot? The price of the "new class extending an AOT class" rung (see
# probes/added_class.sh, ROUTE_B.md "New class").
#
# Same method as measure_real_app.sh (the airgap fixture, the Flutter platform
# dill, TFA on, gen_snapshot --patchable_static_calls), with one axis:
#   ctrl       the shipping interface (p2, privates from the non-AOT kernel)
#   ext_all    + `--extendable` for the three classes (all public members)
#   ext_narrow + `--extendable` for the three classes, only the members a
#                widget class overrides: build, createState, initState,
#                didUpdateWidget, dispose, didChangeDependencies
# Reported: snapshot bytes, the Instructions cluster and dispatch table
# (--print_snapshot_sizes_verbose), and the per-function instruction listing
# (--print_instructions_sizes_to): function count, [Optimized] count, bytes.
#
# WHY NOT JUST RUN measure_real_app.sh. Its private-from-non-AOT arm and its
# shipping arm generate the interface from the --aot prepass alone, and on the
# current airgap fixture gen_kernel rejects that interface ("A member with
# disambiguated name 'set:_rbKindMember' was not found in class
# '_ProbeBodyState'"), so the script dies before its first snapshot. This
# script passes `--private-dill <non-AOT kernel> --platform <flutter platform>`,
# which resolves.
#
# WHAT IT CANNOT TELL YOU. Host (macOS arm64) snapshots, not iOS: absolute bytes
# are not an iOS release size; the DELTAS are the transferable part. Nothing here
# measures frame time, startup, or iOS code size, and TFA devirtualization is
# seen only through its effect on the numbers above, not reported directly.
#
# Prerequisite: `flutter pub get` in the fixture (it writes .dart_tool/ and edits
# pubspec.lock; revert the lock afterwards).
#   OUT=<ddm out dir with flutter_patched_sdk> measure_extendable.sh
set -euo pipefail

SRC="${SRC:-$HOME/shorebird-engine/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64_ddm}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../../.." >/dev/null 2>&1 && pwd)"
APP="${APP:-$REPO/selfhost/fixtures/airgap_app}"
ENTRY="${ENTRY:-package:airgap_probe/main.dart}"
APP_PREFIX="${APP_PREFIX:-package:airgap_probe/}"
WORK="${WORK:-$(mktemp -d)}"; mkdir -p "$WORK"
FW='package:flutter/src/widgets/framework.dart'
DART_TREE="$SRC/flutter/third_party/dart"
DART="$OUT/dart-sdk/bin/dart"
KERNEL_PKGS="--packages=$DART_TREE/.dart_tool/package_config.json"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
PLATFORM="$OUT/flutter_patched_sdk/platform_strong.dill"
die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }
[ -f "$PLATFORM" ] || die "no Flutter platform dill at $PLATFORM"
[ -f "$APP/.dart_tool/package_config.json" ] || die "run 'flutter pub get' in $APP first"
grep -q 'dart_dynamic_modules = true' "$OUT/args.gn" 2>/dev/null || die "$OUT is not a dart_dynamic_modules build"

kernel() { # kernel <out.dill> [extra gen_kernel args...]
  local out="$1"; shift
  (cd "$APP" && "$DART" "$GEN_KERNEL" --platform "$PLATFORM" --target flutter --aot --tfa \
    --packages .dart_tool/package_config.json "$@" -o "$out" "$ENTRY") >"$out.log" 2>&1 \
    || { head -3 "$out.log" >&2; die "gen_kernel failed for $out"; }
}
snap() { # snap <name> <dill> [flags...]
  local name="$1" dill="$2"; shift 2
  "$OUT/gen_snapshot" --deterministic "$@" --print_snapshot_sizes_verbose \
    --print_instructions_sizes_to="$WORK/$name.sizes.json" \
    --snapshot_kind=app-aot-elf --elf="$WORK/$name.aot" "$dill" >"$WORK/$name.verbose.txt" 2>&1 \
    || die "gen_snapshot failed for $name"
}
gen() { # gen <out.yaml> [extra flags...]
  local out="$1"; shift
  "$DART" "$KERNEL_PKGS" "$HERE/gen_dynamic_interface.dart" --dill "$WORK/app.dill" \
    --include "$APP_PREFIX" --private-dill "$WORK/import.dill" --platform "$PLATFORM" \
    --out "$out" "$@" >"$out.log" 2>&1 || { tail -3 "$out.log" >&2; die "interface failed: $out"; }
}

note "kernels: no retention, and non-AOT (private enumeration)"
kernel "$WORK/app.dill"
kernel "$WORK/import.dill" --no-aot --no-link-platform

note "interfaces"
gen "$WORK/di_ctrl.yaml"
gen "$WORK/di_ext_all.yaml" \
  --extendable "$FW#StatelessWidget" --extendable "$FW#StatefulWidget" --extendable "$FW#State"
NARROW=()
for c in StatelessWidget.build StatefulWidget.createState \
         State.build State.initState State.didUpdateWidget State.dispose State.didChangeDependencies; do
  NARROW+=(--extendable "$FW#$c")
done
gen "$WORK/di_ext_narrow.yaml" "${NARROW[@]}"

note "kernels with retention"
kernel "$WORK/k_ctrl.dill"       --dynamic-interface "$WORK/di_ctrl.yaml"
kernel "$WORK/k_ext_all.dill"    --dynamic-interface "$WORK/di_ext_all.yaml"
kernel "$WORK/k_ext_narrow.dill" --dynamic-interface "$WORK/di_ext_narrow.yaml"

# VACUITY GATE (as in measure_real_app.sh): a treatment that changed neither the
# interface nor the kernel priced nothing.
h() { shasum -a 256 "$1" | cut -d' ' -f1; }
for a in ext_all ext_narrow; do
  [ "$(h "$WORK/di_ctrl.yaml")" != "$(h "$WORK/di_$a.yaml")" ] || die "VACUOUS: di_$a == di_ctrl"
  [ "$(h "$WORK/k_ctrl.dill")" != "$(h "$WORK/k_$a.dill")" ] || die "VACUOUS: k_$a == k_ctrl"
done

note "snapshots (--patchable_static_calls; ctrl twice, as a determinism check)"
snap ctrl       "$WORK/k_ctrl.dill"       --patchable_static_calls
snap ctrl_again "$WORK/k_ctrl.dill"       --patchable_static_calls
snap ext_all    "$WORK/k_ext_all.dill"    --patchable_static_calls
snap ext_narrow "$WORK/k_ext_narrow.dill" --patchable_static_calls
if [ "${UNTABLED:-0}" = 1 ]; then
  note "snapshots, --route_b_untabled_overrides"
  snap ctrl_untabled "$WORK/k_ctrl.dill"    --patchable_static_calls --route_b_untabled_overrides
  snap ext_all_untabled "$WORK/k_ext_all.dill" --patchable_static_calls --route_b_untabled_overrides
fi

{
  echo "app            : $APP"
  echo "app commit     : $(git -C "$APP" rev-parse HEAD 2>/dev/null || echo '<not a git checkout>')"
  echo "pubspec.lock   : $(shasum -a 256 "$APP/pubspec.lock" | cut -d' ' -f1)"
  echo "gen_snapshot   : $(h "$OUT/gen_snapshot")"
  echo "platform dill  : $(h "$PLATFORM")"
  echo "di ctrl        : $(h "$WORK/di_ctrl.yaml")"
  echo "di ext_all     : $(h "$WORK/di_ext_all.yaml")"
  echo "di ext_narrow  : $(h "$WORK/di_ext_narrow.yaml")"
} | tee "$WORK/provenance.txt"

python3 - "$WORK" <<'PY'
import json, os, re, sys
w = sys.argv[1]
size = lambda n: os.path.getsize(os.path.join(w, n + '.aot'))
def sizes(n):
    d = json.load(open(os.path.join(w, n + '.sizes.json')))
    return (len(d), sum(1 for e in d if e['n'].startswith('[Optimized]')),
            sum(e['s'] for e in d))
def cluster(n, name):
    for line in open(os.path.join(w, n + '.verbose.txt')):
        p = line.split()
        if name in p[:2]:
            return int(p[p.index(name) + 2])
    sys.exit('no %s row in %s.verbose.txt: gen_snapshot output format changed' % (name, n))
arms = [a for a in ('ctrl', 'ext_all', 'ext_narrow', 'ctrl_untabled', 'ext_all_untabled')
        if os.path.exists(os.path.join(w, a + '.aot'))]
print()
print('determinism: ctrl %d bytes, ctrl again %d bytes (differ by %d; a delta '
      'of that order is noise)' % (size('ctrl'), size('ctrl_again'),
                                   abs(size('ctrl') - size('ctrl_again'))))
print()
hdr = '%-18s %12s %10s %12s %12s %9s %9s %12s' % (
    'arm', 'snapshot B', 'vs ctrl', 'Instr. B', 'DispTbl B', 'funcs', 'optimized', 'func bytes')
print(hdr); print('-' * len(hdr))
for a in arms:
    base = 'ctrl_untabled' if a.endswith('_untabled') else 'ctrl'
    f, o, b = sizes(a)
    print('%-18s %12d %+9.3f%% %12d %12d %9d %9d %12d' % (
        a, size(a), (size(a) - size(base)) / size(base) * 100,
        cluster(a, 'Instructions'), cluster(a, 'DispatchTable'), f, o, b))
print()
print('Instruction listing, ctrl vs each treatment. Names are normalised (the "@<hash>"')
print('library suffix and "_MixinApplicationN" numbering change on any kernel change;')
print('dart:mixin_deduplication entries are left out for the same reason).')
from collections import Counter
def norm(n):
    n = re.sub(r'@\d+', '', n)
    return re.sub(r'_MixinApplication\d+', '_MixinApplication', n)
def listing(n):
    d = json.load(open(os.path.join(w, n + '.sizes.json')))
    c, sz = Counter(), Counter()
    for e in d:
        # The mixin-deduplication library's class names are renumbered and
        # reshuffled by any kernel change; they are noise, not a difference.
        if e.get('l', '') == 'dart:mixin_deduplication': continue
        k = (e.get('l', ''), e.get('c', ''), norm(e['n']))
        c[k] += 1; sz[k] += e['s']
    return c, sz
c0, s0 = listing('ctrl')
for a in arms[1:]:
    if a.endswith('_untabled'): continue
    c1, s1 = listing(a)
    added, gone = c1 - c0, c0 - c1
    print('\n  %s: %d entries only here, %d only in ctrl' % (a, sum(added.values()), sum(gone.values())))
    for k in sorted(added): print('    + %s' % ' | '.join(x for x in k if x))
    for k in sorted(gone): print('    - %s' % ' | '.join(x for x in k if x))
    common = [k for k in c0 if k in c1 and c0[k] == c1[k]]
    grown = sorted(((s1[k] - s0[k], k) for k in common if s1[k] != s0[k]), reverse=True)
    print('    %d functions present in both changed size; net %+d bytes; largest:' % (
        len(grown), sum(d for d, _ in grown)))
    for d, k in grown[:8]: print('      %+6d  %s' % (d, ' | '.join(x for x in k if x)))
PY
echo "work dir kept: $WORK"
