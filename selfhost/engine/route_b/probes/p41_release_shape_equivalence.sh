#!/usr/bin/env bash
# cspell:words dartaotruntime prepass callsite CALLSITES targetable defaultdict
#
# p41_release_shape_equivalence.sh -- PERMANENT REGRESSION CONTROL for P4.1.
#
# Two questions, one build of the three-specimen release:
#
#   1. Does the classification in P41_RELEASE_PROBE_SPEC.md §2 hold under the
#      configurations a REAL release actually uses, not just the bare `--elf`
#      the survey measured?
#
#        iOS      gen_snapshot --snapshot_kind=app-aot-assembly --assembly=...
#                 and NO --strip: flutter_tools strips manually after the dSYM
#                 export (packages/flutter_tools/lib/src/base/build.dart:263).
#        Android  gen_snapshot --snapshot_kind=app-aot-elf --elf=... --strip
#                 (same file, line 271).
#
#      Reasoning said stripping cannot matter because the profile is a separate
#      JSON gen_snapshot writes from its own compilation data, never extracted
#      from the binary. Reasoning is not a control. This is the control.
#
#   2. Is the three-way partition still exactly the permanent table?
#
#        foldOpaque  -> qualifying caller-owned reference exists
#        foldConst   -> target exists, ZERO qualifying caller-owned references
#        deadBranch  -> qualifying caller-owned reference exists
#
# PRECOMMIT -- fixed before running. Every shape must classify identically:
#
#   | shape                     | foldOpaque | foldConst | deadBranch |
#   |---------------------------|------------|-----------|------------|
#   | elf (survey baseline)     | >=1        | 0         | >=1        |
#   | elf --strip (Android)     | >=1        | 0         | >=1        |
#   | assembly (iOS)            | >=1        | 0         | >=1        |
#
#   ...where the number is caller_owned_pools ALONE, per spec §2. The raw
#   categories are printed for every cell so a future change to the incidental
#   counts is visible rather than silent.
#
#   STOP/INVALID: if any shape yields foldConst >= 1 or foldOpaque == 0 the
#   channel is not shape-independent and the spec's §5 binding must name the
#   snapshot kind. If a shape fails to BUILD, that is a STOP, not a pass.
#
# Host only. No device, no mint.
#
#   probes/p41_release_shape_equivalence.sh
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
RB=${RB:-"$(cd "$HERE/.." >/dev/null 2>&1 && pwd)"}
WORK=${WORK:-$(mktemp -d)}

# Editing a running script makes bash resume at a byte offset in the NEW file.
# Re-exec from a snapshot so an edit mid-run cannot produce a garbage tail.
if [ "${SELF_SNAPSHOT:-}" != "1" ]; then
  SNAP=$(mktemp); cat "${BASH_SOURCE[0]}" > "$SNAP"
  SELF_SNAPSHOT=1 WORK="$WORK" RB="$RB" exec bash "$SNAP" "$@"
fi

DART_TREE=$SRC/flutter/third_party/dart
DART=$OUT/dart-sdk/bin/dart
KERNEL_PKGS="--packages=$DART_TREE/.dart_tool/package_config.json"
GEN_KERNEL=$DART_TREE/pkg/vm/bin/gen_kernel.dart
GEN_SNAPSHOT=$OUT/gen_snapshot
PKGS_DIR=$DART_TREE/third_party/pkg/core/pkgs

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1));
  else echo "  FAIL  $1"; echo "        got : $2"; echo "        want: $3"
    fail=$((fail+1)); fi; }

[ -x "$DART" ] || die "no host dart at $DART"
echo "work: $WORK"

# ---- the classifier: spec §2, as the reference implementation ---------------
cat > "$WORK/classify.py" <<'PY'
import json, sys, collections
# Decoder facts are MEASURED (spec §8): node/edge `type` index
# meta.node_types[0] / meta.edge_types[0] -- NOT strings, which is the error
# that voided the first decode -- and `to_node` is a BYTE OFFSET into `nodes`.
d = json.load(open(sys.argv[1]))
snap = d['snapshot']; meta = snap['meta']
NT, ET = meta['node_types'][0], meta['edge_types'][0]
strings, nodes, edges = d['strings'], d['nodes'], d['edges']
NF, EF = len(meta['node_fields']), len(meta['edge_fields'])
if len(nodes) % NF or len(edges) % EF:
    print('PROFILE_INVALID ragged-arrays'); sys.exit(0)
N = [{'type': NT[nodes[i]], 'name': strings[nodes[i+1]], 'ec': nodes[i+4]}
     for i in range(0, len(nodes), NF)]
adj = collections.defaultdict(list); pos = 0
for idx, n in enumerate(N):
    for _ in range(n['ec']):
        if pos + EF > len(edges):
            print('PROFILE_INVALID short-edge-array'); sys.exit(0)
        et, nm, to = edges[pos:pos+EF]; pos += EF
        adj[idx].append((ET[et], nm, to // NF))
if pos != len(edges):
    print('PROFILE_INVALID leftover-edges'); sys.exit(0)
ref = collections.defaultdict(list)
for s, outs in adj.items():
    for et, nm, dst in outs: ref[dst].append((s, et, nm))

def code_owners(pool):
    return [N[s]['name'] for s, _, _ in ref.get(pool, []) if N[s]['type'] == 'Code']

for target in sys.argv[2:]:
    fns = [i for i, x in enumerate(N)
           if x['type'] == 'Function' and x['name'] == target]
    cats = dict(target_function_nodes=len(fns), caller_owned_pools=0,
                tearoff_pools=0, self_owned_pools=0, unowned_pools=0,
                other_referrers=0)
    def emit(res):
        print(f'{target} {res} ' + ' '.join(f'{k}={v}' for k, v in cats.items()))
    if len(fns) == 0:
        emit('TARGET_NOT_FOUND'); continue
    if len(fns) > 1:
        emit('TARGET_AMBIGUOUS'); continue
    fn = fns[0]
    for s, et, nm in ref.get(fn, []):
        if N[s]['type'] != 'ObjectPool':
            cats['other_referrers'] += 1; continue
        owners = code_owners(s)
        if not owners:
            cats['unowned_pools'] += 1                       # recorded, never counted
        elif any('[tear-off]' in o for o in owners):
            cats['tearoff_pools'] += 1                        # not a call
        elif any(o.split()[-1] == target or o.endswith(' ' + target) for o in owners):
            cats['self_owned_pools'] += 1                     # not a call
        else:
            cats['caller_owned_pools'] += 1                   # the ONLY policy input
    emit('ONE_OR_MORE_QUALIFYING_CALLSITES' if cats['caller_owned_pools'] >= 1
         else 'ZERO_QUALIFYING_CALLSITES')
PY

# ---- one release, three snapshot shapes ------------------------------------
mkdir -p "$WORK/lib" "$WORK/.dart_tool"
cp "$RB/packaging/container_target.dart" "$WORK/lib/container_target.dart"
python3 - "$WORK/lib/container_target.dart" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace("void _state(String when) =>", """String foldConst() => 1 > 0 ? 'CST' : 'X';

String foldOpaque() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OPQ' : 'X';

String deadBranch(String x) =>
    DateTime.now().millisecondsSinceEpoch >= 0 ? 'DBR-$x' : 'X';

String _specimenLine() {
  final live = '${foldOpaque()}/${foldConst()}';
  if (DateTime.now().millisecondsSinceEpoch < 0) {
    return '$live/${deadBranch('never')}';
  }
  return live;
}

void _state(String when) =>""", 1)
s = s.replace("print('$when alpha=${alpha()} beta=${beta()}');",
              "print('$when alpha=${alpha()} beta=${beta()} spec=${_specimenLine()}');", 1)
p.write_text(s)
PY
cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$WORK/", "packageUri": "lib/",
    "languageVersion": "3.9" },
  { "name": "crypto", "rootUri": "file://$PKGS_DIR/crypto", "packageUri": "lib/",
    "languageVersion": "3.4" },
  { "name": "typed_data", "rootUri": "file://$PKGS_DIR/typed_data",
    "packageUri": "lib/", "languageVersion": "3.4" } ] }
JSON
URI=package:dynamic_modules/container_target.dart
SDK='dart:core#print,dart:core#DateTime.now,dart:core#DateTime.get:millisecondsSinceEpoch'
cd "$WORK"

note "one release kernel, shared by every shape"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o prepass.dill "$URI" >/dev/null
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot \
  --no-link-platform --packages .dart_tool/package_config.json \
  -o import.dill "$URI" >/dev/null
# shellcheck disable=SC2086
"$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill prepass.dill \
  --private-dill import.dill --policy p2 --out di.yaml --manifest m.json \
  --sdk-members "$SDK" >/dev/null 2>&1
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
  -o release.dill "$URI" >/dev/null
echo "    release.dill sha256: $(shasum -a 256 release.dill | cut -c1-16)"

shape() { # <label> <profile> <gen_snapshot args...>
  local label=$1 prof=$2 t want; shift 2
  note "shape: $label"
  if ! "$GEN_SNAPSHOT" --patchable_static_calls "$@" \
        --write-v8-snapshot-profile-to="$prof" release.dill 2>"$prof.err"; then
    echo "  STOP  $label FAILED TO BUILD -- not a pass"; sed -n '1,5p' "$prof.err"
    fail=$((fail+1)); return
  fi
  [ -s "$prof" ] || { echo "  STOP  $label produced no profile"; fail=$((fail+1)); return; }
  echo "    profile bytes: $(wc -c < "$prof")"
  python3 classify.py "$prof" foldOpaque foldConst deadBranch \
    | while read -r a b rest; do echo "    $a  $b"; echo "        $rest"; done
  for t in foldOpaque foldConst deadBranch; do
    case $t in foldConst) want=ZERO_QUALIFYING_CALLSITES;;
      *) want=ONE_OR_MORE_QUALIFYING_CALLSITES;; esac
    check "$label: $t" \
      "$(python3 classify.py "$prof" "$t" | awk '{print $2}')" "$want"
  done
}

shape "elf (survey baseline)" p_elf.json  --snapshot_kind=app-aot-elf --elf=a_elf.aot
shape "elf --strip (Android)" p_strip.json --snapshot_kind=app-aot-elf --elf=a_strip.aot --strip
shape "assembly (iOS)"        p_asm.json  --snapshot_kind=app-aot-assembly --assembly=a.S

note "cross-shape equivalence: the classification must not depend on the shape"
for t in foldOpaque foldConst deadBranch; do
  a=$(python3 classify.py p_elf.json "$t" | awk '{print $2}')
  b=$(python3 classify.py p_strip.json "$t" | awk '{print $2}')
  c=$(python3 classify.py p_asm.json "$t" | awk '{print $2}')
  check "$t identical across elf / elf+strip / assembly" "$a|$b|$c" "$a|$a|$a"
done

note "PASS=$pass FAIL=$fail"
echo "work dir kept: $WORK"
[ "$fail" -eq 0 ]
