#!/usr/bin/env bash
# cspell:words delibrate hlclpqwxzq hldxg VVFRF UNRE Volemes cspelltest
# cspell:ignore Ünïcödé
#
# cspell_token_control.sh -- the paired control for a FILE-SCOPED, EXACT-TOKEN
# suppression (`overrides: [{filename, ignoreWords}]`).
#
# WHAT IS BEING CLAIMED, and therefore what must be tested. The claim is not
# "this token is not a word" -- it is "this token, IN THIS FILE, is quoted
# machine content, and suppressing it costs no coverage of the authored text
# around it". File scope is the boundary, so the control has to exercise the
# boundary in both directions inside the same file:
#
#   the suppressed token must DISAPPEAR;
#   a deliberate typo planted in authored text BESIDE it must STILL BE RED,
#   through the exact tree-wide command being promoted.
#
# INSTRUMENT FIRST. Phase `before` requires every token to be REPORTED with no
# suppression in place. A token that was never visible would "disappear" for
# reasons having nothing to do with the override.
#
# THE PLANTED TYPOS ARE APPENDED AND THEN REMOVED, and the script verifies the
# files come back byte-identical to HEAD. Four of these six files are evidence
# records; a control that leaves a mark on the record it was testing has
# damaged the thing it was protecting.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
cd "$REPO"

PHASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) PHASE="${2:?}"; shift 2 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$PHASE" == before || "$PHASE" == after ]] || { echo "ERROR: --phase before|after" >&2; exit 2; }

# file : one representative token that must vanish
TARGETS=(
  "selfhost/evidence/g15/gate2_verdict.txt:hlclpqwxzq"
  "selfhost/evidence/g15/gate5_armA_inconclusive.txt:hldxg"
  "selfhost/evidence/g41-define-from-file/DECLARES.md:VVFRF"
  "selfhost/evidence/releases/24/RECORDED:UNRE"
  "selfhost/plans/H4-gen-snapshot-obfuscation-map.md:Volemes"
  "selfhost/engine/route_b/probes/lowering_matrix.sh:Ünïcödé"
)
MARK="cspelltest-planted-delibrate-line"

# Restore by BYTE SNAPSHOT, not by parsing the plant back out. The first version
# stripped the marked line and left the blank line above it, so all six records
# came back one byte longer -- caught only because the control asserts
# byte-identity afterwards, which is the reason to assert it.
SNAP=$(mktemp -d)
snapshot() {
  local i=0
  for entry in "${TARGETS[@]}"; do
    cp "${entry%%:*}" "$SNAP/$i"; i=$((i+1))
  done
}
restore() {
  local i=0
  for entry in "${TARGETS[@]}"; do
    [[ -f "$SNAP/$i" ]] && cp "$SNAP/$i" "${entry%%:*}"
    i=$((i+1))
  done
}
snapshot
trap "restore; rm -rf '$SNAP'" EXIT

pass=0; fail=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "  PASS  $1 -> $2"; pass=$((pass+1))
  else echo "  FAIL  $1 -> got [$2] want [$3]"; fail=$((fail+1)); fi
}

echo "== phase: $PHASE =="

if [[ "$PHASE" == after ]]; then
  # Plant one deliberate typo in authored text in each file under test.
  for entry in "${TARGETS[@]}"; do
    f=${entry%%:*}
    printf '\n%s a delibrate typo beside the quoted token\n' "$MARK" >> "$f"
  done
fi

OUT=$(mktemp); RC=0
npx cspell --no-progress --no-summary selfhost packages/code_push_server/lib > "$OUT" 2>&1 || RC=$?

for entry in "${TARGETS[@]}"; do
  f=${entry%%:*}; tok=${entry#*:}
  tok_seen=$(grep -cF "$f:" "$OUT" | head -1 >/dev/null; grep -F "$f:" "$OUT" | grep -cF "Unknown word ($tok)" || true)
  if [[ "$PHASE" == before ]]; then
    check "$(basename "$f") — $tok reported" "$([ "$tok_seen" -gt 0 ] && echo yes || echo no)" "yes"
  else
    typo_seen=$(grep -F "$f:" "$OUT" | grep -c "Unknown word (delibrate)" || true)
    check "$(basename "$f") — $tok suppressed" "$([ "$tok_seen" -eq 0 ] && echo yes || echo no)" "yes"
    check "$(basename "$f") — planted typo still RED" "$([ "$typo_seen" -gt 0 ] && echo yes || echo no)" "yes"
  fi
done

if [[ "$PHASE" == after ]]; then
  check "tree-wide command exits nonzero with typos planted" \
    "$([ "$RC" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
fi
rm -f "$OUT"

restore
# The records must come back exactly as they were.
dirty=$(git status --porcelain -- "${TARGETS[@]%%:*}" | wc -l | tr -d ' ')
check "all six files byte-identical to HEAD after the control" "$dirty" "0"

echo
echo "TOKEN CONTROL PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
