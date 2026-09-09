#!/usr/bin/env bash
# SM1-G8 (#57) -- clean reproduction and the centralized negative inventory.
#
# Rebuilds rather than inherits, checks ONE mandatory inventory, proves
# inventory == tested == caught, falsifies missing and corrupted evidence with
# byte-for-byte restoration, re-derives the known FAIL_OPEN findings AS
# findings, and proves the product directories are untouched.
#
# It does NOT claim clean reproduction it has not achieved. Where an input
# cannot be reconstructed from checked-in sources, that is reported as a STOP
# condition rather than silently carried.
#
# usage: run_g8.sh <clone-src> <corpora-dir>
set -uo pipefail
SRC="${1:?usage: run_g8.sh <clone-src> <corpora-dir>}"
CORP="${2:?}"
G="$(cd "$(dirname "$0")" && pwd)"
SM="$(cd "$G/.." && pwd)"
REPO="$(cd "$SM/../../.." && pwd)"
S="$SRC/out/host_release_arm64"
DT="$SRC/flutter/third_party/dart"
RB="$SM/../route_b"
W="${TMPDIR:-/tmp}/sm1_g8"; rm -rf "$W"; mkdir -p "$W"
rc=0
STOP=""
ASSERTIONS=()
want() {
  if [ "$2" = "$3" ]; then ASSERTIONS+=("  pass  $1")
  else ASSERTIONS+=("  FAIL  $1 -- got '$3', expected '$2'"); rc=1; fi
}
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
treehash() { # deterministic digest of a directory's tracked content
  git -C "$REPO" ls-files "$1" | sort | while read -r f; do
    printf '%s  %s\n' "$(sha "$REPO/$f")" "$f"
  done | shasum -a 256 | awk '{print $1}'
}

{
echo "SM1-G8 -- clean reproduction and centralized negative inventory"
echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by run_g8.sh"
echo
echo "############ 1. PRODUCT DIRECTORIES, BEFORE ############"
PROD=$(python3 -c "import json;print(' '.join(json.load(open('$G/inventory.json'))['product_directories']['paths']))")
for d in $PROD; do
  h=$(treehash "$d"); eval "BEFORE_${d//[^a-zA-Z0-9]/_}=$h"
  echo "  $h  $d"
done
echo
echo "############ 2. CAN THE PROBE CORPUS BE REBUILT FROM SOURCE? ############"
cat <<'TXT'
  The G5 probe banks consume a work directory: release3.dill, pre_r.dill,
  import.dill, di3.yaml, g2_r.json and four .sbrb containers. #57 requires
  rebuilding rather than inheriting, so this attempts the chain from the
  checked-in probe source and compares.
TXT
echo
N="$W/probe"; mkdir -p "$N/lib" "$N/.dart_tool"
cp "$SM/g5_patchability/probe/callsite_target.dart" "$N/lib/"
PKGS=/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart/third_party/pkg/core/pkgs
cat > "$N/.dart_tool/package_config.json" <<EOF
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$N/", "packageUri": "lib/", "languageVersion": "3.9" },
  { "name": "crypto", "rootUri": "file://$PKGS/crypto", "packageUri": "lib/", "languageVersion": "3.4" },
  { "name": "typed_data", "rootUri": "file://$PKGS/typed_data", "packageUri": "lib/", "languageVersion": "3.4" } ] }
EOF
GKR="$S/dartaotruntime $S/gen/gen_kernel_aot.dart.snapshot"
$GKR --platform "$S/vm_platform.dill" --packages "$N/.dart_tool/package_config.json" \
     --aot -o "$N/prepass.dill" "$N/lib/callsite_target.dart" >/dev/null 2>&1
# TWO CANDIDATE INVOCATIONS ARE TRIED, and both are recorded with their
# deltas, so whoever closes this does not repeat the search. No third guess is
# made: reverse-engineering flags until an artifact matches would manufacture
# a reproduction claim rather than establish one.
"$S/dart" "--packages=$DT/.dart_tool/package_config.json" \
     "$RB/gen_dynamic_interface.dart" --dill "$N/prepass.dill" \
     --include "package:dynamic_modules/callsite_target.dart" \
     --out "$N/di.yaml" >/dev/null 2>&1
"$S/dart" "--packages=$DT/.dart_tool/package_config.json" \
     "$RB/gen_dynamic_interface.dart" --dill "$N/prepass.dill" \
     --out "$N/di_all.yaml" >/dev/null 2>&1
$GKR --platform "$S/vm_platform.dill" --packages "$N/.dart_tool/package_config.json" \
     --aot --dynamic-interface "$N/di.yaml" -o "$N/release.dill" \
     "$N/lib/callsite_target.dart" >/dev/null 2>&1
WD="${TMPDIR:-/tmp}/sm1_g5_in"
python3 - "$N" "$WD" <<'PY' | sed 's/^/  /'
import pathlib, re, sys
N, WD = (pathlib.Path(p) for p in sys.argv[1:3])
banked = WD / 'di3.yaml'
def shape(p):
    if not p.exists():
        return None
    t = p.read_text()
    return (p.stat().st_size, len(re.findall(r'library:', t)),
            len(set(re.findall(r"library: '([^']+)'", t))))
b = shape(banked)
print(f"{'invocation':34} {'bytes':>8} {'entries':>8} {'distinct libs':>14}")
for label, f in (("--include probe library only", N / 'di.yaml'),
                 ("no --include (all non-SDK)", N / 'di_all.yaml'),
                 ("BANKED di3.yaml", banked)):
    sh = shape(f)
    if sh is None:
        print(f"{label:34} {'missing':>8}")
        continue
    print(f"{label:34} {sh[0]:>8} {sh[1]:>8} {sh[2]:>14}"
          + ("   <- target" if f == banked else
             ("   MATCHES" if b and sh == b else "   differs")))
PY
printf '  %-22s %14s  %14s\n' artifact rebuilt banked
for pair in "di.yaml:di3.yaml" "release.dill:release3.dill"; do
  r="${pair%%:*}"; b="${pair##*:}"
  rs=$( [ -f "$N/$r" ] && wc -c < "$N/$r" | tr -d ' ' || echo missing )
  bs=$( [ -f "$WD/$b" ] && wc -c < "$WD/$b" | tr -d ' ' || echo missing )
  printf '  %-22s %14s  %14s\n' "$r vs $b" "$rs" "$bs"
done
cat <<'TXT'

  THE CHAIN RUNS, BUT DOES NOT REPRODUCE THE BANKED CORPUS. Two plausible
  invocations were tried and neither matches: scoping to the probe library
  gives far too little, and taking every non-SDK library still yields fewer
  capability entries and no dart:core members. The banked interface therefore
  used further flags -- SDK member/library selection, or private-class options
  -- and that invocation was never recorded. Its own header records the source
  dill and the retention POLICY, but not the command.

  This is reported as a STOP CONDITION, not worked around. The G5 probe banks
  are reproducible from their WORK DIRECTORY, whose inputs are digest-recorded
  below, but not yet from checked-in sources alone.
TXT
echo
echo "  inherited probe inputs, by digest:"
for f in release3.dill pre_r.dill prepass3.dill import.dill di3.yaml g2_r.json \
         patch_alpha.sbrb patch_basework.sbrb patch_smallTarget.sbrb \
         patch_tearOffTarget.sbrb; do
  if [ -f "$WD/$f" ]; then echo "    $(sha "$WD/$f")  $f"
  else echo "    MISSING $f"; rc=1; fi
done
STOP="probe corpus: di3.yaml recipe unrecorded, so the G5 probe banks cannot be rebuilt from checked-in sources"
echo
echo "############ 3. REBUILT FROM SOURCE: G6 AND G7 ############"
cat <<'TXT'
  These two are self-sufficient: G6 builds its maps from artifacts it names,
  and G7 now builds its own retention pair. Both are re-run here into a fresh
  work state rather than trusted.
TXT
echo
"$SM/g6_binding/run_g6.sh" "$SRC" "$WD" "$CORP" 2>&1 | tail -3 | sed 's/^/    /'
G6_RC=${PIPESTATUS[0]}
"$SM/g7_cost/run_g7.sh" "$SRC" "$CORP" 3 2>&1 | tail -3 | sed 's/^/    /'
G7_RC=${PIPESTATUS[0]}
echo
echo "############ 4. INVENTORY == TESTED == CAUGHT ############"
python3 "$G/lib/check_inventory.py" "$SM" "$G/inventory.json" \
    "$G/evidence/inventory_check.json"
INV_RC=$?
echo "  exit=$INV_RC"
echo
echo "############ 5. NEGATIVES, WITH BYTE-FOR-BYTE RESTORATION ############"
python3 "$G/lib/falsify_reproduction.py" "$SM" "$G/inventory.json" "$W/neg"
NEG_RC=$?
echo "  exit=$NEG_RC"
echo
echo "############ 6. PRODUCT DIRECTORIES, AFTER ############"
for d in $PROD; do
  h=$(treehash "$d")
  v="BEFORE_${d//[^a-zA-Z0-9]/_}"
  if [ "$h" = "${!v}" ]; then echo "  unchanged  $h  $d"
  else echo "  CHANGED    $h  $d"; rc=1; fi
done
} > "$G/evidence/g8_reproduction.txt" 2>&1

T="$G/evidence/g8_reproduction.txt"
want 'G6 reproduces green' 0 "${G6_RC:-1}"
want 'G7 reproduces green' 0 "${G7_RC:-1}"
want 'inventory == tested == caught' 0 "${INV_RC:-1}"
want 'every negative is detected and restored' 0 "${NEG_RC:-1}"
want 'the negatives transcript records ALL_DETECTED_AND_RESTORED' 1 \
     "$(grep -c 'SM1_G8_NEGATIVES: ALL_DETECTED_AND_RESTORED' "$T")"
want 'product directories are unchanged' 0 "$(grep -c '^  CHANGED' "$T")"
want 'the stale-summary negative is present' 1 \
     "$(grep -c 'the summary no longer matches the retained samples' "$T")"
want 'all three classifier controls ran' 3 \
     "$(grep -c '^classifier:\|  classifier:' "$T")"

VERDICT=REPRODUCTION_INCOMPLETE
[ "$rc" = 0 ] && [ -z "$STOP" ] && VERDICT=CLEAN_REPRODUCTION
{
  echo
  echo "ASSERTIONS (${#ASSERTIONS[@]} checked)"
  printf '%s\n' "${ASSERTIONS[@]}"
  echo
  if [ -n "$STOP" ]; then
    echo "STOP CONDITION: $STOP"
    echo "  Everything else below reproduces; this one input chain does not,"
    echo "  and #57 requires stopping rather than silently carrying it."
  fi
  echo "SM1_G8: $VERDICT"
} >> "$T"
printf '%s\n' "${ASSERTIONS[@]}"
[ -n "$STOP" ] && echo "STOP CONDITION: $STOP"
echo "SM1_G8: $VERDICT"
exit "$rc"
