#!/usr/bin/env python3
"""Does every mandatory artifact have BOTH a deleted and a corrupted arm?

#57 requires every mandatory item to refuse when missing OR corrupted. Deriving
one arm per artifact satisfied only the first half, so this asserts the pair
exists for each -- computed from the inventory, not from the arm list, so a
missing pair is a finding rather than an absence nobody notices.

usage: _check_arm_pairs.py <inventory.json> <negative_outcomes.json>
"""
import json
import pathlib
import sys

inv = json.load(open(sys.argv[1]))
tested = set(json.load(open(sys.argv[2]))['tested_ids'])
missing = []
for gate, spec in inv['gates'].items():
    for rel in spec['artifacts']:
        base = f"auto-{gate}-{pathlib.Path(rel).name}"
        for kind in ('deleted', 'corrupted'):
            if f'{base}-{kind}' not in tested:
                missing.append(f'{base}-{kind}')
print(not missing if not missing else f'missing arms: {missing[:4]}')
