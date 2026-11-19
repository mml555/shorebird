#!/usr/bin/env python3
"""aggregate.py <probes.tsv> <table.tsv> <keys.tsv> <harness.keys> <results.tsv> <members.json>

Joins what each probe did with the member it tested.

A probe RESOLVES when the member ran (or failed with an error other than a
NoSuchMethodError that names the member); THROWS is a NoSuchMethodError naming
the member; ABORTS and CRASHES stop the process. A NoSuchMethodError that does
not name the member is UNATTRIBUTED and counts as a failure.

A key is accepted only when EVERY probe of it, on every runtime class and
every form that maps to the key, resolved, and the harness's own code never
references the key (then a "resolves" could come from the harness, not from the
platform). A failure is real; a success is evidence for that release only.
"""
import sys, json, re
probes = [l.rstrip('\n').split('\t') for l in open(sys.argv[1])]
table = {}
for l in open(sys.argv[2]):
    f = l.rstrip('\n').split('\t'); table[f[0]] = (f[1], f[2] if len(f) > 2 else '')
keys = {}
for l in open(sys.argv[3]):
    f = l.rstrip('\n').split('\t'); keys[f[0]] = f[1].split(' ') if len(f) > 1 and f[1] else []
harness = set(l.strip() for l in open(sys.argv[4]) if l.strip())
rows = []; per_key = {}
for pid, typ, label, form, sel in probes:
    st, d = table.get(pid, ('NOT-RUN', ''))
    plain = re.sub(r'^(get:|set:|tearoff:)', '', sel)
    if st == 'THROWS' and plain not in d:
        st = 'UNATTRIBUTED'
    cand = keys.get(pid, [])
    if 'dynamic' in form:
        key = f'dynamic#{sel}' if f'dynamic#{sel}' in cand else None
        if sel.startswith('tearoff:'):
            key = f'dynamic#{sel}'  # a dynamic get of a method name
    else:
        key = next((k for k in cand if k.split('#', 2)[2] == sel), None)
    rows.append((pid, key or '?', typ, label, form, st, d[:140]))
    if key:
        e = per_key.setdefault(key, {'resolves': [], 'fails': [], 'harness': key in harness})
        (e['resolves'] if st == 'RESOLVES' else e['fails']).append(f'{label}:{form}:{st}')
with open(sys.argv[5], 'w') as o:
    o.write('probe\tkey\treceiver_type\truntime_class\tform\tresult\tdetail\n')
    for r in rows: o.write('\t'.join(r) + '\n')
members = {}
for k, e in sorted(per_key.items()):
    ok = not e['fails'] and not e['harness']
    members[k] = {'accepted': ok, 'harness_supplied': e['harness'], 'failing': e['fails'][:8],
                  'resolving_on': len(e['resolves'])}
json.dump(members, open(sys.argv[6], 'w'), indent=1, sort_keys=True)
from collections import Counter
print(Counter(r[5] for r in rows)); print('accepted keys', sum(m['accepted'] for m in members.values()), 'of', len(members))
