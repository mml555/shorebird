#!/usr/bin/env bash
# cspell:words cspelltest delibrate mispelt
#
# cspell_exclusion_control.sh -- the paired control for a proposed cspell
# exclusion, run through the EXACT command being promoted.
#
# WHAT AN EXCLUSION CONTROL HAS TO SHOW, and why a falling count is not it.
# ignorePaths is a COVERAGE decision: once a path class is excluded, every future
# misspelling inside it is invisible by design and nothing will ever report that
# the boundary was drawn too wide. So the control tests the BOUNDARY, in both
# directions at once:
#
#   INSIDE  the excluded class -- a deliberate typo must DISAPPEAR;
#   BESIDE  it, in authored content that must stay watched -- a deliberate typo
#           must STILL BE FOUND, and must make the promoted command exit nonzero.
#
# One direction alone proves nothing. A rule that hides everything also hides the
# finding you wanted, and a rule that hides nothing was not applied.
#
# THE INSTRUMENT CONTROL COMES FIRST. Before the exclusion exists, BOTH specimens
# must be found. Otherwise a specimen that was never detectable would "disappear"
# for a reason having nothing to do with the exclusion -- the vacuous-check shape
# this repo has named more times than any other.
#
# THE COMMAND SHAPE IS THE OBJECT UNDER TEST, per PARITY.md §17's guard rule: a
# correct checker invoked behind a pipe is an inert guard. This runs the promoted
# invocation and keeps its exit status out of any pipeline.
#
#   cspell_exclusion_control.sh --phase before   # no exclusions yet: expect ALL FOUND
#   cspell_exclusion_control.sh --phase after    # exclusions applied: expect the split
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

# specimen path : must-vanish? : label
#   The excluded specimens are TEMPORARY files matching the proposed globs, so no
#   real evidence file is edited to run this.
SPECIMENS=(
  "selfhost/evidence/releases/_cspelltest/obfuscation_map.json:hide:obfuscation-map glob"
  "selfhost/evidence/releases/_cspelltest/NOTES.md:keep:authored file beside it"
  "selfhost/engine/route_b/instrumentation/_cspelltest.snapshot:hide:instrumentation snapshot"
  "selfhost/engine/route_b/instrumentation/_cspelltest_notes.md:keep:authored file beside it"
  "selfhost/evidence/_cspelltest/probe.routeb.trace:hide:device trace"
  "selfhost/evidence/_cspelltest/verdict.txt:keep:authored verdict beside it"
)

cleanup() {
  rm -rf "$REPO/selfhost/evidence/releases/_cspelltest" \
         "$REPO/selfhost/evidence/_cspelltest" \
         "$REPO/selfhost/engine/route_b/instrumentation/_cspelltest.snapshot" \
         "$REPO/selfhost/engine/route_b/instrumentation/_cspelltest_notes.md"
}
trap cleanup EXIT
cleanup

mkdir -p selfhost/evidence/releases/_cspelltest selfhost/evidence/_cspelltest
for entry in "${SPECIMENS[@]}"; do
  p=${entry%%:*}
  mkdir -p "$(dirname "$p")"
  printf 'this line contains a delibrate mispelt word\n' > "$p"
done

# THE PROMOTED COMMAND, verbatim, with its status kept out of a pipeline.
OUT=$(mktemp); RC=0
npx cspell --no-progress --no-summary selfhost packages/code_push_server/lib > "$OUT" 2>&1 || RC=$?

pass=0; fail=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "  PASS  $1 -> $2"; pass=$((pass+1))
  else echo "  FAIL  $1 -> got [$2] want [$3]"; fail=$((fail+1)); fi
}

echo "== phase: $PHASE =="
for entry in "${SPECIMENS[@]}"; do
  p=${entry%%:*}; rest=${entry#*:}; kind=${rest%%:*}; label=${rest#*:}
  found=$(grep -cF -- "$p:" "$OUT" || true)
  seen=$([ "$found" -gt 0 ] && echo found || echo absent)
  if [ "$PHASE" = before ]; then
    # Instrument control: every specimen must be detectable before any exclusion.
    check "$label [$kind]" "$seen" "found"
  else
    [ "$kind" = hide ] && check "$label" "$seen" "absent" || check "$label" "$seen" "found"
  fi
done

# The adjacent findings must also make the promoted invocation itself fail.
check "promoted command exits nonzero" "$([ "$RC" -ne 0 ] && echo nonzero || echo zero)" "nonzero"

rm -f "$OUT"
echo
echo "CONTROL PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
