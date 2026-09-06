#!/usr/bin/env bash
# cspell:want dartaotruntime dill semantic linker devirtualization
# run_costs.sh -- SEMANTIC-LINKER-1 / G6B. Four cost families, reported
# INDEPENDENTLY, with raw samples retained.
#
# The point of separating them is that a single "dynamic modules overhead"
# number would be misleading in both directions: the substrate cost is paid by
# every build, the interface cost only by declared-patchable members, the module
# cost only after a load, and the execution cost only at a boundary actually
# crossed.
#
# NO PRODUCTION THRESHOLD IS IMPOSED. This lane reports orders of magnitude.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LANE=${LANE:-/Volumes/build/semantic-linker/sl1}
SRC="$LANE/flutter/engine/src"
OUT_OFF="$SRC/out/sl1_dm_off"
OUT_ON="$SRC/out/sl1_dm_on"
ARM=${ARM:-g3_on}
OUT="$SRC/out/sl1_$ARM"
ITERS=${ITERS:-10000000}
REPS=${REPS:-5}
EVID="$HERE/evidence"; mkdir -p "$EVID"
LOGF="$EVID/costs.txt"
RAW="$EVID/raw_samples.txt"
: > "$RAW"
DART_TREE="$SRC/flutter/third_party/dart"
GK="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
D2B="$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart"
DART="$OUT/dart-sdk/bin/dart"
G4="$HERE/../g4_optimizer/probe"

sz() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1"; }
maxrss() { # <cmd...> -> peak RSS bytes, via the shell's own time builtin
  /usr/bin/time -l "$@" 2>&1 >/dev/null | awk '/maximum resident set size/{print $1}'
}

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/lib" "$W/.dart_tool"
cp "$HERE/probe/bench_host.dart" "$W/lib/"
cp "$HERE/probe/m_bench.dart" "$W/"
cat > "$W/.dart_tool/package_config.json" <<JSON
{"configVersion":2,"packages":[{"name":"dynamic_modules","rootUri":"file://$W/","packageUri":"lib/","languageVersion":"3.9"}]}
JSON

{
echo "SL1-G6B cost measurement"
echo "date  : $(date -u +%FT%TZ)"
echo "arm   : $ARM   iters=$ITERS reps=$REPS"
echo "host  : $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
echo

echo "=================== FAMILY A — runtime substrate (DM OFF vs ON) ==================="
echo "Measured BEFORE any module is loaded: this is what every build pays."
printf '%-22s %14s %14s %10s\n' artifact OFF ON delta
for f in dartaotruntime gen_snapshot vm_platform.dill dart-sdk/bin/dart; do
  a=$(sz "$OUT_OFF/$f"); b=$(sz "$OUT_ON/$f")
  printf '%-22s %14s %14s %9s%%\n' "$f" "$a" "$b" "$(python3 -c "print(f'{($b-$a)*100/$a:+.2f}')")"
done
echo
# A trivial AOT program built by EACH arm's own toolchain, run under its own
# runtime: startup, peak RSS, and a compute loop that touches no boundary.
cat > "$W/tiny.dart" <<'DART'
import 'dart:io';
@pragma('vm:never-inline')
int f(int x) => x ^ 0x5a5a;
void main() {
  var a = 0;
  final n = int.parse(Platform.environment['N'] ?? '20000000');
  final sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) { a ^= f(i); }
  sw.stop();
  print('TINY micros=${sw.elapsedMicroseconds} sink=$a rss=${ProcessInfo.currentRss}');
}
DART
for arm in off on; do
  O=$([[ $arm == off ]] && echo "$OUT_OFF" || echo "$OUT_ON")
  "$O/dart-sdk/bin/dart" "$GK" --platform "$O/vm_platform.dill" --aot \
    --packages "$W/.dart_tool/package_config.json" -o "$W/tiny_$arm.dill" "$W/tiny.dart" >/dev/null 2>&1
  "$O/gen_snapshot" --snapshot_kind=app-aot-elf --elf="$W/tiny_$arm.aot" "$W/tiny_$arm.dill" >/dev/null 2>&1
  echo "tiny.aot ($arm) bytes=$(sz "$W/tiny_$arm.aot")"
  for r in $(seq 1 "$REPS"); do
    s=$( { /usr/bin/time -l "$O/dartaotruntime" "$W/tiny_$arm.aot"; } 2>&1 )
    echo "A $arm rep$r $s" >> "$RAW"
    echo "  rep$r $(grep -o 'TINY micros=[0-9]*' <<<"$s") peak_rss=$(awk '/maximum resident set size/{print $1}' <<<"$s")"
  done
  # startup: an empty program, so the number is process start, not the loop
  echo 'void main() {}' > "$W/empty.dart"
  "$O/dart-sdk/bin/dart" "$GK" --platform "$O/vm_platform.dill" --aot \
    --packages "$W/.dart_tool/package_config.json" -o "$W/empty_$arm.dill" "$W/empty.dart" >/dev/null 2>&1
  "$O/gen_snapshot" --snapshot_kind=app-aot-elf --elf="$W/empty_$arm.aot" "$W/empty_$arm.dill" >/dev/null 2>&1
  t0=$(python3 -c 'import time;print(int(time.time()*1000000))')
  for r in $(seq 1 20); do "$O/dartaotruntime" "$W/empty_$arm.aot" >/dev/null 2>&1; done
  t1=$(python3 -c 'import time;print(int(time.time()*1000000))')
  echo "  startup: $(( (t1-t0)/20 )) micros/run over 20 runs (empty main)"
  echo "A $arm startup_micros_per_run $(( (t1-t0)/20 ))" >> "$RAW"
done
echo

echo "=================== FAMILY B — dynamic-interface / patchability cost ==================="
echo "The SAME host with and without the required contract (G4's fenced/unfenced"
echo "solo pair). This is the cost of declaring a member patchable."
for v in fenced unfenced; do
  "$DART" "$GK" --platform "$OUT/vm_platform.dill" --aot \
    --packages "$W/.dart_tool/package_config.json" \
    --dynamic-interface "$G4/di_solo_$v.yaml" -o "$W/b_$v.dill" \
    package:dynamic_modules/g4_host_solo.dart >/dev/null 2>&1 || true
  if [[ ! -f "$W/b_$v.dill" ]]; then
    cp "$G4/g4_host_solo.dart" "$W/lib/g4_host_solo.dart"
    "$DART" "$GK" --platform "$OUT/vm_platform.dill" --aot \
      --packages "$W/.dart_tool/package_config.json" \
      --dynamic-interface "$G4/di_solo_$v.yaml" -o "$W/b_$v.dill" \
      package:dynamic_modules/g4_host_solo.dart >/dev/null 2>&1
  fi
  "$OUT/gen_snapshot" --snapshot_kind=app-aot-elf --elf="$W/b_$v.aot" "$W/b_$v.dill" >/dev/null 2>&1
  echo "  host.aot $v: dill=$(sz "$W/b_$v.dill") aot=$(sz "$W/b_$v.aot")"
  echo "B $v dill=$(sz "$W/b_$v.dill") aot=$(sz "$W/b_$v.aot")" >> "$RAW"
done
python3 -c "
import os
a=os.path.getsize('$W/b_unfenced.aot'); b=os.path.getsize('$W/b_fenced.aot')
print(f'  retained-AOT cost of the contract: {b-a} bytes ({(b-a)*100/a:+.3f}%)')
print('  lost devirtualization: the fenced build keeps a dispatch-table call at')
print('  every one of G4\'s five shapes; the unfenced build devirtualizes them')
print('  (and inlines one). That is the same difference, measured as code shape')
print('  in G4 and as bytes here.')
"
echo

echo "=================== FAMILY C + D — module and execution ==================="
"$DART" "$GK" --platform "$OUT/vm_platform.dill" --aot \
  --packages "$W/.dart_tool/package_config.json" --dynamic-interface "$HERE/probe/di_bench.yaml" \
  -o "$W/bench.dill" package:dynamic_modules/bench_host.dart 2>&1 | sed 's/^/   /'
"$OUT/gen_snapshot" --snapshot_kind=app-aot-elf --elf="$W/bench.aot" "$W/bench.dill" 2>&1 | sed 's/^/   /'
"$DART" "$GK" --platform "$OUT/vm_platform.dill" --no-aot --no-link-platform \
  --packages "$W/.dart_tool/package_config.json" -o "$W/bench_import.dill" \
  package:dynamic_modules/bench_host.dart >/dev/null 2>&1
"$DART" "$D2B" --platform "$OUT/vm_platform.dill" --import-dill "$W/bench_import.dill" \
  -o "$W/m_bench.bytecode" "$W/m_bench.dart" 2>&1 | sed 's/^/   /'
echo "  bench.aot bytes=$(sz "$W/bench.aot")  module bytes=$(sz "$W/m_bench.bytecode")"
echo
for r in $(seq 1 "$REPS"); do
  echo "--- rep $r ---"
  o=$(G6B_SEED=$r "$OUT/dartaotruntime" "$W/bench.aot" "$ITERS" "$W/m_bench.bytecode" 2>&1)
  sed 's/^/   /' <<<"$o"
  echo "D rep$r $o" >> "$RAW"
done
echo

echo "=================== SUMMARY (medians over $REPS reps) ==================="
python3 - "$RAW" <<'PY'
import re,sys,statistics
raw=open(sys.argv[1]).read()
modes={}
for m,ns in re.findall(r'BENCH (\w+) iters=\d+ micros=\d+ ns_per_call=([\d.]+)', raw):
    modes.setdefault(m,[]).append(float(ns))
if modes:
    base=statistics.median(modes.get('aot_to_aot_direct',[1]))
    print(f"{'mode':<24}{'ns/call (median)':>18}{'min':>10}{'max':>10}{'x direct':>10}")
    for m in ['aot_to_aot_direct','aot_to_aot_virtual','aot_to_bytecode','bytecode_to_aot','bytecode_to_bytecode']:
        if m in modes:
            v=modes[m]
            print(f"{m:<24}{statistics.median(v):>18.2f}{min(v):>10.2f}{max(v):>10.2f}{statistics.median(v)/base:>9.1f}x")
for label,pat in (('load latency (us)', r'LOAD micros=(\d+)'), ('rss delta (bytes)', r'rss_delta=(-?\d+)')):
    vals=[float(x) for x in re.findall(pat, raw)]
    if vals: print(f"{label:<24}{statistics.median(vals):>18.1f}{min(vals):>10.1f}{max(vals):>10.1f}")
PY
} > "$LOGF" 2>&1
tail -14 "$LOGF"; echo "transcript: $LOGF"; echo "raw: $RAW"
