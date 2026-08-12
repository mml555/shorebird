#!/usr/bin/env python3
"""compat_reclassify.py -- rederive every study row from its preserved `raw`.

The reason `compat_study.py` never overwrites the analyzer's output with the
study's interpretation: when the taxonomy is wrong -- and around Phase 0 it was,
twice -- the fix costs seconds instead of hours of kernel compiles.

Rewrites only derived fields. `raw` is never touched. Rows with no `raw`
(compile-failed, identical-kernels, checkout-failed) keep their terminal state.

  compat_reclassify.py rows.jsonl
"""
import json, sys
from compat_taxonomy import blockers_for, outcomes_for


def derive(row):
    raw = row.get('raw')
    if not raw:
        return row
    blockers, _ = blockers_for(raw)
    row.update(outcomes_for(raw))
    cats = sorted({b['category'] for b in blockers})
    row.update(
        targets={'changed': len(raw.get('changed') or []),
                 'added': len(raw.get('added') or []),
                 'removed': len(raw.get('removed') or []),
                 'unreachable': len(raw.get('unreachable') or []),
                 'unknown': len(raw.get('unknown') or [])},
        blockers=blockers,
        blocking_categories=cats,
        blocking_policies=sorted({b['policy'] for b in blockers}),
        primary_blocker=(cats[0] if len(cats) == 1 else None),
        blocked_by_one=(not row['publishable']
                        and row['representable_and_lowerable'] > 0),
    )
    return row


if __name__ == '__main__':
    path = sys.argv[1]
    rows = [derive(json.loads(l)) for l in open(path) if l.strip()]
    with open(path, 'w') as fh:
        for r in rows:
            fh.write(json.dumps(r) + '\n')
    print(f'reclassified {len(rows)} rows in place; `raw` untouched')
