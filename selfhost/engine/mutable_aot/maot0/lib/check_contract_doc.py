#!/usr/bin/env python3
"""MAOT-0 (#63) -- keep CONTRACT.md's figures tied to the computed record.

CONTRACT.md quotes counts and identities. Prose drifts from data silently,
and a contract whose stated coverage no longer matches its actual coverage is
worse than one that states nothing -- a reader trusts the sentence, not the
JSON. So every figure the prose quotes is DERIVED here and required to appear
verbatim in the file.

This does not check the prose is correct English. It checks that no number in
it survived a change to the matrix it describes.

usage: check_contract_doc.py <maot0-dir> <gate-record.json> <arms.json> <out.json>
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import contract as C          # noqa: E402
import validate as V          # noqa: E402


def main(argv):
    if len(argv) != 5:
        print(__doc__)
        return 2
    maot_dir, record_path, arms_path, out_path = argv[1:5]

    with open(os.path.join(maot_dir, 'CONTRACT.md'), encoding='utf-8') as fh:
        doc = fh.read()
    with open(os.path.join(maot_dir, 'matrix.json'), encoding='utf-8') as fh:
        matrix = json.load(fh)
    with open(record_path, encoding='utf-8') as fh:
        record = json.load(fh)
    with open(arms_path, encoding='utf-8') as fh:
        arms = json.load(fh)

    universes, _ = V.load_universes(os.path.join(maot_dir, 'universe'))
    named = set()
    for row in matrix['rows']:
        named.update(row.get('covers') or [])
    excluded = {x['universe_id'] for x in matrix['universe_exclusions']}
    per_row = [i for i, e in universes.items()
               if C.TIER_COVERAGE[e['tier']] == 'per_row']

    kernel = record['universe_identity']['kernel_declarations.json']
    vm = record['universe_identity']['vm_runtime_state.json']
    n02 = next((a for a in arms['arms'] if a['id'] == 'N02'), {})

    claims = {
        'row count':
            str(record['matrix_identity']['row_count']),
        'rows proven':
            f'{record["aggregate"]["row_state_counts"]["PROVEN"]} of '
            f'{record["matrix_identity"]["row_count"]} rows',
        'aggregate verdict':
            record['aggregate']['universal_dart_patchability'],
        'kernel universe total': str(kernel['total']),
        'vm universe total': str(vm['total']),
        'universe total': str(record['coverage']['universe_total']),
        'dart tree sha': kernel['dart_tree_head'],
        'per-row entries': str(len(per_row)),
        'per-row named': str(sum(1 for i in per_row if i in named)),
        'per-row excluded': str(sum(1 for i in per_row if i in excluded)),
        'boundary count': str(len(matrix['boundaries'])),
        'arm count': str(arms['arms_total']),
        'n02 percentage': f'{n02.get("observed_percentage_diagnostic", "?")} %'
                          .replace(' %', ' %'),
    }
    # The N02 percentage is written in the prose as "99.04 %"; normalise the
    # spacing rather than requiring the doc to match a Python repr.
    pct = n02.get('observed_percentage_diagnostic')
    claims['n02 percentage'] = f'{pct:.2f}' if pct is not None else 'MISSING'

    missing = [f'{label} ({value!r})' for label, value in claims.items()
               if str(value) not in doc]

    result = {
        'schema': 'maot0.contract_doc/1',
        'derived_claims': claims,
        'missing_from_contract_md': missing,
        'rule': ('Every figure CONTRACT.md quotes is derived from the record '
                 'and required to appear verbatim. A matrix change that does '
                 'not reach the prose fails here.'),
        'result': 'pass' if not missing else 'FAIL',
    }
    with open(out_path, 'w', encoding='utf-8') as fh:
        json.dump(result, fh, indent=2)
        fh.write('\n')

    for label, value in claims.items():
        mark = 'pass' if str(value) in doc else 'FAIL'
        print(f'  {mark}  CONTRACT.md states the {label}: {value}')
    return 0 if not missing else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
