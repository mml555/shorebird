#!/usr/bin/env bash
# MAOT-0 (#63) -- the universal Dart patchability contract, gated.
#
# Produces evidence/maot0.json (the record), evidence/maot0_falsification.json
# (the arms) and evidence/maot0.txt (this log). Exits non-zero on any blocking
# finding or any failed arm.
#
# The gate runs with NO Dart tree and NO external SSD: the construct universes
# are frozen into universe/. When a Dart tree IS reachable it is re-derived
# and compared byte for byte, because a freeze nobody re-derives is a claim
# about bytes that were never checked again.
#
#   usage: run_maot0.sh [--accept-lock]
#   env:   DART_TREE=<path to a dart checkout>   (optional; re-verifies)
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
EVID="$HERE/evidence"; mkdir -p "$EVID"
RAW="$EVID/maot0.json"
ARMS="$EVID/maot0_falsification.json"
LOG_FILE="$EVID/maot0.txt"
DART_TREE="${DART_TREE:-/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart}"
ACCEPT=""
[[ "${1:-}" == "--accept-lock" ]] && ACCEPT="--accept-lock"

rm -f "$LOG_FILE"

{
echo "MAOT-0 (#63) -- the universal Dart patchability contract and matrix"
echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by run_maot0.sh"
echo "repo $REPO at $(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
echo
echo "############ 1. WHAT THIS ISSUE OWNS, AND WHAT IT DOES NOT ############"
cat <<'TXT'
  #63 is a specification and gating issue. It defines what counts as
  supported, what needs an explicit developer migration, and what is outside
  the fixed-native-binary promise. It implements no CFE, compiler, VM, Route
  B, CLI, patch-format, migration or Flutter change -- and the commit is
  checked against that boundary rather than asserted to respect it.

  Every implementation axis in the matrix is UNMODELED. That is the correct
  state: nothing has been built, so nothing is claimed. What is delivered is
  the enumeration, the four-axis separation, the boundary, and a gate that
  refuses a 100% claim.
TXT
echo
echo "############ 2. THE CONSTRUCT UNIVERSES ARE NOT AUTHORED HERE ############"
cat <<'TXT'
  A coverage check whose required-row list is the matrix itself cannot fail.
  So the required list is derived from the compiler and runtime this program
  intends to fork:

    U1  every node class and node-kind enum value in package:kernel's AST
    U2  every heap class in the Dart VM's object.h that reaches Object

  Both are frozen with the Dart tree's full SHA and per-file digests. The
  gate reads the freeze, so it runs off this machine; when a tree is present
  the freeze is re-derived and compared.
TXT
echo
} > "$LOG_FILE" 2>&1

# ---- universe re-derivation, when a tree is reachable ---------------------
REVERIFY=absent
REVERIFY_DETAIL="no Dart tree at $DART_TREE"
if [[ -d "$DART_TREE/pkg/kernel/lib/src/ast" ]]; then
  TMP_UNIVERSE=$(mktemp -d)
  if python3 "$HERE/lib/extract_universe.py" "$DART_TREE" "$TMP_UNIVERSE" \
       >"$TMP_UNIVERSE/extract.log" 2>&1; then
    if diff -q "$TMP_UNIVERSE/kernel_declarations.json" \
         "$HERE/universe/kernel_declarations.json" >/dev/null 2>&1 && \
       diff -q "$TMP_UNIVERSE/vm_runtime_state.json" \
         "$HERE/universe/vm_runtime_state.json" >/dev/null 2>&1; then
      REVERIFY=identical
      REVERIFY_DETAIL="re-derived from $DART_TREE, byte-identical to the freeze"
    else
      REVERIFY=DIFFERS
      REVERIFY_DETAIL="re-derivation DIFFERS from the freeze -- the frozen universes no longer describe this tree"
    fi
  else
    REVERIFY=extract_failed
    REVERIFY_DETAIL="$(tail -3 "$TMP_UNIVERSE/extract.log" | tr '\n' ' ')"
  fi
  rm -rf "$TMP_UNIVERSE"
fi

{
echo "  re-derivation: $REVERIFY"
echo "  $REVERIFY_DETAIL"
echo
python3 -c "
import json,sys
for n in ('kernel_declarations.json','vm_runtime_state.json'):
    d=json.load(open('$HERE/universe/'+n))
    p=d['provenance']
    print(f'  {n}')
    print(f'    entries {d[\"total\"]}  dart tree {p[\"dart_tree_head\"]}')
    print(f'    dirty under extracted paths: {p[\"extracted_paths_dirty\"]}')
    for t,c in sorted(d['tier_counts'].items()): print(f'      {t:20s} {c}')
"
echo
echo "############ 3. THE GATE ############"
} >> "$LOG_FILE" 2>&1

python3 "$HERE/lib/gate.py" "$HERE" "$REPO" "$RAW" $ACCEPT >>"$LOG_FILE" 2>&1
GATE_RC=$?
if [[ -n "$ACCEPT" ]]; then
  python3 "$HERE/lib/gate.py" "$HERE" "$REPO" "$RAW" >>"$LOG_FILE" 2>&1
  GATE_RC=$?
fi

{
python3 -c "
import json
d=json.load(open('$RAW'))
a=d['aggregate']
print(f'  rows              {d[\"matrix_identity\"][\"row_count\"]}')
print(f'  in scope          {len(d[\"scope\"][\"in_scope_rows\"])}')
print(f'  universe entries  {d[\"coverage\"][\"universe_total\"]}')
print(f'  covered by row    {d[\"coverage\"][\"covered_by_row\"]}')
print(f'  by exclusion      {d[\"coverage\"][\"covered_by_exclusion\"]}')
print(f'  uncovered         {len(d[\"coverage\"][\"uncovered\"])}')
print(f'  lock              {d[\"lock\"][\"status\"]}')
print(f'  blocking findings {sum(1 for f in d[\"findings\"] if f[\"severity\"]==\"blocking\")}')
print()
print(f'  row states        {a[\"row_state_counts\"]}')
print(f'  VERDICT           universal_dart_patchability = {a[\"universal_dart_patchability\"]}')
print(f'  rows not proven   {len(a[\"rows_not_proven\"])}')
print()
print('  ' + a['verdict_rule'])
"
echo
echo "############ 4. THE FOUR SEMANTICS, KEPT APART ############"
python3 -c "
import json
d=json.load(open('$RAW'))
for axis,info in d['axis_states'].items():
    print(f'  {axis}')
    print(f'    {info[\"meaning\"]}')
    print(f'    {info[\"counts\"]}')
"
echo
echo "############ 5. THE FIXED-NATIVE-BINARY BOUNDARY ############"
python3 -c "
import json
d=json.load(open('$RAW'))
for b in d['scope']['boundaries']:
    print(f'  {b[\"id\"]}  in_scope={b[\"in_scope\"]}  {b[\"title\"]}')
"
echo
echo "############ 6. THE GATE, FALSIFIED IN BOTH DIRECTIONS ############"
} >> "$LOG_FILE" 2>&1

python3 "$HERE/lib/falsify_maot0.py" "$HERE/matrix.json" "$HERE/universe" \
    "$REPO" "$ARMS" >>"$LOG_FILE" 2>&1
ARMS_RC=$?

{
echo
echo "############ 7. THE PROSE IS TIED TO THE RECORD ############"
cat <<'TXT'
  CONTRACT.md quotes counts and identities. Every one of them is derived from
  the record and required to appear verbatim, because a contract whose stated
  coverage no longer matches its actual coverage is worse than one that states
  nothing -- a reader trusts the sentence, not the JSON.
TXT
echo
} >> "$LOG_FILE"
python3 "$HERE/lib/check_contract_doc.py" "$HERE" "$RAW" "$ARMS" \
    "$EVID/maot0_contract_doc.json" >>"$LOG_FILE" 2>&1
DOC_RC=$?

echo >> "$LOG_FILE"
echo "############ 8. ASSERTIONS ############" >> "$LOG_FILE"

rc=0
A=()
want() {
  if [[ "$2" == "$3" ]]; then A+=("  pass  $1")
  else A+=("  FAIL  $1 -- got '$3', expected '$2'"); rc=1; fi
}
j() { python3 -c "
import json,sys
try: print(eval(sys.argv[1], {'d': json.load(open('$RAW'))}))
except Exception as e: print('unreadable')" "$1"; }
k() { python3 -c "
import json,sys
try: print(eval(sys.argv[1], {'d': json.load(open('$ARMS'))}))
except Exception as e: print('unreadable')" "$1"; }

want 'the gate ran' 0 "${GATE_RC:-1}"
want 'the record was written' 0 "$([[ -s "$RAW" ]] && echo 0 || echo 1)"
want 'no blocking finding stands' 0 \
     "$(j "sum(1 for f in d['findings'] if f['severity']=='blocking')")"

# --- the matrix is complete against a universe it did not author
want 'every universe entry is covered, blanketed or excluded' 0 \
     "$(j "len(d['coverage']['uncovered'])")"
want 'the universes were extracted from a full-SHA tree' True \
     "$(j "all(len(v['dart_tree_head'] or '')==40 for v in d['universe_identity'].values())")"
want 'the frozen universes are digested' True \
     "$(j "all(v['frozen_file_sha256'] and v['source_digests'] for v in d['universe_identity'].values())")"
want 'the universe re-derives byte-identically from the tree' identical "$REVERIFY"
want 'coverage is not mostly blanket: the declaration space is named row by row' True \
     "$(python3 -c "
import json
d=json.load(open('$HERE/universe/kernel_declarations.json'))
m=json.load(open('$HERE/matrix.json'))
named=set()
for r in m['rows']: named.update(r.get('covers') or [])
decl=[e['id'] for e in d['entries'] if e['tier'] in ('declaration','type','constant','identity')]
print(all(i in named for i in decl))")"

# --- the four semantics are separate FIELDS, not one status
want 'all four axes are reported separately' 4 "$(j "len(d['axis_states'])")"
want 'code representability is its own axis' True \
     "$(j "'code_representability' in d['axis_states']")"
want 'live state compatibility is its own axis' True \
     "$(j "'live_state_compatibility' in d['axis_states']")"
want 'semantic migration is its own axis' True \
     "$(j "'semantic_migration' in d['axis_states']")"
# An ambiguous state transformation must be classified as needing a developer
# migration, NOT as unsupported Dart. #63 calls this out by name.
want 'ambiguous transformations are migration rows, not unsupported code' True \
     "$(python3 -c "
import json
m=json.load(open('$HERE/matrix.json'))
rows={r['id']:r for r in m['rows']}
print(all(rows[i]['migration']=='developer_migration_required' for i in ('TS-03','TS-05','TS-10','RS-03')))")"

# --- the boundary is machine-readable
want 'the fixed-native-binary boundary is declared' 7 \
     "$(j "len(d['scope']['boundaries'])")"
want 'every declared boundary is out of scope' True \
     "$(j "all(b['in_scope'] is False for b in d['scope']['boundaries'])")"
want 'every exclusion class carries a rationale' True \
     "$(j "all(x.get('rationale') for x in d['scope']['exclusion_classes'])")"

# --- the aggregate cannot claim 100% here, and the rule is a conjunction
want 'the aggregate refuses' NOT_PROVEN \
     "$(j "d['aggregate']['universal_dart_patchability']")"
want 'the verdict rule is a conjunction, not a threshold' True \
     "$(j "'every in-scope row' in d['aggregate']['verdict_rule'] and 'threshold' not in d['aggregate']['verdict_rule']")"
want 'counts are labelled diagnostic' True \
     "$(j "'DIAGNOSTIC' in d['aggregate']['diagnostic_only']")"
want 'no row is PROVEN at MAOT-0' 0 \
     "$(j "d['aggregate']['row_state_counts']['PROVEN']")"

# --- every computed value feeds a decision
want 'every computed value names its consumer' 0 \
     "$(j "len(d['consumers']['unconsumed_or_undeclared'])")"

# --- the lock exists and is clean
want 'the lock is present and clean' clean "$(j "d['lock']['status']")"
want 'the lock covers every row' True \
     "$(j "d['lock']['locked_rows'] == d['matrix_identity']['row_count']")"

# --- the arms, in BOTH directions
want 'every falsification arm passes' 0 "${ARMS_RC:-1}"
want 'the arms include a positive control on the real matrix' pass \
     "$(k "[a['result'] for a in d['arms'] if a['id']=='P0'][0]")"
want 'the arms prove the aggregate CAN reach PROVEN' PROVEN \
     "$(k "[a['observed_aggregate'] for a in d['arms'] if a['id']=='P1'][0]")"
want 'a 99%-proven matrix still refuses' NOT_PROVEN \
     "$(k "[a['observed_aggregate'] for a in d['arms'] if a['id']=='N02'][0]")"
want 'a deleted row cannot buy a 100% claim' NOT_PROVEN \
     "$(k "[a['observed_aggregate'] for a in d['arms'] if a['id']=='N03'][0]")"
want 'a promotion with a regenerated lock is still refused' pass \
     "$(k "[a['result'] for a in d['arms'] if a['id']=='N09'][0]")"

# --- the human-readable half cannot drift from the machine-readable one
want 'every figure CONTRACT.md quotes is derived and present' 0 "${DOC_RC:-1}"
want 'the doc check derives its claims rather than reading them' True \
     "$(python3 -c "
import json
try:
    d=json.load(open('$EVID/maot0_contract_doc.json'))
    print(len(d['derived_claims'])>=12 and d['result']=='pass')
except Exception: print(False)")"

# --- the stop boundary: this issue implements nothing.
# `status --porcelain`, not `diff HEAD`: an UNTRACKED new file under packages/
# would be invisible to a diff, and adding a file is exactly how scope leaks.
want 'no implementation subsystem is modified in the working tree' 0 \
     "$(git -C "$REPO" status --porcelain -- packages bin scripts \
        selfhost/engine/route_b selfhost/engine/route_b_di \
        selfhost/engine/dart-fork selfhost/engine/semantic_map \
        2>/dev/null | wc -l | tr -d ' ')"

{
  printf '%s\n' "${A[@]}"
  echo
  echo "ASSERTIONS (${#A[@]} checked: $(printf '%s\n' "${A[@]}" | grep -c '^  pass  ') pass, $(printf '%s\n' "${A[@]}" | grep -c '^  FAIL  ') fail)"
  echo
  echo "MAOT0: $([[ "$rc" == 0 ]] && echo "CONTRACT_ESTABLISHED / universal_dart_patchability=$(j "d['aggregate']['universal_dart_patchability']")" || echo GATE_FAILED)"
} >> "$LOG_FILE"

cat "$LOG_FILE"
echo "record: $RAW"
echo "arms:   $ARMS"
exit "$rc"
