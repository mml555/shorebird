#!/usr/bin/env bash
# SM1-G5 Phase C -- the predictor's refusal bank.
#
# Every safety-bearing refusal has one adversarial arm, and every arm has a
# control that removes THAT gate. Two properties are asserted, not printed:
#
#   * every reason in the predictor's vocabulary is armed. A declared refusal
#     nobody exercises is indistinguishable from a gate that cannot fire --
#     which is exactly how DEVIRTUALIZED_CALL_SITE sat unreachable until
#     Phase C removed it;
#   * no arm is satisfied by a predictor that refuses everything under one
#     generic code.
#
# usage: run_predictor_bank.sh <clone-src> <workdir>
set -uo pipefail
SRC="${1:?usage: run_predictor_bank.sh <clone-src> <workdir>}"
W="${2:?usage: run_predictor_bank.sh <clone-src> <workdir>}"
G="$(cd "$(dirname "$0")" && pwd)"
S="$SRC/out/host_release_arm64"
rc=0
ASSERTIONS=()
want() {
  if [ "$2" = "$3" ]; then ASSERTIONS+=("  pass  $1")
  else ASSERTIONS+=("  FAIL  $1 -- got '$3', expected '$2'"); rc=1; fi
}
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
rm -f "$W"/weak_*.dart

{
echo "SM1-G5 Phase C -- predictor refusal bank"
echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by run_predictor_bank.sh"
echo
echo "PROVENANCE"
echo "  $(sha "$G/lib/predict_patchable.dart")  lib/predict_patchable.dart"
echo "  $(sha "$G/lib/falsify_predictor.py")  lib/falsify_predictor.py"
echo "  $(sha "$G/lib/weaken_predictor.py")  lib/weaken_predictor.py"
echo
cat <<'TXT'
WHAT EACH ARM ASSERTS

  1. the real predictor runs on real input schemas;
  2. the arm's intended STABLE refusal code is present;
  3. predicted_patchable is false;
  4. the arm's own control -- the predictor with the gate for THAT code
     removed from the decision path -- fails the arm. So an arm proves the
     gate it names, not merely that something refused.

  Prediction consumes only RELEASE EVIDENCE. Route 2's reader output is read
  as evidence about the release artifact and is bound to it by AOT identity;
  the demonstrator's verdicts are never an input.

ROUTE 2 IS INTERPRETED CONSERVATIVELY

  INLINED     -> refuse
  UNKNOWN     -> refuse
  absent row  -> refuse (no missing row is safe, on the consuming side too)
  unvalidated -> refuse
  wrong AOT   -> refuse (a sibling build is not evidence about this artifact)
  NOT_INLINED -> clears ONLY the inlining refusal, and never implies patchable
TXT
echo
echo "======================= RUN: the shipped predictor ======================="
python3 "$G/lib/falsify_predictor.py" "$S/dart" "$W"
echo "exit=$?  (asserted: 0)"
echo
echo "============ CONTROL: every refusal collapsed to one code ==========="
cat <<'TXT'
A predictor that still refuses everything, but reports one undifferentiated
code, must satisfy NO reason-specific arm. Otherwise the bank would be proving
"something refused" rather than "this gate refused".
TXT
echo
python3 "$G/lib/weaken_predictor.py" "$G/lib/predict_patchable.dart" \
    "$W/weak_generic.dart" generic
SM1_PREDICTOR="$W/weak_generic.dart" python3 "$G/lib/falsify_predictor.py" \
    "$S/dart" "$W" --no-controls
echo "exit=$?  (asserted: non-zero, with every arm failed)"
} > "$G/evidence/predictor_falsification.txt" 2>&1

T="$G/evidence/predictor_falsification.txt"
python3 "$G/lib/falsify_predictor.py" "$S/dart" "$W" >/dev/null 2>&1
want 'every reason is armed and every gate is sensitive' 0 "$?"
want 'the bank records EVERY_REASON_ARMED_AND_SENSITIVE' 1 \
     "$(grep -c 'SM1_G5_PREDICTOR_FALSIFICATION: EVERY_REASON_ARMED_AND_SENSITIVE' "$T")"
# The FIRST summary line is the shipped run; the control run prints its own.
want 'no vocabulary reason is unarmed' unarmed=0 \
     "$(grep -m1 -o 'unarmed=[0-9]*' "$T")"
python3 "$G/lib/weaken_predictor.py" "$G/lib/predict_patchable.dart" \
    "$W/weak_generic.dart" generic >/dev/null 2>&1
SM1_PREDICTOR="$W/weak_generic.dart" python3 "$G/lib/falsify_predictor.py" \
    "$S/dart" "$W" --no-controls >/dev/null 2>&1
want 'a one-code predictor satisfies no arm' 1 "$?"
ARMS=$(grep -m1 -o 'arms=[0-9]*' "$T" | cut -d= -f2)
want 'the generic control failed every arm' "arms=$ARMS passed=0 failed=$ARMS" \
     "$(grep -o "arms=$ARMS passed=0 failed=$ARMS" "$T" | head -1)"

{
  echo
  echo "ASSERTIONS (${#ASSERTIONS[@]} checked)"
  printf '%s\n' "${ASSERTIONS[@]}"
  echo
  echo "SM1_G5_PREDICTOR_BANK: $([ "$rc" = 0 ] && echo COMPLETE || echo FAILED)"
} >> "$T"
printf '%s\n' "${ASSERTIONS[@]}"
echo "SM1_G5_PREDICTOR_BANK: $([ "$rc" = 0 ] && echo COMPLETE || echo FAILED)"
exit "$rc"
