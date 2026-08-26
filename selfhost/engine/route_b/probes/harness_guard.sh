# shellcheck shell=bash
# cspell:words dartaotruntime
#
# harness_guard.sh -- shared guards against a probe reporting its OWN failure as
# a product verdict. Source it; it defines functions and runs nothing.
#
#   . "$(dirname "${BASH_SOURCE[0]}")/harness_guard.sh"
#
# WHY THIS IS GLOBAL RATHER THAN LOCAL TO ONE PROBE. On 2026-08-25 the P5
# differential matrix passed the release OUTPUT directory as the producer's
# project root. The bytecode compiler then failed with a bare `exit 254` and NO
# stderr, and two rows of the matrix reported REFUSED -- indistinguishable, in
# the log, from a semantic refusal. Two other rows had passed only because those
# two paths happened to be the same directory. A probe that cannot tell its own
# breakage from a product decision produces confident wrong answers, which is
# worse than producing none.
#
# The rule this encodes:
#
#   A compiler or tool failure with no diagnostic output is HARNESS_FAILURE,
#   never a refusal. A refusal has to come with something the product said.

# classify_tool_failure <exit-code> <output-file>
#
# Echoes one of:
#   OK                 the tool succeeded
#   PRODUCT_REFUSAL    it failed AND said something diagnosable
#   HARNESS_FAILURE    it failed silently -- suspect the probe, not the product
#
# "Said something" is deliberately broad: any Dart/Kernel diagnostic, an
# exception, a usage error, or a path error. Narrow patterns would classify a
# novel real failure as a harness bug, which fails in the direction of ignoring
# product evidence.
classify_tool_failure() {
  local rc=$1 out=$2
  if [ "$rc" -eq 0 ]; then echo OK; return 0; fi
  if [ ! -s "$out" ]; then echo HARNESS_FAILURE; return 0; fi
  if grep -qiE 'error|exception|warning|usage|cannot|not found|no such|refus' \
       "$out"; then
    echo PRODUCT_REFUSAL
  else
    echo HARNESS_FAILURE
  fi
}

# require_tool_ok <label> <exit-code> <output-file>
#
# For steps a probe treats as SETUP rather than as measurement. A silent failure
# here aborts loudly instead of flowing into the results, because a probe whose
# fixture never built cannot measure anything.
require_tool_ok() {
  local label=$1 rc=$2 out=$3
  [ "$rc" -eq 0 ] && return 0
  echo "HARNESS FAILURE in setup: $label (exit $rc)" >&2
  if [ -s "$out" ]; then sed -n '1,6p' "$out" >&2; else
    echo "  ...and it produced NO output, which is itself the finding" >&2
  fi
  exit 2
}
