#!/usr/bin/env python3
"""Assert each composite rung predicate IS the conjunction it claims to be.

These three facts were previously asserted by looking for names in a
predicate's own `from` prose. That check passes unchanged if the predicate is
rewritten and only the comment survives -- an outcome literal proving nothing
about the code that produced it. Comparing published VALUES makes the
assertion structural: if a rung stops being the conjunction it documents, this
fails.

  1. the analyzer rung carries model validity ITSELF, so an attribution
     against an invalid model falls through instead of selecting or resetting
  2. the map-design rung is armed by the DIRECT representability evidence
     alone -- not by the blocker count, and not suppressed by a non-empty
     admitted set
  3. REDUCE_SCOPE is all four of its conditions

usage: _check_predicates.py <final_verdict.json>
"""
import json
import sys

try:
    P = json.load(open(sys.argv[1]))['predicates']
except Exception as ex:                                      # noqa: BLE001
    print(f'unreadable: {type(ex).__name__}')
    raise SystemExit(1)


def v(name):
    return P[name]['value']


try:
    analyzer_ok = v('ANALYZER_DEFECT_UNDER_VALID_MODEL') == (
        v('ANALYZER_DEFECT_ATTRIBUTED_BY_EVIDENCE')
        and v('MODEL_ROWS_ALL_ESTABLISHED'))
    # Equality, not implication: the rung must be NEITHER weaker (armed by
    # something else) NOR stronger (suppressed by an unrelated fact) than the
    # direct evidence.
    mapdesign_ok = (v('DISTINCTION_NOT_REPRESENTABLE')
                    == v('REPRESENTABILITY_EVIDENCE_SAYS_NOT_REPRESENTABLE'))
    reduce_ok = v('DECIDABLE_EXCLUSION_YIELDS_NONEMPTY') == (
        v('NAMED_DECIDABLE_EXCLUSION_PRESENT')
        and v('REPRESENTABILITY_DEFECT_ABSENT')
        and v('ADMITTED_SET_IS_SOUND')
        and v('ADMITTED_SET_IS_PROPER_SUBSET'))
except KeyError as ex:
    print(f'missing predicate {ex}')
    raise SystemExit(1)

print(f'{analyzer_ok} {mapdesign_ok} {reduce_ok}')
raise SystemExit(0 if (analyzer_ok and mapdesign_ok and reduce_ok) else 1)
