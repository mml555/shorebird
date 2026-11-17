#!/usr/bin/env python3
# cspell:words cdir kdir
"""side_by_side.py <counter result dir> <kept result dir>

Joins the counter release's verdict per key (result/members.tsv) with the kept release's
(result_kept/members.tsv) and what the snapshot profile said about the key in the kept release
(kept_check_build3.keys.tsv for the final build, kept_check_build2.keys.tsv for the build before
`--sdk-members` was widened). A tear-off key is UNCALLED, not SAFE, when its call form is not SAFE (see compare.py). Writes <kept>/side_by_side.tsv and <kept>/side_by_side.md.
"""
import collections, csv, sys

cdir, kdir = sys.argv[1:3]


def load(path):
    return {r['key']: r for r in csv.DictReader(open(path), delimiter='\t')}


counter = load(f'{cdir}/members.tsv')
kept = load(f'{kdir}/members.tsv')
prof3 = load(f'{kdir}/kept_check_build3.keys.tsv')
prof2 = load(f'{kdir}/kept_check_build2.keys.tsv')

rows = []
for k in sorted(counter):
    c, d = counter[k], kept[k]
    if c['device_verdict'] == 'THROWS' and not k.startswith('dynamic#'):
        # a target: the build 2 profile says whether the call sites alone kept it
        by = 'call sites and --sdk-members' if prof2.get(k, {}).get('kept_in_profile') == 'REAL' else '--sdk-members'
    elif k.startswith('dynamic#'):
        by = 'not a target: the retention gate does not cover dynamic keys, do not widen any from this run'
    else:
        by = 'not a target (counter verdict was not THROWS)'
    rows.append(dict(key=k, counter_release=c['device_verdict'], counter_thin=c['thin'],
                     kept_release=d['device_verdict'], kept_thin=d['thin'],
                     kept_in_profile=prof3.get(k, {}).get('kept_in_profile', ''),
                     kept_by=by, release_kept_1_0_0_64='2fc41d3f'))
with open(f'{kdir}/side_by_side.tsv', 'w') as f:
    w = csv.DictWriter(f, list(rows[0]), delimiter='\t', lineterminator='\n')
    w.writeheader()
    w.writerows(rows)

mat = collections.Counter((r['counter_release'], r['kept_release']) for r in rows)
out = ['# Counter release vs kept release, per key', '',
       'Rows: verdict in the counter release. Columns: verdict in the kept release. Counts are keys.', '']
cols = ['SAFE', 'UNCALLED', 'THROWS', 'CRASH', 'CRASH(host)', 'PARTIAL']
out += ['| counter \\ kept | ' + ' | '.join(cols) + ' | total |', '|---|' + '---|' * (len(cols) + 1)]
for a in cols:
    n = [mat[(a, b)] for b in cols]
    if sum(n):
        out.append(f'| {a} | ' + ' | '.join(str(x) for x in n) + f' | {sum(n)} |')
out += ['']


def listing(title, pred):
    ks = [r for r in rows if pred(r)]
    out.extend([f'## {title} ({len(ks)})', ''])
    out.extend(f"- `{r['key']}`: kept by {r['kept_by']}{' (thin)' if r['kept_thin'] else ''}" for r in ks)
    out.append('')


listing('THROWS in the counter release, SAFE in the kept release',
        lambda r: (r['counter_release'], r['kept_release']) == ('THROWS', 'SAFE'))
listing('THROWS in the counter release, UNCALLED in the kept release (tear-off keys whose call form is not SAFE)',
        lambda r: (r['counter_release'], r['kept_release']) == ('THROWS', 'UNCALLED'))
listing('THROWS in the counter release, CRASH in the kept release',
        lambda r: (r['counter_release'], r['kept_release']) == ('THROWS', 'CRASH'))
listing('THROWS in both',
        lambda r: (r['counter_release'], r['kept_release']) == ('THROWS', 'THROWS'))
listing('CRASH in the counter release, SAFE in the kept release',
        lambda r: (r['counter_release'], r['kept_release']) == ('CRASH', 'SAFE'))
open(f'{kdir}/side_by_side.md', 'w').write('\n'.join(out))
print(mat)
