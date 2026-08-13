#!/usr/bin/env bash
#
# classifier_regression.sh -- the classifier's compatibility contract, as a test.
#
# FIVE REAL preserved device traces with known semantics, not hand-built fixtures.
#
# This is a regression corpus for the REASONING, not just for the parser. Each entry
# is a hypothesis that was retired by measurement, and its trace is the exact record
# that retired it -- so a future classifier edit that would have accepted the wrong
# conclusion fails here instead of on a device three releases later.
# Two classifier regressions were already caught by running exactly these:
#
#   * adding caller_scan_status made a v2 caller-bearing record fall through to the
#     FIELD verdict and report 0, hiding the identity gap it existed to expose;
#   * the schema bump had to be enforced, or a v2 record would be read as v3
#     evidence.
#
# Neither showed up in the code. Both showed up here. So these stay required inputs
# for any future classifier edit.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
EV="$(cd "$HERE/../../.." >/dev/null 2>&1 && pwd)/evidence/releases"
C="$HERE/classify_routeb_trace.py"

pass=0; fail=0
expect() { # <release> <expected-exit> <why>
  local r=$1 want=$2 why=$3 got
  python3 "$C" "$EV/$r/patch1.routeb.trace" >/dev/null 2>&1 && got=0 || got=$?
  if [ "$got" = "$want" ]; then
    echo "  PASS  release $r -> exit $got   ($why)"; pass=$((pass+1))
  else
    echo "  FAIL  release $r -> exit $got, want $want   ($why)"; fail=$((fail+1))
  fi
}

echo "classifier: $(git -C "$EV" log -1 --format=%h -- "$C" 2>/dev/null || echo unknown)"
expect 26 2 "v1 record: uep_ meant Code accessors, not comparable with v3"
expect 27 0 "v2, no caller: the FIELD question is still decidable"
expect 28 3 "v2 with a caller but no scan state: identity not measurable"
expect 29 3 "v3, NULL_POOL: AOT has one global pool, so no per-Code pool to scan"
expect 30 0 "v4, exact entry read: pool entry IS the patched Function"

echo
echo "classifier_regression: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
