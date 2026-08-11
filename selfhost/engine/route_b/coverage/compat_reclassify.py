#!/usr/bin/env python3
"""compat_reclassify.py -- rederive every study row from its preserved `raw`.

The reason `compat_study.py` never overwrites the analyzer's output with the
study's interpretation: when the taxonomy is wrong -- and in the pilot it was --
the fix costs seconds instead of hours of kernel compiles.

Reads rows.jsonl, rewrites only the derived fields, leaves `raw` untouched.

  compat_reclassify.py rows.jsonl
"""
import json, sys
from compat_study import classify, REJECTION_CATEGORY


def derive(row):
    raw = row.get('raw')
    if not raw:
        return row
    blockers = []
    for rej in raw.get('rejections') or []:
        cat, pol = REJECTION_CATEGORY.get(rej.get('category'), ('other', 'unclassified'))
        blockers.append({'target': rej.get('target'), 'raw': rej.get('reason'),
                         'raw_category': rej.get('category'), 'category': cat, 'policy': pol})
    for target, low in (raw.get('lowering') or {}).items():
        for reason in low.get('unsupported') or []:
            cat, pol = classify(reason)
            blockers.append({'target': target, 'raw': reason,
                             'raw_category': 'lowering', 'category': cat, 'policy': pol})
    for target in raw.get('removed') or []:
        blockers.append({'target': target, 'raw': 'member removed by the change',
                         'raw_category': 'removed', 'category': 'removed-member',
                         'policy': 'architectural'})

    emit = set(raw.get('patchable') or []) | set(raw.get('conditional') or [])
    unlowerable = {t for t, low in (raw.get('lowering') or {}).items()
                   if t in emit and (low.get('unsupported') or [])}
    accepted = raw.get('verdict') == 'accept' and not unlowerable
    cats = sorted({b['category'] for b in blockers})

    row.update(
        verdict=raw.get('verdict'),
        verdict_accepts=raw.get('verdict') == 'accept',
        patch_accepted=accepted,
        unlowerable_emit_targets=sorted(unlowerable),
        targets={'changed': len(raw.get('changed') or []),
                 'added': len(raw.get('added') or []),
                 'removed': len(raw.get('removed') or []),
                 'representable': len(emit),
                 'unreachable': len(raw.get('unreachable') or []),
                 'unknown': len(raw.get('unknown') or [])},
        blockers=blockers,
        blocking_categories=cats,
        primary_blocker=(cats[0] if len(cats) == 1 else None),
        blocked_by_one=(not accepted and (len(emit) - len(unlowerable)) > 0),
    )
    return row


if __name__ == '__main__':
    path = sys.argv[1]
    rows = [derive(json.loads(l)) for l in open(path) if l.strip()]
    with open(path, 'w') as fh:
        for r in rows:
            fh.write(json.dumps(r) + '\n')
    print(f'reclassified {len(rows)} rows in place; `raw` untouched')
