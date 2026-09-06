#!/usr/bin/env bash
# cspell:words dartaotruntime dill semantic linker
# run_alloc.sh -- SEMANTIC-LINKER-1 / G6B addendum. Allocation throughput and
# collection behaviour under mixed execution.
#
# NARROW BY DESIGN. This is not a GC study: it measures the three allocation
# paths the architecture actually creates, and the cost of one collection after
# each, using the G3 instrument and nothing new.
#
# It requires an arm that carries BOTH instruments (execution-mode oracle and
# collectAllGarbageForTesting), i.e. the G3 build.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LANE=${LANE:-/Volumes/build/semantic-linker/sl1}
SRC="$LANE/flutter/engine/src"
ARM=${ARM:-g3_on}
OUT="$SRC/out/sl1_$ARM"
N=${N:-5000000}
REPS=${REPS:-5}
EVID="$HERE/evidence"; mkdir -p "$EVID"
LOGF="$EVID/alloc_gc.txt"
RAW="$EVID/alloc_raw_samples.txt"
: > "$RAW"
DART_TREE="$SRC/flutter/third_party/dart"
GK="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
D2B="$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart"
DART="$OUT/dart-sdk/bin/dart"

grep -q collectAllGarbageForTesting "$SRC/flutter/third_party/dart/sdk/lib/internal/internal.dart" \
  || { echo "the GC instrument is not in this lane tree" >&2; exit 2; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/lib" "$W/.dart_tool"
cp "$HERE/probe/alloc_host.dart" "$W/lib/"
cp "$HERE/probe/m_alloc.dart" "$W/"
cat > "$W/.dart_tool/package_config.json" <<JSON
{"configVersion":2,"packages":[{"name":"dynamic_modules","rootUri":"file://$W/","packageUri":"lib/","languageVersion":"3.9"}]}
JSON
URI=package:dynamic_modules/alloc_host.dart

{
echo "SL1-G6B addendum -- allocation and GC under mixed execution"
echo "date : $(date -u +%FT%TZ)"
echo "arm  : $ARM   n=$N per mode   reps=$REPS"
echo
echo "== build =="
"$DART" "$GK" --platform "$OUT/vm_platform.dill" --aot \
  --packages "$W/.dart_tool/package_config.json" --dynamic-interface "$HERE/probe/di_alloc.yaml" \
  -o "$W/a.dill" "$URI" 2>&1 | sed 's/^/   /'
"$OUT/gen_snapshot" --snapshot_kind=app-aot-elf --elf="$W/a.aot" "$W/a.dill" 2>&1 | sed 's/^/   /'
"$DART" "$GK" --platform "$OUT/vm_platform.dill" --no-aot --no-link-platform \
  --packages "$W/.dart_tool/package_config.json" -o "$W/a_import.dill" "$URI" >/dev/null 2>&1
"$DART" "$D2B" --platform "$OUT/vm_platform.dill" --import-dill "$W/a_import.dill" \
  -o "$W/m_alloc.bytecode" "$W/m_alloc.dart" 2>&1 | sed 's/^/   /'
[[ -f "$W/a.aot" && -f "$W/m_alloc.bytecode" ]] || { echo "   BUILD FAILED"; exit 1; }
echo "   module bytes=$(wc -c < "$W/m_alloc.bytecode" | tr -d ' ')"
echo

for r in $(seq 1 "$REPS"); do
  echo "--- rep $r ---"
  o=$(G6B_SEED=$r "$OUT/dartaotruntime" "$W/a.aot" "$N" "$W/m_alloc.bytecode" 2>&1)
  sed 's/^/   /' <<<"$o"
  echo "$o" >> "$RAW"
done

echo
echo "=================== SUMMARY (medians over $REPS reps) ==================="
python3 - "$RAW" <<'PY'
import re,sys,statistics
raw=open(sys.argv[1]).read()
alloc={}; rssd={}; gcus={}; gcrss={}
for m,ns,rd in re.findall(r'ALLOC (\w+) n=\d+ micros=\d+ ns_per_alloc=([\d.]+) rss_before=\d+ rss_after=\d+ rss_delta=(-?\d+)', raw):
    alloc.setdefault(m,[]).append(float(ns)); rssd.setdefault(m,[]).append(int(rd))
for m,us,rd in re.findall(r'GC (\w+) micros=(\d+) rss_before=\d+ rss_after=\d+ rss_delta=(-?\d+)', raw):
    gcus.setdefault(m,[]).append(int(us)); gcrss.setdefault(m,[]).append(int(rd))
order=['alloc_aot_aot_type','alloc_bytecode_aot_type','alloc_bytecode_patch_type']
base=statistics.median(alloc.get(order[0],[1]))
print(f"{'mode':<28}{'ns/alloc':>10}{'min':>9}{'max':>9}{'x AOT':>8}{'M allocs/s':>12}")
for m in order:
    if m in alloc:
        v=alloc[m]; med=statistics.median(v)
        print(f"{m:<28}{med:>10.2f}{min(v):>9.2f}{max(v):>9.2f}{med/base:>7.1f}x{1000/med:>12.1f}")
print()
print(f"{'mode':<28}{'RSS delta after alloc':>24}{'GC micros':>12}{'RSS freed by GC':>18}")
for m in order:
    if m in alloc:
        print(f"{m:<28}{statistics.median(rssd[m]):>24,.0f}{statistics.median(gcus[m]):>12,.0f}{-statistics.median(gcrss[m]):>18,.0f}")
PY
} > "$LOGF" 2>&1
tail -14 "$LOGF"; echo "transcript: $LOGF"; echo "raw: $RAW"
