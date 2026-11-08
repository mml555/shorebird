#!/usr/bin/env python3
"""Is G5's substantive result preserved after the probe re-bank?

#57's acceptance boundary: if the re-bank preserves or narrows the result, the
closed gates need not reopen. This compares the two facts that define it as
DATA, rather than grepping a formatted line.
"""
import json
import sys

EXPECTED_ACCOUNTING = {'total_g1_rows': 36, 'INLINED': 2, 'NOT_INLINED': 15,
                       'UNKNOWN': 14, 'NO_BODY': 5, 'accounted': 36}
inl = json.load(open(sys.argv[1]))
sub = json.load(open(sys.argv[2]))
print(inl['accounting'] == EXPECTED_ACCOUNTING
      and sub['predicted_patchable'] == 0
      and sub['verdict'] == 'SUBSET_HOLDS_VACUOUSLY')
