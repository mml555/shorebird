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
GATE_STATUS="${TMPDIR:-/tmp}/sm1_g8_gates.txt"; : > "$GATE_STATUS"
gate() { # gate <name> <exit-status>
  printf '%s %s\n' "$1" "$2" >> "$GATE_STATUS"
}
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
  "$G5/$s" "$SRC" "$PROBE" >"$W/${s%.sh}.log" 2>&1; st=$?
  gate "$s" "$st"
  if [ "$st" = 0 ]; then
    echo "OK   $(grep -c '  pass  ' "$W/${s%.sh}.log") assertions"
  else
    echo "FAILED ($st)"; grep -m3 '  FAIL  ' "$W/${s%.sh}.log" | sed 's/^/     /'; rc=1
  fi
done
printf '  %-30s' run_corpora.sh
"$G5/run_corpora.sh" "$SRC" "$CORP" >"$W/corpora.log" 2>&1; st=$?
gate run_corpora.sh "$st"
if [ "$st" = 0 ]; then
  echo "OK   $(grep -c '  pass  ' "$W/corpora.log") assertions"
else echo "FAILED ($st)"; grep -m3 '  FAIL  ' "$W/corpora.log" | sed 's/^/     /'; rc=1; fi
printf '  %-30s' run_g6.sh
"$SM/g6_binding/run_g6.sh" "$SRC" "$PROBE" "$CORP" >"$W/g6.log" 2>&1; st=$?
gate run_g6.sh "$st"
if [ "$st" = 0 ]; then
  echo "OK   $(grep -c '  pass  ' "$W/g6.log") assertions"
else echo "FAILED ($st)"; grep -m3 '  FAIL  ' "$W/g6.log" | sed 's/^/     /'; rc=1; fi
printf '  %-30s' run_g7.sh
"$SM/g7_cost/run_g7.sh" "$SRC" "$CORP" 3 >"$W/g7.log" 2>&1; st=$?
gate run_g7.sh "$st"
if [ "$st" = 0 ]; then
  echo "OK   $(grep -c '  pass  ' "$W/g7.log") assertions"
else echo "FAILED ($st)"; grep -m3 '  FAIL  ' "$W/g7.log" | sed 's/^/     /'; rc=1; fi
echo
echo "  recorded exit status per gate (the data the assertion reads):"
sed 's/^/    /' "$GATE_STATUS"
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
echo "############ 3b. DIGEST SNAPSHOT OF EVERY MANDATORY ARTIFACT ############"
cat <<'TXT'
  Taken AFTER the gates regenerate, because these transcripts carry
  generated-at timestamps -- a committed digest would fail on every legitimate
  rebuild. It is this run's provenance, and it is what makes a
  present-but-corrupted artifact detectable at all: before it existed, a byte
  flipped in most artifacts changed nothing the checker looked at, so a derived
  corruption arm had nothing to catch it.
TXT
echo
python3 "$G/lib/snapshot_digests.py" "$SM" "$G/inventory.json" \
    "$G/evidence/artifact_digests.json"
echo
echo "############ 4. NEGATIVES, DRIVEN BY THE INVENTORY ############"
python3 "$G/lib/falsify_reproduction.py" "$SM" "$G/inventory.json" "$W/neg" \
    "$G/evidence/negative_outcomes.json" "$G/evidence/artifact_digests.json"
NEG_RC=$?
echo "  exit=$NEG_RC"
echo
echo "############ 5. INVENTORY == TESTED == CAUGHT ############"
python3 "$G/lib/check_inventory.py" "$SM" "$G/inventory.json" \
    "$G/evidence/inventory_check.json" "$G/evidence/negative_outcomes.json" \
    "$G/evidence/artifact_digests.json"
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

# ---- 7. THE TOP-LEVEL RESULT, IN THE FOUR-PARTITION SHAPE ----------------
# Emitted last and appended, because it DERIVES from the finished transcript
# (the product-surface CHANGED lines are written just above) as well as from
# the structured evidence. #57 requires this shape rather than a pass count:
# "CLEAN_REPRODUCTION" is readable as "the patchability model is clean", and it
# is not -- G5 is REDUCE_SCOPE with zero admitted declarations.
echo >> "$G/evidence/g8_reproduction.txt"
python3 "$G/lib/emit_result.py" "$SM" "$G/inventory.json" \
    "$G/evidence/g8_result.json" \
    "$G/evidence/inventory_check.json" \
    "$G/evidence/negative_outcomes.json" \
    "$G/evidence/artifact_digests.json" \
    "$GATE_STATUS" \
    "$G/evidence/g8_reproduction.txt" \
    >> "$G/evidence/g8_reproduction.txt" 2>&1
RESULT_RC=$?

# ---- 8. THE REPORTING PATH, FALSIFIED IN REPORT-ONLY MODE ---------------
# The four partitions are this gate's public answer, so they need their own
# negatives: an emitter that rendered REPRODUCTION: PASS regardless of input
# would be the most expensive vacuous check in the programme -- it would
# certify the whole lane. Report-only, per the g6c_harness precedent: each arm
# mutates one structured input in a scratch COPY and asserts the named
# partition moves to the named value. No gate is re-run and nothing under
# evidence/ is touched, so an arm cannot corrupt the bank it reports on.
{
echo
python3 "$G/lib/falsify_result.py" "$SM" "$G" "$W/report_neg"
} >> "$G/evidence/g8_reproduction.txt" 2>&1
REPORTNEG_RC=$?

T="$G/evidence/g8_reproduction.txt"
want 'the probe corpus rebuilds from source' 0 "${PROBE_RC:-1}"
want 'the rebuilt canonical AOT is the banked one' 1 "$(grep -c '    IDENTICAL' "$T")"
want 'the G1 projection matches the banked copy' 1 \
     "$(grep -c 'G1 projection IDENTICAL' "$T")"
want 'every gate re-ran green on the rebuilt corpus' 0 \
     "$(awk '$2!=0' "$GATE_STATUS" | wc -l | tr -d ' ')"
want 'every expected gate reported a status' 7 \
     "$(wc -l < "$GATE_STATUS" | tr -d ' ')"
want 'negatives all detected and restored' 0 "${NEG_RC:-1}"
want 'every mandatory artifact is digest-checked' \
     "$(python3 -c "
import json,sys
d=json.load(open('$G/inventory.json'))
print(sum(len(g['artifacts']) for g in d['gates'].values()))")" \
     "$(python3 -c "
import json
print(json.load(open('$G/evidence/inventory_check.json')).get('artifacts_digest_checked',0))")"
want 'both a deleted and a corrupted arm exist per artifact' True \
     "$(python3 "$G/lib/_check_arm_pairs.py" "$G/inventory.json" "$G/evidence/negative_outcomes.json")"
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
PART=$(python3 -c "
import json
d=json.load(open('$G/evidence/g8_result.json'))['result']
print(' '.join(f'{k}={v}' for k,v in d.items()))" 2>/dev/null || echo unreadable)
want 'the emitted result carries all four partitions' \
     'REPRODUCTION FEASIBILITY_EVIDENCE KNOWN_FAIL_OPEN_FINDINGS PRODUCTION_PREREQUISITES' \
     "$(python3 -c "
import json
try: print(' '.join(json.load(open('$G/evidence/g8_result.json'))['result']))
except Exception: print('unreadable')" )"
# Checked against the emitted JSON, not by counting a rendered pattern: the
# KNOWN_FAIL_OPEN_FINDINGS section header carries a count suffix and matched
# the same regex as the summary line, so the count was 5 for 4 partitions.
want 'the four partitions are rendered, with the values the JSON holds' True \
     "$(python3 "$G/lib/_check_partitions.py" "$G/evidence/g8_result.json" "$T")"
want 'REPRODUCTION derives to PASS' PASS \
     "$(python3 -c "
import json
try: print(json.load(open('$G/evidence/g8_result.json'))['result']['REPRODUCTION'])
except Exception: print('unreadable')" )"
want 'known FAIL_OPEN findings reproduce AS FINDINGS' REPRODUCED \
     "$(python3 -c "
import json
try: print(json.load(open('$G/evidence/g8_result.json'))['result']['KNOWN_FAIL_OPEN_FINDINGS'])
except Exception: print('unreadable')" )"
# NOT asserted as RESOLVED. Three prerequisites are genuinely unresolved, and a
# gate that demanded RESOLVED here would be demanding the evidence say
# something it does not.
want 'PRODUCTION_PREREQUISITES is derived, not defaulted' UNRESOLVED \
     "$(python3 -c "
import json
try: print(json.load(open('$G/evidence/g8_result.json'))['result']['PRODUCTION_PREREQUISITES'])
except Exception: print('unreadable')" )"
want 'every prerequisite binding resolved against real evidence' 0 \
     "$(python3 -c "
import json
try: print(len(json.load(open('$G/evidence/g8_result.json'))['production_prerequisites']['evidence_missing']))
except Exception: print(99)" )"
want 'the emitter exited clean' 0 "${RESULT_RC:-1}"
want 'the reporting path is itself falsified' 0 "${REPORTNEG_RC:-1}"
want 'every reporting partition discriminates' 1 \
     "$(grep -c 'SM1_G8_REPORT_FALSIFICATION: EVERY_PARTITION_DISCRIMINATES' "$T")"
# Asserted as DATA from the suite's own accounting line, so a suite that
# silently shrank cannot pass by having fewer arms to fail.
want 'the reporting suite did not shrink' True \
     "$(python3 -c "
import re,sys
m = re.search(r'arms=(\d+) failed=(\d+) control_survivors=(\d+)',
              open('$T').read())
print(bool(m) and int(m.group(1)) >= 30 and m.group(2) == '0'
      and m.group(3) == '0')" )"

for f in evidence/g8_reproduction.txt evidence/inventory_check.json \
         evidence/negative_outcomes.json evidence/g8_result.json; do
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
