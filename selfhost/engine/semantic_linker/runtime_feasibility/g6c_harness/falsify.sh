#!/usr/bin/env bash
# cspell:words semantic linker falsifiability
# falsify.sh -- SEMANTIC-LINKER-1 / G6C. Prove the harness FAILS when mandatory
# evidence is missing or mutated.
#
# WHY THIS IS PERMANENT AND NOT A ONE-OFF. G6C found a harness that printed
#
#     structured: .../negatives.json
#
# while that file did not exist -- a direct violation of this lane's evidence
# model, and the exact defect that makes every other check worthless. A harness
# that cannot be shown to fail is not evidence that anything passed, so the
# refusal is itself regression-tested from here on.
#
# Each case mutates ONE piece of mandatory evidence, runs the reporting path,
# and requires a nonzero exit. The original file is restored afterwards; the
# script refuses to run if it cannot restore, rather than leaving the evidence
# set damaged.
#
#   falsify.sh
#
# Exit: 0 every mutation was caught · 1 some mutation was NOT caught
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
RF="$(cd -- "$HERE/.." >/dev/null 2>&1 && pwd)"
EVID="$HERE/evidence"; mkdir -p "$EVID"
LOG="$EVID/falsify.txt"
BK=$(mktemp -d); trap 'rm -rf "$BK"' EXIT
PASS=0; FAIL=0

# Mandatory evidence, one line per case: <label>|<path>|<mutation>
CASES=(
  "structured_negatives|$RF/g6a_negatives/evidence/negatives.json|delete"
  "structured_negatives_corrupt|$RF/g6a_negatives/evidence/negatives.json|corrupt"
  "g2_trace|$RF/g2_execution/evidence/g2_g3_on.txt|delete"
  "g3_trace|$RF/g3_types_gc/evidence/g3_g3_on.txt|delete"
  "g4_disassembly|$RF/g4_optimizer/evidence/g4_solo_fenced.txt|delete"
  "g1_probe_trace|$RF/g1_substrate/evidence/probe_g3_on.txt|delete"
  "freeze_manifest|$RF/g0_freeze/freeze_manifest.json|corrupt"
  "banked_patch|$RF/g0_freeze/banked_source/dart/9999-worktree-uncommitted.patch|corrupt"
)

say() { printf '%s\n' "$*" | tee -a "$LOG"; }
: > "$LOG"
say "SL1-G6C falsifiability -- mandatory evidence must not be optional"
say "date : $(date -u +%FT%TZ)"
say ""

for c in "${CASES[@]}"; do
  IFS='|' read -r label path mut <<<"$c"
  if [[ ! -f "$path" ]]; then say "  SKIP-ABSENT $label ($path does not exist; nothing to falsify)"; FAIL=$((FAIL+1)); continue; fi
  cp "$path" "$BK/$(basename "$path").$label" || { say "  ABORT cannot back up $path"; exit 1; }
  case "$mut" in
    delete)  rm -f "$path" ;;
    corrupt) printf 'THIS IS NOT VALID CONTENT\n' > "$path" ;;
  esac

  # The reporting path is what consumes evidence, so that is what must refuse.
  if bash "$HERE/reproduce.sh" --mode report-only >>"$LOG" 2>&1; then
    say "  NOT CAUGHT  $label ($mut) — the harness reported success with mandatory evidence $mut"
    FAIL=$((FAIL+1))
  else
    say "  caught      $label ($mut)"
    PASS=$((PASS+1))
  fi
  cp "$BK/$(basename "$path").$label" "$path" || { say "  ABORT cannot restore $path"; exit 1; }
done

# The evidence set must be exactly as it was before this script ran.
say ""
if bash "$HERE/reproduce.sh" --mode report-only >>"$LOG" 2>&1; then
  say "restored: the harness reports normally again"
else
  say "RESTORE FAILED: the evidence set is not as it was found"
  FAIL=$((FAIL+1))
fi

say ""
say "SUMMARY caught=$PASS not-caught=$FAIL"
[[ "$FAIL" -eq 0 ]] && say "FALSIFIABILITY PASS — every mandatory-evidence mutation is refused" \
                    || say "FALSIFIABILITY FAIL — $FAIL mutation(s) were not refused"
exit $(( FAIL > 0 ))
