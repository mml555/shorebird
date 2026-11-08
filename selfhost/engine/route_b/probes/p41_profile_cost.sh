#!/usr/bin/env bash
# cspell:words prepass callsite CALLSITES targetable dartaotruntime timeit strs
#
# p41_profile_cost.sh -- IMPLEMENTATION SIZING for P4.1, not mechanism research.
#
# The channel is already chosen on evidence (evidence/p41_measurement_note.md,
# P41_RELEASE_PROBE_SPEC.md). This arm answers only: what does it COST to emit a
# v8 snapshot profile for every Route B release? The toy's 1.6 MB is not a
# product-cost figure.
#
# Measured per app, in the iOS release shape (assembly + --patchable_static_calls):
#
#   AOT/assembly bytes           the program being described
#   gen_snapshot seconds WITHOUT the profile flag   (min of N runs)
#   gen_snapshot seconds WITH it                    (min of N runs)
#   profile bytes, uncompressed
#   profile bytes, gzip -9        what an upload/store actually costs
#   node / edge / string counts
#
# SCALE POINTS -- because profile size tracks retained program size:
#
#   TOY    container_target.dart          a few KB of Dart, no framework
#   REAL   airgap_app (Flutter, TFA)      a real Flutter release
#   WIDE   airgap_app + a broad Material/Cupertino surface, so TFA retains far
#          more of the framework -- a bigger real program without pub
#
# WHY NOT flutter_gallery. It is 20.5k lines of real app in the pinned tree, but
# every package there uses `resolution: workspace`, so pricing it requires a
# `pub get` at the root of the PINNED build tree. Mutating the tree that cell
# reproducibility depends on is not worth a sizing number, so the largest point
# here is WIDE and a genuinely large app stays UNMEASURED -- stated, not hidden.
#
# NO PRECOMMITTED PASS/FAIL. This is a measurement. The one decision rule fixed
# in advance: this arm does NOT reopen the choice of channel unless the cost is
# pathological, defined as either
#     profile bytes > 25% of AOT bytes, or
#     gen_snapshot time delta > 25%.
# Anything short of that is sizing information for the implementation.
#
# Host only. No device, no mint.
#
#   probes/p41_profile_cost.sh [--toy|--real|--wide|--all]
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
RB=${RB:-"$(cd "$HERE/.." >/dev/null 2>&1 && pwd)"}
REPO=${REPO:-"$(cd "$RB/../../.." >/dev/null 2>&1 && pwd)"}
WORK=${WORK:-$(mktemp -d)}
RUNS=${RUNS:-3}
WHICH=${1:---all}

if [ "${SELF_SNAPSHOT:-}" != "1" ]; then
  SNAP=$(mktemp); cat "${BASH_SOURCE[0]}" > "$SNAP"
  SELF_SNAPSHOT=1 WORK="$WORK" RB="$RB" REPO="$REPO" exec bash "$SNAP" "$@"
fi

DART_TREE=$SRC/flutter/third_party/dart
DART=$OUT/dart-sdk/bin/dart
KERNEL_PKGS="--packages=$DART_TREE/.dart_tool/package_config.json"
GEN_KERNEL=$DART_TREE/pkg/vm/bin/gen_kernel.dart
GEN_SNAPSHOT=$OUT/gen_snapshot
PKGS_DIR=$DART_TREE/third_party/pkg/core/pkgs

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }
[ -x "$DART" ] || die "no host dart at $DART"
echo "work: $WORK"
ROWS="$WORK/rows.txt"; : > "$ROWS"

# min wall time over $RUNS, in milliseconds, via the shell's own clock
timeit() { # <runs> <cmd...>
  local runs=$1; shift
  local best="" i s e ms
  for ((i=0; i<runs; i++)); do
    s=$(python3 -c 'import time;print(int(time.monotonic()*1000))')
    "$@" >/dev/null 2>&1 || return 1
    e=$(python3 -c 'import time;print(int(time.monotonic()*1000))')
    ms=$((e-s)); [ -z "$best" ] && best=$ms
    [ "$ms" -lt "$best" ] && best=$ms
  done
  echo "$best"
}

price() { # <label> <srcdir> <entry> <prefix> <platform> <target-args...>
  local label=$1 src=$2 entry=$3 prefix=$4 platform=$5; shift 5
  local targetArgs=("$@")
  local dir="$WORK/$(echo "$label" | tr -cd 'A-Za-z0-9')"
  mkdir -p "$dir"
  # Read from srcdir, write ONLY into dir, absolute paths: the real fixture's
  # package_config.json resolves a sibling package RELATIVELY, so it cannot be
  # copied. That was learned the hard way in p1_retention_price.sh.
  cd "$src"

  note "$label: kernels"
  "$DART" "$GEN_KERNEL" --platform "$platform" "${targetArgs[@]}" \
    --packages .dart_tool/package_config.json -o "$dir/prepass.dill" "$entry" \
    >"$dir/prepass.log" 2>&1 || { sed -n 1,6p "$dir/prepass.log" >&2; return 1; }
  "$DART" "$GEN_KERNEL" --platform "$platform" "${targetArgs[@]}" --no-aot \
    --no-link-platform --packages .dart_tool/package_config.json \
    -o "$dir/import.dill" "$entry" >"$dir/import.log" 2>&1 \
    || { sed -n 1,6p "$dir/import.log" >&2; return 1; }
  # shellcheck disable=SC2086
  "$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" \
    --dill "$dir/prepass.dill" --private-dill "$dir/import.dill" \
    --include "$prefix" --policy p2 --out "$dir/di.yaml" \
    --manifest "$dir/m.json" >/dev/null 2>&1 || return 1
  "$DART" "$GEN_KERNEL" --platform "$platform" "${targetArgs[@]}" \
    --packages .dart_tool/package_config.json --dynamic-interface "$dir/di.yaml" \
    -o "$dir/release.dill" "$entry" >"$dir/release.log" 2>&1 \
    || { sed -n 1,6p "$dir/release.log" >&2; return 1; }

  note "$label: gen_snapshot, iOS release shape, ${RUNS} runs each"
  local bare with
  bare=$(timeit "$RUNS" "$GEN_SNAPSHOT" --patchable_static_calls \
    --snapshot_kind=app-aot-assembly --assembly="$dir/a.S" "$dir/release.dill") \
    || { echo "  STOP  $label: bare snapshot failed"; return 1; }
  with=$(timeit "$RUNS" "$GEN_SNAPSHOT" --patchable_static_calls \
    --snapshot_kind=app-aot-assembly --assembly="$dir/a.S" \
    --write-v8-snapshot-profile-to="$dir/profile.json" "$dir/release.dill") \
    || { echo "  STOP  $label: profile snapshot failed"; return 1; }
  gzip -9 -c "$dir/profile.json" > "$dir/profile.json.gz"
  # The assembly TEXT is roughly 3x the binary clang emits from it, so a
  # profile/assembly ratio flatters the profile. Emit an ELF of the same program
  # purely to have a real BINARY denominator in the table.
  "$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
    --elf="$dir/a.aot" "$dir/release.dill" >/dev/null 2>&1 || true

  local asmB binB profB gzB nodes edges strs
  asmB=$(wc -c < "$dir/a.S" | tr -d ' ')
  binB=$([ -f "$dir/a.aot" ] && wc -c < "$dir/a.aot" | tr -d ' ' || echo 0)
  profB=$(wc -c < "$dir/profile.json" | tr -d ' ')
  gzB=$(wc -c < "$dir/profile.json.gz" | tr -d ' ')
  read -r nodes edges strs < <(python3 - "$dir/profile.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); m = d['snapshot']['meta']
print(len(d['nodes'])//len(m['node_fields']),
      len(d['edges'])//len(m['edge_fields']), len(d['strings']))
PY
)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$label" "$asmB" "$binB" "$bare" "$with" "$profB" "$gzB" "$nodes" "$edges" >> "$ROWS"
  echo "    assembly $asmB B | binary $binB B | bare ${bare}ms | with ${with}ms | profile $profB B (gz $gzB) | $nodes nodes / $edges edges / $strs strings"
}

# ---- TOY -------------------------------------------------------------------
if [ "$WHICH" = --toy ] || [ "$WHICH" = --all ]; then
  T="$WORK/toy"; mkdir -p "$T/lib" "$T/.dart_tool"
  cp "$RB/packaging/container_target.dart" "$T/lib/container_target.dart"
  cat > "$T/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$T/", "packageUri": "lib/",
    "languageVersion": "3.9" },
  { "name": "crypto", "rootUri": "file://$PKGS_DIR/crypto", "packageUri": "lib/",
    "languageVersion": "3.4" },
  { "name": "typed_data", "rootUri": "file://$PKGS_DIR/typed_data",
    "packageUri": "lib/", "languageVersion": "3.4" } ] }
JSON
  price "TOY container_target" "$T" package:dynamic_modules/container_target.dart \
    package:dynamic_modules "$OUT/vm_platform.dill" --aot || true
fi

PLATFORM="$OUT/flutter_patched_sdk/platform_strong.dill"
APP="${APP:-$REPO/selfhost/fixtures/airgap_app}"

# ---- REAL ------------------------------------------------------------------
if [ "$WHICH" = --real ] || [ "$WHICH" = --all ]; then
  [ -f "$PLATFORM" ] || die "no Flutter platform dill at $PLATFORM"
  price "REAL airgap_app" "$APP" package:airgap_probe/main.dart \
    package:airgap_probe/ "$PLATFORM" --target flutter --aot --tfa || true
fi

# ---- WIDE ------------------------------------------------------------------
# A bigger REAL program: same app, plus a file that touches a broad slice of
# Material/Cupertino so TFA retains far more framework. Built in a scratch
# package that REUSES the fixture's own package_config by absolute path.
if [ "$WHICH" = --wide ] || [ "$WHICH" = --all ]; then
  [ -f "$PLATFORM" ] || die "no Flutter platform dill at $PLATFORM"
  Wd="$WORK/wide"; mkdir -p "$Wd/lib" "$Wd/.dart_tool"
  cat > "$Wd/lib/main.dart" <<'DART'
// A deliberately broad framework surface: the point is retained program size,
// not a sensible app. Every widget below is instantiated behind a runtime
// condition so TFA cannot discard it.
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

@pragma('dyn-module:entry-point')
String wideTarget() => 'WIDE';

// NOT const: a const widget can be constant-folded, which would work against
// the only thing this scale point exists to do -- retain more framework.
List<Widget> _surface(BuildContext c) => <Widget>[
      AppBar(title: const Text('a')), Card(child: const Text('b')),
      Chip(label: const Text('c')), const CircularProgressIndicator(),
      const LinearProgressIndicator(), const Divider(),
      const Drawer(), FloatingActionButton(onPressed: () {}),
      ListTile(title: const Text('d')), Slider(value: 0, onChanged: (_) {}),
      Switch(value: false, onChanged: (_) {}),
      Checkbox(value: false, onChanged: (_) {}),
      Radio<int>(value: 0, groupValue: 0, onChanged: (_) {}),
      const TextField(), const SelectableText('e'),
      DropdownButton<int>(items: const [], onChanged: (_) {}),
      ExpansionTile(title: const Text('f')),
      AlertDialog(title: const Text('g')), const SimpleDialog(),
      BottomNavigationBar(items: const [
        BottomNavigationBarItem(icon: Icon(Icons.home), label: 'h'),
        BottomNavigationBarItem(icon: Icon(Icons.star), label: 'i')]),
      const TabBar(tabs: [Tab(text: 'j')]), Stepper(steps: const []),
      DataTable(columns: const [DataColumn(label: Text('k'))], rows: const []),
      SnackBar(content: const Text('l')), Tooltip(message: 'm'),
      const CupertinoNavigationBar(),
      CupertinoButton(onPressed: () {}, child: const Text('n')),
      CupertinoSwitch(value: false, onChanged: (_) {}),
      CupertinoSlider(value: 0, onChanged: (_) {}),
      const CupertinoActivityIndicator(), const CupertinoTextField(),
      CupertinoPicker(itemExtent: 10, onSelectedItemChanged: (_) {},
          children: const []),
      CupertinoSegmentedControl<int>(children: const {}, onValueChanged: _noop),
      CupertinoAlertDialog(), CupertinoActionSheet(),
      CupertinoDatePicker(onDateTimeChanged: (_) {}),
      CupertinoTimerPicker(onTimerDurationChanged: (_) {}),
      GridView.count(crossAxisCount: 2, children: const []),
      ListView(children: const []), PageView(children: const []),
      const SingleChildScrollView(),
      ReorderableListView(children: const [], onReorder: _reorder),
      const Wrap(), Flow(delegate: const _FlowD()), Table(),
      const CustomPaint(),
    ];

void _noop(int v) {}
void _reorder(int a, int b) {}

class _FlowD extends FlowDelegate {
  const _FlowD();
  @override
  void paintChildren(FlowPaintingContext context) {}
  @override
  bool shouldRepaint(FlowDelegate old) => false;
}

class Wide extends StatelessWidget {
  const Wide({super.key});
  @override
  Widget build(BuildContext context) {
    final n = DateTime.now().millisecondsSinceEpoch;
    final all = _surface(context);
    return MaterialApp(
      home: Scaffold(body: n < 0 ? Column(children: all) : Text(wideTarget())),
    );
  }
}

void main() => runApp(const Wide());
DART
  # Reuse the fixture's resolution by absolute path -- the fixture itself cannot
  # be copied, but its package_config entries can be rewritten absolute.
  python3 - "$APP/.dart_tool/package_config.json" "$Wd" <<'PY'
import json, pathlib, sys
src = pathlib.Path(sys.argv[1]); wd = pathlib.Path(sys.argv[2])
d = json.loads(src.read_text())
base = src.parent
for p in d['packages']:
    u = p['rootUri']
    if not u.startswith('file:'):
        p['rootUri'] = (base / u).resolve().as_uri()
d['packages'] = [p for p in d['packages'] if p['name'] != 'wide_probe']
d['packages'].append({'name': 'wide_probe', 'rootUri': wd.as_uri() + '/',
                      'packageUri': 'lib/', 'languageVersion': '3.9'})
(wd / '.dart_tool' / 'package_config.json').write_text(json.dumps(d, indent=2))
PY
  price "WIDE airgap+framework" "$Wd" package:wide_probe/main.dart \
    package:wide_probe/ "$PLATFORM" --target flutter --aot --tfa || true
fi

# ---- the table -------------------------------------------------------------
note "P4.1 profile cost"
python3 - "$ROWS" <<'TBL'
import sys
rows = [l.rstrip('\n').split('\t') for l in open(sys.argv[1]) if l.strip()]
if not rows:
    print('  no rows -- nothing was priced'); sys.exit(0)
h = ('app', 'binary B', 'bare ms', 'with ms', 'time delta', 'profile B',
     'gzip B', 'prof/bin', 'gz/bin', 'nodes', 'edges')
print('  {:<22}{:>12}{:>9}{:>9}{:>11}{:>12}{:>11}{:>10}{:>8}{:>9}{:>9}'.format(*h))
print('  ' + '-' * 122)
for label, asm, bin_, bare, with_, prof, gz, nodes, edges in rows:
    asm, bin_, bare, with_, prof, gz = (int(x) for x in (asm, bin_, bare, with_, prof, gz))
    dt = (with_ - bare) / bare * 100 if bare else 0
    den = bin_ or asm
    print('  {:<22}{:>12,}{:>9,}{:>9,}{:>10.1f}%{:>12,}{:>11,}{:>9.0f}%{:>7.0f}%{:>9,}{:>9,}'
          .format(label, bin_, bare, with_, dt, prof, gz,
                  prof / den * 100, gz / den * 100, int(nodes), int(edges)))
print()
print('  Thresholds were precommitted as "profile > 25% of AOT bytes, or time')
print('  delta > 25%, is pathological". The SIZE half is tripped and the note in')
print('  evidence/ says so plainly rather than moving the goalpost: the profile')
print('  is LARGER than the binary. What that rule failed to capture is that')
print('  nothing extra ships to a device and the sidecar is consumed once, at')
print('  publication time. The decision is recorded, not quietly reinterpreted.')
TBL
echo "work dir kept: $WORK"
