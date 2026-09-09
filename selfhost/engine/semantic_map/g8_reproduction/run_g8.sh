#!/usr/bin/env bash
# SM1-G8 (#57) -- clean reproduction and the centralized negative inventory.
#
# Rebuilds from checked-in source rather than inheriting, drives every negative
# from ONE inventory, proves inventory == tested == caught as a LITERAL equality
# over stable ids, restores every mutation byte-for-byte, re-derives the known
# FAIL_OPEN findings as findings, and proves the product surface is untouched.
#
# usage: run_g8.sh <clone-src> <corpora-dir>
set -uo pipefail
SRC="${1:?usage: run_g8.sh <clone-src> <corpora-dir>}"
CORP="${2:?}"
G="$(cd "$(dirname "$0")" && pwd)"
SM="$(cd "$G/.." && pwd)"
REPO="$(cd "$SM/../../.." && pwd)"
G5="$SM/g5_patchability"
W="${TMPDIR:-/tmp}/sm1_g8"; rm -rf "$W"; mkdir -p "$W"
PROBE="$W/probe"
rc=0
STOP=""
ASSERTIONS=()
want() {
  if [ "$2" = "$3" ]; then ASSERTIONS+=("  pass  $1")
  else ASSERTIONS+=("  FAIL  $1 -- got '$3', expected '$2'"); rc=1; fi
}
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
surfacehash() { # digest of every tracked file under a path
  git -C "$REPO" ls-files -- "$1" | sort | while read -r f; do
    printf '%s  %s\n' "$(sha "$REPO/$f")" "$f"
  done | shasum -a 256 | awk '{print $1}'
}

PROD=$(python3 -c "import json;print(' '.join(json.load(open('$G/inventory.json'))['product_directories']['paths']))")
# A file, not an associative array: bash 3.2 ships on macOS and has none.
BEFORE_FILE="$W/product_before.txt"
for d in $PROD; do printf '%s %s\n' "$d" "$(surfacehash "$d")" >> "$BEFORE_FILE"; done
before_of() { awk -v k="$1" '$1==k{print $2}' "$BEFORE_FILE"; }

{
echo "SM1-G8 -- clean reproduction and centralized negative inventory"
echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by run_g8.sh"
echo
echo "############ 1. PRODUCT SURFACE, BEFORE ############"
for d in $PROD; do echo "  $(before_of "$d")  $d"; done
echo
echo "############ 2. THE PROBE CORPUS, REBUILT FROM SOURCE ############"
cat <<'TXT'
  The previous G8 run stopped here: the probe corpus depended on a di3.yaml
  whose producing invocation was never recorded, and two candidate
  reconstructions both missed. The recipe is now AUTHORED in
  g5_patchability/build_probe_corpus.sh -- policy p2, the three app packages,
  three named SDK members, private enumeration from the non-AOT kernel -- with
  each choice justified against what the probe actually exercises.
TXT
echo
"$G5/build_probe_corpus.sh" "$SRC" "$PROBE" 2>&1 | tail -14 | sed 's/^/  /'
PROBE_RC=${PIPESTATUS[0]}
echo
echo "  does the rebuild reproduce the banked identities?"
CANON=$(python3 -c "import json;print(json.load(open('$G5/evidence/inlining_state.json'))['diagnostics']['aot_sha256'])")
REBUILT=$(sha "$PROBE/app_release.aot")
echo "    banked canonical AOT   $CANON"
echo "    rebuilt canonical AOT  $REBUILT"
if [ "$CANON" = "$REBUILT" ]; then echo "    IDENTICAL"; else echo "    DIFFERS"; fi
if cmp -s "$PROBE/g2_r.json" "$G5/evidence/g1_projection.json"; then
  echo "    G1 projection IDENTICAL to the banked copy"
else
  echo "    G1 projection DIFFERS from the banked copy"; rc=1
fi
echo
echo "############ 3. EVERY GATE, RE-RUN ON THE REBUILT CORPUS ############"
for s in run_route2.sh run_dispatch_experiment.sh run_predictor_bank.sh run_subset.sh; do
  printf '  %-30s' "$s"
  if "$G5/$s" "$SRC" "$PROBE" >"$W/${s%.sh}.log" 2>&1; then
    echo "OK   $(grep -c '  pass  ' "$W/${s%.sh}.log") assertions"
  else
    echo "FAILED"; grep -m3 '  FAIL  ' "$W/${s%.sh}.log" | sed 's/^/     /'; rc=1
  fi
done
printf '  %-30s' run_corpora.sh
if "$G5/run_corpora.sh" "$SRC" "$CORP" >"$W/corpora.log" 2>&1; then
  echo "OK   $(grep -c '  pass  ' "$W/corpora.log") assertions"
else echo "FAILED"; rc=1; fi
printf '  %-30s' run_g6.sh
if "$SM/g6_binding/run_g6.sh" "$SRC" "$PROBE" "$CORP" >"$W/g6.log" 2>&1; then
  echo "OK   $(grep -c '  pass  ' "$W/g6.log") assertions"
else echo "FAILED"; rc=1; fi
printf '  %-30s' run_g7.sh
if "$SM/g7_cost/run_g7.sh" "$SRC" "$CORP" 3 >"$W/g7.log" 2>&1; then
  echo "OK   $(grep -c '  pass  ' "$W/g7.log") assertions"
else echo "FAILED"; rc=1; fi
echo
echo "  the substantive results a re-bank must preserve:"
python3 - "$G5/evidence/inlining_state.json" "$G5/evidence/subset.json" <<'PY' | sed 's/^/    /'
import json, sys
inl, sub = (json.load(open(p)) for p in sys.argv[1:3])
print(f"reader accounting  {inl['accounting']}")
print(f"subset verdict     {sub['verdict']}  admitted "
      f"{sub['predicted_patchable']}/{sub['declarations']}")
PY
echo
echo "############ 4. NEGATIVES, DRIVEN BY THE INVENTORY ############"
python3 "$G/lib/falsify_reproduction.py" "$SM" "$G/inventory.json" "$W/neg" \
    "$G/evidence/negative_outcomes.json"
NEG_RC=$?
echo "  exit=$NEG_RC"
echo
echo "############ 5. INVENTORY == TESTED == CAUGHT ############"
python3 "$G/lib/check_inventory.py" "$SM" "$G/inventory.json" \
    "$G/evidence/inventory_check.json" "$G/evidence/negative_outcomes.json"
INV_RC=$?
echo "  exit=$INV_RC"
echo
echo "############ 6. PRODUCT SURFACE, AFTER ############"
} > "$G/evidence/g8_reproduction.txt" 2>&1

for d in $PROD; do
  h=$(surfacehash "$d")
  if [ "$h" = "$(before_of "$d")" ]; then echo "  unchanged  $h  $d"
  else echo "  CHANGED    $h  $d"; rc=1; fi
done >> "$G/evidence/g8_reproduction.txt"

T="$G/evidence/g8_reproduction.txt"
want 'the probe corpus rebuilds from source' 0 "${PROBE_RC:-1}"
want 'the rebuilt canonical AOT is the banked one' 1 "$(grep -c '    IDENTICAL' "$T")"
want 'the G1 projection matches the banked copy' 1 \
     "$(grep -c 'G1 projection IDENTICAL' "$T")"
want 'every gate re-ran green on the rebuilt corpus' 0 \
     "$(grep -c '^  FAILED' "$T")"
want 'negatives all detected and restored' 0 "${NEG_RC:-1}"
want 'inventory == tested == caught' 0 "${INV_RC:-1}"
want 'the equality is literal over stable ids' True \
     "$(python3 -c "
import json
d=json.load(open('$G/evidence/inventory_check.json'))['equality']
print(d['declared_ids']==d.get('tested_ids')==d.get('caught_ids'))")"
want 'product surface unchanged' 0 "$(grep -c '^  CHANGED' "$T")"
# Brace-free: zsh expands a Python set literal on the command line.
want 'the product surface covers what #57 requires' True \
     "$(python3 "$G/lib/_check_surface.py" "$G/inventory.json")"
# Compared as data, not by grepping a formatted line whose spaces and commas
# the shell re-splits.
want 'the reader accounting is preserved' True \
     "$(python3 "$G/lib/_check_substantive.py" "$G5/evidence/inlining_state.json" "$G5/evidence/subset.json")"
want 'zero declarations remain admitted' 0 \
     "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['predicted_patchable'])" "$G5/evidence/subset.json")"

# G8's OWN outputs, asserted after the run rather than through the inventory:
# a checker cannot validate its own transcript while writing it.
for f in evidence/g8_reproduction.txt evidence/inventory_check.json \
         evidence/negative_outcomes.json; do
  want "g8 produced $f" True \
       "$([ -s "$G/$f" ] && echo True || echo False)"
done

VERDICT=REPRODUCTION_INCOMPLETE
[ "$rc" = 0 ] && [ -z "$STOP" ] && VERDICT=CLEAN_REPRODUCTION
{
  echo
  echo "ASSERTIONS (${#ASSERTIONS[@]} checked)"
  printf '%s\n' "${ASSERTIONS[@]}"
  echo
  [ -n "$STOP" ] && echo "STOP CONDITION: $STOP"
  echo "SM1_G8: $VERDICT"
} >> "$T"
printf '%s\n' "${ASSERTIONS[@]}"
[ -n "$STOP" ] && echo "STOP CONDITION: $STOP"
echo "SM1_G8: $VERDICT"
exit "$rc"
