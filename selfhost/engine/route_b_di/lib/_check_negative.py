#!/usr/bin/env python3
"""Every complete-and-consumed policy must be accounted for as NOT
release-bound.

The negative existential B0 claims is "no complete RELEASE-BOUND validation
source exists". Two SL1 probe fixtures do carry all four sections and are
referenced by universe members, so a raw count of complete-and-consumed is not
the claim -- and asserting that count is zero would have been false while the
claim stayed true. What must hold is that each such policy appears in the
source record and is there recorded as not release-bound, so none of them is
quietly ignored.

usage: _check_negative.py <b0_policies.json> <b0_result.json>
"""
import json
import sys

try:
    pol = json.load(open(sys.argv[1]))
    res = json.load(open(sys.argv[2]))
except Exception as ex:                                      # noqa: BLE001
    print(f'unreadable:{type(ex).__name__}')
    raise SystemExit(1)

complete_consumed = pol['negative_existential'][
    'committed_complete_and_consumed']
roles = res['source_roles']
unaccounted = []
for path in complete_consumed:
    key = f'committed_policy:{path}'
    r = roles.get(key)
    if r is None:
        unaccounted.append(f'{path}: absent from the source record')
    elif r.get('release_bound') is not False:
        unaccounted.append(f'{path}: not recorded as non-release-bound')
    elif r.get('role') == 'complete':
        unaccounted.append(f'{path}: holds the complete role')
print(not unaccounted if not unaccounted else f'False {unaccounted}')
raise SystemExit(0 if not unaccounted else 1)
