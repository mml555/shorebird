#!/usr/bin/env python3
"""Prove the four partitions are RENDERED, by checking them against the JSON.

The first version of this check counted transcript lines matching
`^  (REPRODUCTION|FEASIBILITY_EVIDENCE|KNOWN_FAIL_OPEN_FINDINGS|
PRODUCTION_PREREQUISITES) ` and wanted 4. It got 5: the
KNOWN_FAIL_OPEN_FINDINGS *section header* carries a "3/3 reproduced" suffix, so
it matched the same pattern as the summary line. Grepping a rendered line for a
structural fact keeps producing this -- the shape of the prose is not the fact.

So the fact is checked against the DATA: for every partition the emitter wrote
to g8_result.json, a summary line must exist in the transcript whose stripped
content is exactly "<PARTITION> <VALUE>", and the partition must also open its
own detail section. Both directions matter -- a partition present in the JSON
but missing from the transcript is unreported, and a value rendered that
disagrees with the JSON is worse than either.

usage: _check_partitions.py <g8_result.json> <transcript>
"""
import json
import pathlib
import sys

WANT = ['REPRODUCTION', 'FEASIBILITY_EVIDENCE', 'KNOWN_FAIL_OPEN_FINDINGS',
        'PRODUCTION_PREREQUISITES']

try:
    result = json.load(open(sys.argv[1]))['result']
    lines = pathlib.Path(sys.argv[2]).read_text(errors='replace').splitlines()
except Exception as ex:                                      # noqa: BLE001
    print(f'unreadable: {type(ex).__name__}')
    raise SystemExit(1)

if list(result) != WANT:
    print(f'wrong partitions: {list(result)}')
    raise SystemExit(1)

stripped = [' '.join(l.split()) for l in lines]
problems = []
for k, v in result.items():
    if f'{k} {v}' not in stripped:
        problems.append(f'{k}: no summary line rendering value {v!r}')
    # The detail section opens with the partition name alone, or with the name
    # plus a count. It must be a DIFFERENT line from the summary: the first
    # version accepted `startswith(k + " ")`, which the summary line itself
    # satisfies -- so deleting a whole detail section still passed. Caught by
    # running the negative, not by reading the code.
    summary = f'{k} {v}'
    if not any(s != summary and (s == k or s.startswith(k + ' '))
               for s in stripped):
        problems.append(f'{k}: no detail section distinct from the summary')

print('True' if not problems else f'False {problems}')
raise SystemExit(0 if not problems else 1)
