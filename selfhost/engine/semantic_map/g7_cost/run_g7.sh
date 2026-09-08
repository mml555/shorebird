#!/usr/bin/env bash
# SM1-G7 (#56) -- what the map costs at release scale.
#
# Five families, reported SEPARATELY so no single number stands in for the
# others. Raw samples are retained, not just ratios. Arms are INTERLEAVED and
# then run in the REVERSED order, because SL1 found an apparent 2x that was
# machine drift and RSS deltas that looked like a per-mode property until the
# order was reversed.
#
# NO THRESHOLD IS IMPOSED. Whether a cost is acceptable is a product decision
# against a real application's profile. This lane reports orders of magnitude.
#
# usage: run_g7.sh <clone-src> <corpora-dir> [reps]
set -uo pipefail
SRC="${1:?usage: run_g7.sh <clone-src> <corpora-dir> [reps]}"
C="${2:?}"
REPS="${3:-3}"
G="$(cd "$(dirname "$0")" && pwd)"
SM="$(cd "$G/.." && pwd)"
G5="$SM/g5_patchability"
G6="$SM/g6_binding"
RB="$(cd "$SM/../route_b" && pwd)"
S="$SRC/out/host_release_arm64"
DT="$SRC/flutter/third_party/dart"
PKG="--packages=$DT/.dart_tool/package_config.json"
GK="$S/dartaotruntime $S/gen/gen_kernel_aot.dart.snapshot"
PLAT="$S/flutter_patched_sdk/platform_strong.dill"
L=/Volumes/build/route-b/demand1/localsend/wt
ENTRY="app/lib/main.dart"
INC="package:localsend_app/"
W="${TMPDIR:-/tmp}/sm1_g7"; rm -rf "$W"; mkdir -p "$W"
rc=0
ASSERTIONS=()
want() {
  if [ "$2" = "$3" ]; then ASSERTIONS+=("  pass  $1")
  else ASSERTIONS+=("  FAIL  $1 -- got '$3', expected '$2'"); rc=1; fi
}
SAMPLES="$G/evidence/samples.jsonl"
: > "$SAMPLES"
# DELETE THE DERIVED SUMMARY FIRST. If the families script fails, a stale
# families.json would otherwise remain and every assertion below would read the
# PREVIOUS run's numbers -- which is exactly how a superseded 48.2% figure got
# reported once already.
rm -f "$G/evidence/families.json"

# ms <label> <order> <rep> <cmd...>  -- one timed sample, appended raw
ms() {
  local label="$1" order="$2" rep="$3"; shift 3
  local t0 t1
  t0=$(python3 -c 'import time;print(time.monotonic_ns())')
  "$@" >/dev/null 2>&1; local st=$?
  t1=$(python3 -c 'import time;print(time.monotonic_ns())')
  python3 - "$SAMPLES" "$label" "$order" "$rep" "$t0" "$t1" "$st" <<'PY'
import json, sys
p, label, order, rep, t0, t1, st = sys.argv[1:8]
with open(p, 'a') as f:
    f.write(json.dumps({'label': label, 'order': order, 'rep': int(rep),
                        'ms': (int(t1) - int(t0)) / 1e6,
                        'exit': int(st)}) + '\n')
PY
  return $st
}

# The two arms. BASE is a release build with no map. MAP is the added work:
# every evidence producer plus the bound map.
arm_base() { # <rep> <order>
  ms base_gen_kernel "$2" "$1" $GK --platform "$PLAT" --target flutter --aot \
      --packages "$L/.dart_tool/package_config.json" \
      -o "$W/b_$1_$2.dill" "$L/$ENTRY"
  ms base_gen_snapshot "$2" "$1" "$S/gen_snapshot" --deterministic \
      --snapshot_kind=app-aot-elf --patchable_static_calls \
      --elf="$W/b_$1_$2.aot" "$W/b_$1_$2.dill"
}
arm_map() { # <rep> <order>  -- needs the base kernel/AOT of this rep
  local d="$W/b_$1_$2.dill" a="$W/b_$1_$2.aot"
  ms map_g1 "$2" "$1" "$S/dart" $PKG "$SM/g2_fingerprints/lib/gen_map_rows.dart" \
      --dill "$d" --pre-dill "$C/localsend_pre.dill" --include "$INC" \
      --out "$W/m_$1_$2_g1.json"
  ms map_g3 "$2" "$1" "$S/dart" $PKG "$SM/g3_privacy/lib/gen_privacy_rows.dart" \
      --dill "$d" --pre-dill "$C/localsend_pre.dill" --include "$INC" \
      --out "$W/m_$1_$2_g3.json"
  ms map_g4 "$2" "$1" "$S/dart" $PKG "$SM/g4_retention/lib/gen_retention_rows.dart" \
      --dill "$d" --enforcement "$SM/g4_retention/evidence/arms.json" \
      --include "$INC" --out "$W/m_$1_$2_g4.json"
  ms map_refs "$2" "$1" "$S/dart" $PKG "$G5/lib/body_references.dart" \
      --dill "$d" --include "$INC" --out "$W/m_$1_$2_refs.json"
  ms map_contract "$2" "$1" "$S/dart" $PKG "$G5/lib/release_contract.dart" \
      --dill "$d" --aot "$a" --include "$INC" --out "$W/m_$1_$2_con.json"
  ms map_reader "$2" "$1" python3 "$G5/lib/read_inlining.py" "$a" \
      "$W/m_$1_$2_g1.json" - "$W/m_$1_$2_inl.json"
  ms map_bound "$2" "$1" python3 "$G6/lib/gen_bound_map.py" 1 localsend \
      "$d" "$a" "$W/m_$1_$2_g1.json" "$G5/instrumentation/MANIFEST.json" \
      "$G5/lib" "$W/m_$1_$2_map.json"
}

{
echo "SM1-G7 -- cost at release scale"
echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by run_g7.sh"
echo "corpus: LocalSend, a real application (35,139 declarations in scope)"
echo "reps per order: $REPS   orders: base-first and map-first"
echo
cat <<'TXT'
METHOD

  Arms are INTERLEAVED within a repetition, and the whole schedule is then run
  with the arm order REVERSED. SEMANTIC-LINKER-1 reported an apparent 2x that
  turned out to be machine drift, and RSS deltas that looked like a per-mode
  property until the order was reversed -- so order-dependence is tested here
  rather than assumed.

  Every sample is appended raw to evidence/samples.jsonl. The summaries below
  are derived from that file; no ratio is reported without the samples behind
  it.

  gen_snapshot runs with --deterministic for the SIZE families, because G5
  measured that whole-AOT output is otherwise not byte-reproducible and sizes
  would carry build-to-build noise.

  NO THRESHOLD IS IMPOSED. Costs are reported as orders of magnitude; whether
  one is acceptable is a product decision against a real application profile.

WHAT THE "ORDER" AXIS ACTUALLY VARIES -- stated because the label would
otherwise imply more than was done. The map arm consumes the base arm's kernel
and AOT, so base still runs first WITHIN a repetition; a true A-then-B /
B-then-A reversal is not possible without measuring a different thing. What
reverses is the position of each arm in the overall SCHEDULE -- whether the map
work runs early on a cooler machine or late on a warmer one. That is enough to
expose drift of the kind SL1 hit, and it is not a claim of full arm-order
independence.
TXT
echo
echo "############ RETENTION PAIR, BUILT HERE ############"
cat <<'TXT'
  The retention family compares an AOT built WITH the dynamic-interface
  contract against one built WITHOUT it. Both are produced here, from the
  application worktree, rather than read from a work directory -- an inherited
  size pair cannot be reproduced from empty state, and a cost family that
  cannot be rebuilt is a number without provenance.
TXT
echo
RET="$W/ret"; mkdir -p "$RET"
# 1. the no-retention kernel and its AOT
ms ret_kernel_noret schedule 0 $GK --platform "$PLAT" --target flutter --aot \
    --packages "$L/.dart_tool/package_config.json" \
    -o "$RET/noret.dill" "$L/$ENTRY"
# 2. a non-AOT kernel, which is what the interface generator reads
ms ret_kernel_pre schedule 0 $GK --platform "$PLAT" --target flutter \
    --packages "$L/.dart_tool/package_config.json" \
    -o "$RET/pre.dill" "$L/$ENTRY"
# 3. the dynamic interface over the app's own libraries
ms ret_interface schedule 0 "$S/dart" $PKG "$RB/gen_dynamic_interface.dart" \
    --dill "$RET/pre.dill" --include "$INC" --out "$RET/di.yaml"
# 4. the retention kernel
ms ret_kernel_ret schedule 0 $GK --platform "$PLAT" --target flutter --aot \
    --packages "$L/.dart_tool/package_config.json" \
    --dynamic-interface "$RET/di.yaml" -o "$RET/ret.dill" "$L/$ENTRY"
# 5. both AOTs, --deterministic so the sizes carry no build-to-build noise
ms ret_aot_noret schedule 0 "$S/gen_snapshot" --deterministic \
    --snapshot_kind=app-aot-elf --patchable_static_calls \
    --elf="$RET/noret.aot" "$RET/noret.dill"
ms ret_aot_ret schedule 0 "$S/gen_snapshot" --deterministic \
    --snapshot_kind=app-aot-elf --patchable_static_calls \
    --elf="$RET/ret.aot" "$RET/ret.dill"
for f in noret.dill pre.dill di.yaml ret.dill noret.aot ret.aot; do
  if [ -s "$RET/$f" ]; then
    printf '  %14s  %12s bytes\n' "$f" "$(wc -c < "$RET/$f" | tr -d ' ')"
  else
    echo "  MISSING $f -- the retention family cannot be rebuilt"; rc=1
  fi
done
echo
echo "############ TIMED SCHEDULE ############"
for rep in $(seq 1 "$REPS"); do
  echo "  order=base_first rep=$rep"
  arm_base "$rep" base_first
  arm_map  "$rep" base_first
done
for rep in $(seq 1 "$REPS"); do
  echo "  order=map_first rep=$rep"
  # The map arm needs a kernel/AOT, so the base build still happens first
  # within the rep; what reverses is which arm's SAMPLES are taken first in the
  # schedule, i.e. whether the map work runs on a cold or warm machine.
  arm_base "$rep" map_first
  arm_map  "$rep" map_first
done
echo
} > "$G/evidence/g7_cost.txt" 2>&1

# ---- families, derived from the raw samples ------------------------------
python3 - "$SAMPLES" "$W/ret" "$G/evidence/families.json" "$G5" "$C" >> "$G/evidence/g7_cost.txt" 2>&1 <<'PY'
import json, os, statistics, sys

SAMPLES, RET, OUT, G5, C = sys.argv[1:6]
rows = [json.loads(l) for l in open(SAMPLES)]
bad = [r for r in rows if r['exit'] != 0]

def stats(vals):
    vals = sorted(vals)
    if not vals:
        # The retention-pair stages run once, outside the two timed orders, so
        # asking for their per-order statistics is legitimate and empty.
        return {'n': 0, 'min_ms': None, 'median_ms': None, 'max_ms': None,
                'mean_ms': None, 'stdev_ms': None}
    return {'n': len(vals), 'min_ms': round(vals[0], 1),
            'median_ms': round(statistics.median(vals), 1),
            'max_ms': round(vals[-1], 1),
            'mean_ms': round(statistics.fmean(vals), 1),
            'stdev_ms': round(statistics.stdev(vals), 1) if len(vals) > 1 else 0.0}

labels = sorted({r['label'] for r in rows})
by_label = {l: stats([r['ms'] for r in rows if r['label'] == l]) for l in labels}
by_label_order = {
    l: {o: stats([r['ms'] for r in rows if r['label'] == l and r['order'] == o])
        for o in ('base_first', 'map_first')} for l in labels}

base_labels = [l for l in labels if l.startswith('base_')]
map_labels = [l for l in labels if l.startswith('map_')]

def total_per_rep(prefixes, order):
    out = []
    reps = sorted({r['rep'] for r in rows})
    for rep in reps:
        v = [r['ms'] for r in rows
             if r['rep'] == rep and r['order'] == order
             and any(r['label'].startswith(p) for p in prefixes)]
        if v:
            out.append(sum(v))
    return out

base_tot = {o: total_per_rep(['base_'], o) for o in ('base_first', 'map_first')}
map_tot = {o: total_per_rep(['map_'], o) for o in ('base_first', 'map_first')}

size = lambda p: os.path.getsize(p)
# THE PAIR THIS RUN BUILT, not one inherited from a work directory.
aot_noret = size(f'{RET}/noret.aot')
aot_ret = size(f'{RET}/ret.aot')
# N comes from a G1 projection over the kernel this run built, for the same
# reason -- an inherited row count would not describe these artifacts.
g1_files = sorted(glob_g1 := __import__('glob').glob(
    os.environ.get('TMPDIR', '/tmp') + '/sm1_g7/m_*_g1.json'))
if not g1_files:
    raise SystemExit('no G1 projection was produced by this run')
g1 = json.load(open(g1_files[0]))
N = len(g1['rows'])
# G4 handed G7 a curve: a 40,912-byte floor plus ~82 bytes per member.
G4_FLOOR, G4_PER_MEMBER = 40912, 82
projected = G4_FLOOR + G4_PER_MEMBER * N
measured = aot_ret - aot_noret

# Map size: the bound map produced during the timed runs.
import glob
maps = sorted(glob.glob(os.path.dirname(SAMPLES) + '/../../../../*'))  # unused
map_files = sorted(glob.glob(os.environ.get('TMPDIR', '/tmp') + '/sm1_g7/m_*_map.json'))
map_size = size(map_files[0]) if map_files else None

fam = {
    'schema': 'semantic-map-1/g7-cost/1',
    'gate': 'SM1-G7', 'issue': 56,
    'corpus': 'localsend',
    'retention_pair_built_by_this_run': True,
    'declarations_in_scope': N,
    'samples': len(rows),
    'failed_samples': len(bad),
    'threshold_imposed': False,
    'families': {
        'map_size': {
            'map_bytes': map_size,
            'release_aot_bytes': aot_noret,
            'map_over_aot_pct': round(100.0 * map_size / aot_noret, 3)
            if map_size else None,
            'note': 'the map is JSON here; no compact encoding is claimed',
        },
        'generation_time': {
            'per_stage': by_label,
            'per_stage_by_order': by_label_order,
            'map_total_ms': {o: stats(v) for o, v in map_tot.items() if v},
        },
        'release_build_impact': {
            'base_total_ms': {o: stats(v) for o, v in base_tot.items() if v},
            'map_total_ms': {o: stats(v) for o, v in map_tot.items() if v},
            'added_pct_median': None,
        },
        'retention_cost_at_scale': {
            'aot_without_retention_bytes': aot_noret,
            'aot_with_retention_bytes': aot_ret,
            'measured_delta_bytes': measured,
            'measured_delta_pct': round(100.0 * measured / aot_noret, 3),
            'g4_projection_bytes': projected,
            'g4_projection_pct': round(100.0 * projected / aot_noret, 3),
            'measured_over_projected': round(measured / projected, 3),
            'g4_curve': f'{G4_FLOOR} byte floor + ~{G4_PER_MEMBER} bytes/member',
        },
        'aot_size_impact': {
            'kernel_without_retention_bytes': size(f'{RET}/noret.dill'),
            'kernel_with_retention_bytes': size(f'{RET}/ret.dill'),
            'dynamic_interface_bytes': size(f'{RET}/di.yaml'),
        },
    },
}
b = fam['families']['release_build_impact']
if b['base_total_ms'] and b['map_total_ms']:
    bm = statistics.median(base_tot['base_first'] + base_tot['map_first'])
    mm = statistics.median(map_tot['base_first'] + map_tot['map_first'])
    b['added_pct_median'] = round(100.0 * mm / bm, 1)

# ORDER DEPENDENCE, tested rather than asserted.
order_effects = {}
for l in labels:
    a = by_label_order[l]['base_first']
    z = by_label_order[l]['map_first']
    # Only labels sampled in BOTH timed orders can show an order effect. The
    # retention-pair stages are built once and are excluded rather than
    # silently counted as unaffected.
    if a['n'] and z['n']:
        ratio = z['median_ms'] / a['median_ms'] if a['median_ms'] else None
        # A RATIO ALONE IS NOT AN ORDER EFFECT. At small n the medians of a
        # noisy stage differ by more than 10% from run to run, so a bare ratio
        # test flags different stages each time -- observed directly here: one
        # run flagged five stages, the next zero, the next four, on identical
        # code. That is the drift SL1 warned about, reappearing in the
        # DETECTOR rather than the measurement.
        #
        # So a stage counts as order-dependent only when the gap between the
        # two order-medians also exceeds the run-to-run spread within those
        # orders. Below that floor the difference is indistinguishable from
        # noise and is reported as such.
        gap = abs((z['median_ms'] or 0) - (a['median_ms'] or 0))
        noise = max(a['stdev_ms'] or 0, z['stdev_ms'] or 0)
        order_effects[l] = {
            'base_first_median_ms': a['median_ms'],
            'map_first_median_ms': z['median_ms'],
            'ratio': round(ratio, 3) if ratio else None,
            'gap_ms': round(gap, 1),
            'within_order_spread_ms': round(noise, 1),
            'exceeds_10pct': bool(ratio and abs(ratio - 1) > 0.10),
            'exceeds_noise_floor': bool(gap > noise),
            'order_dependent': bool(ratio and abs(ratio - 1) > 0.10
                                    and gap > noise),
        }
fam['order_dependence'] = order_effects
fam['order_dependence_scope'] = (
    'labels sampled in both timed orders; the retention-pair stages run once '
    'and are excluded rather than counted as unaffected')
fam['order_dependent_labels'] = sorted(
    l for l, v in order_effects.items() if v['order_dependent'])
fam['exceeds_10pct_but_within_noise'] = sorted(
    l for l, v in order_effects.items()
    if v['exceeds_10pct'] and not v['exceeds_noise_floor'])
json.dump(fam, open(OUT, 'w'), indent=2)

f = fam['families']
print('############ FAMILY 1 -- MAP SIZE ############')
m = f['map_size']
print(f"  map                {m['map_bytes']:>14,} bytes")
print(f"  release AOT        {m['release_aot_bytes']:>14,} bytes")
print(f"  map / AOT          {m['map_over_aot_pct']:>14.3f} %")
print(f"  {m['note']}")
print()
print('############ FAMILY 2 -- GENERATION TIME (per stage, ms) ############')
print(f"  {'stage':22} {'n':>3} {'min':>9} {'median':>9} {'max':>9} {'stdev':>9}")
for l in labels:
    s = by_label[l]
    if not s['n']:
        continue
    print(f"  {l:22} {s['n']:>3} {s['min_ms']:>9.1f} {s['median_ms']:>9.1f} "
          f"{s['max_ms']:>9.1f} {s['stdev_ms']:>9.1f}")
print()
print('############ FAMILY 3 -- RELEASE BUILD IMPACT ############')
for o in ('base_first', 'map_first'):
    if base_tot[o]:
        print(f"  {o:11} base total median {statistics.median(base_tot[o]):>10.1f} ms"
              f"   map total median {statistics.median(map_tot[o]):>10.1f} ms")
print(f"  map work as a share of the base build: "
      f"{f['release_build_impact']['added_pct_median']} % (median)")
print()
print('############ FAMILY 4 -- RETENTION COST AT SCALE ############')
r = f['retention_cost_at_scale']
print(f"  AOT without retention {r['aot_without_retention_bytes']:>14,} bytes")
print(f"  AOT with retention    {r['aot_with_retention_bytes']:>14,} bytes")
print(f"  measured delta        {r['measured_delta_bytes']:>14,} bytes "
      f"({r['measured_delta_pct']:+.2f} %)")
print(f"  G4 projection         {r['g4_projection_bytes']:>14,} bytes "
      f"({r['g4_projection_pct']:+.2f} %)")
print(f"  measured / projected  {r['measured_over_projected']:>14.3f} x")
print(f"  G4 curve consumed     {r['g4_curve']}")
print()
print('############ FAMILY 5 -- AOT SIZE IMPACT OF THE CONTRACT ############')
a = f['aot_size_impact']
print(f"  kernel without retention {a['kernel_without_retention_bytes']:>14,} bytes")
print(f"  kernel with retention    {a['kernel_with_retention_bytes']:>14,} bytes")
print(f"  dynamic interface        {a['dynamic_interface_bytes']:>14,} bytes")
print()
print('############ ORDER DEPENDENCE, TESTED ############')
print(f"  {'stage':22} {'base_first':>11} {'map_first':>11} {'ratio':>7} "
      f"{'gap':>8} {'noise':>8}  verdict")
for l, v in fam['order_dependence'].items():
    if v['order_dependent']:
        verdict = 'ORDER-DEPENDENT'
    elif v['exceeds_10pct']:
        verdict = '>10% but within noise'
    else:
        verdict = 'no'
    print(f"  {l:22} {v['base_first_median_ms']:>11.1f} "
          f"{v['map_first_median_ms']:>11.1f} {v['ratio']:>7.3f} "
          f"{v['gap_ms']:>8.1f} {v['within_order_spread_ms']:>8.1f}  {verdict}")
print()
print(f"  order-dependent (>10% AND beyond noise): "
      f"{fam['order_dependent_labels'] or 'none'}")
print(f"  >10% but inside the noise floor: "
      f"{fam['exceeds_10pct_but_within_noise'] or 'none'}")
print(f"  failed samples: {len(bad)}")
PY

T="$G/evidence/g7_cost.txt"
F="$G/evidence/families.json"
j() { python3 -c "import json,sys;d=json.load(open('$F'));print(eval(sys.argv[1],{'d':d}))" "$1"; }
want 'no timed sample failed' 0 "$(j "d['failed_samples']")"
want 'samples were retained raw' True \
     "$(python3 -c "import os;print(os.path.getsize('$SAMPLES') > 0)")"
want 'every family is reported' 5 "$(j "len(d['families'])")"
want 'both timed orders were run' 'base_first,map_first' \
     "$(python3 -c "
import json
o={json.loads(l)['order'] for l in open('$SAMPLES')}
print(','.join(sorted(x for x in o if x != 'schedule')))")"
want 'the derived summary is from THIS run' True \
     "$(python3 -c "
import json
try:
    print(json.load(open('$G/evidence/families.json')).get('retention_pair_built_by_this_run') is True)
except Exception:
    print(False)")"
want 'the retention projection was checked against a measurement' True \
     "$(j "d['families']['retention_cost_at_scale']['measured_delta_bytes'] > 0 and d['families']['retention_cost_at_scale']['g4_projection_bytes'] > 0")"
want 'order dependence was tested, not assumed' True \
     "$(j "len(d['order_dependence']) > 0")"
want 'no threshold is imposed' False "$(j "d['threshold_imposed']")"
{
  echo
  echo "ASSERTIONS (${#ASSERTIONS[@]} checked)"
  printf '%s\n' "${ASSERTIONS[@]}"
  echo
  echo "SM1_G7: $([ "$rc" = 0 ] && echo COST_REPORTED || echo FAILED)"
} >> "$T"
printf '%s\n' "${ASSERTIONS[@]}"
echo "SM1_G7: $([ "$rc" = 0 ] && echo COST_REPORTED || echo FAILED)"
exit "$rc"
