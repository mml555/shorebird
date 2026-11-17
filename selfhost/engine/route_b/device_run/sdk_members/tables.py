#!/usr/bin/env python3
# cspell:words hostkey xids
"""tables.py <gen dir> <raw results.tsv> <host evidence dir> <out dir> [--device LABEL]

Joins what each probe did on the device with the member it tested and writes
<out>/results.tsv (the host matrix's columns plus `device`) and <out>/members.json.

<gen dir>       gen_device_probe.py's output (probes.tsv, left_out.txt)
<raw results>   one `<probe>\\t<result>` line per probe, from the app's
                results.tsv in its Documents folder (result is OK, ERR <text> or ABORTS)
<host dir>      the host matrix (evidence/sdk_instance_members on PR #209's branch); its
                results.tsv gives each probe id its key. Probes the host did not run
                (dart:ui, StreamSubscription) are keyed below.

A probe RESOLVES when the member ran, or failed with an error that is not a
NoSuchMethodError naming it. THROWS is a NoSuchMethodError naming the member;
ABORTS killed the process (the next launch recorded it); a NoSuchMethodError
naming something else is UNATTRIBUTED and counts as a failure; NOT-RUN means the
probe never ran (left out of the patch, or its stub was not patched).
A key is accepted only when every probe of it resolved.
"""
import json
import re
import sys
from collections import Counter

gen, raw, host, out = sys.argv[1:5]
device = sys.argv[sys.argv.index('--device') + 1] if '--device' in sys.argv else 'device'

NEW_KEYS = {
    'size_width': 'dart:ui#Size#get:width', 'size_height': 'dart:ui#Size#get:height',
    'offset_dx': 'dart:ui#Offset#get:dx', 'offset_dy': 'dart:ui#Offset#get:dy',
}


def key_of(pid, form, sel):
    base = pid.split('__')[0]
    if base in NEW_KEYS:
        return f'dynamic#{sel}' if 'dynamic' in form else NEW_KEYS[base]
    if base == 'sub_cancel':
        if 'dynamic' in form:
            return 'dynamic#tearoff:cancel' if form.startswith('tearoff') else 'dynamic#cancel'
        return 'dart:async#StreamSubscription#' + ('tearoff:cancel' if form.startswith('tearoff') else 'cancel')
    return None


hostkey = {}
for l in list(open(f'{host}/results.tsv'))[1:]:
    f = l.rstrip('\n').split('\t')
    hostkey[f[0]] = f[1]
res = {}
for l in open(raw):
    f = l.rstrip('\n').split('\t', 1)
    res[f[0]] = f[1] if len(f) > 1 else ''
left_out = set(open(f'{gen}/left_out.txt').read().split())
xids = dict(l.rstrip('\n').split('\t') for l in open(f'{gen}/excluded_ids.tsv') if l.strip())
rows, per_key = [], {}
for l in open(f'{gen}/probes.tsv'):
    pid, typ, label, form, sel = l.rstrip('\n').split('\t')
    r = res.get(pid)
    plain = re.sub(r'^(get:|set:|tearoff:)', '', sel)
    detail = ''
    if xids.get(pid) in ('device-abort', 'device-activation-abort'):
        st, detail = 'ABORTS', 'the process aborted while the patch was activated (device launch), before main'
    elif r is None:
        st = 'NOT-RUN'
        detail = ('aborted on the host matrix; not tried on the device' if xids.get(pid) == 'host-abort'
                  else 'left out of the patch' if pid in left_out else 'no result recorded')
    elif r == 'ABORTS':
        st = 'ABORTS'
    elif r == 'OK':
        st = 'RESOLVES'
    else:
        detail = r
        if 'NoSuchMethodError' in r:
            st = 'THROWS' if plain in r else 'UNATTRIBUTED'
        else:
            st = 'RESOLVES'
    key = key_of(pid, form, sel) or hostkey.get(pid)
    if key == '?':
        key = None
    rows.append((pid, key or '?', typ, label, form, st, detail[:140], device))
    if key:
        e = per_key.setdefault(key, {'resolves': [], 'fails': [], 'unmeasured': []})
        tag = f'{label}:{form}:{st}'
        (e['resolves'] if st == 'RESOLVES' else e['unmeasured'] if st == 'NOT-RUN' else e['fails']).append(tag)
with open(f'{out}/results.tsv', 'w') as o:
    o.write('probe\tkey\treceiver_type\truntime_class\tform\tresult\tdetail\tdevice\n')
    for r in rows:
        o.write('\t'.join(r) + '\n')
members = {}
for k, e in sorted(per_key.items()):
    ok = not e['fails'] and not e['unmeasured'] and e['resolves']
    members[k] = {'accepted': bool(ok), 'failing': e['fails'][:8], 'unmeasured': e['unmeasured'][:8],
                  'resolving_on': len(e['resolves'])}
json.dump(members, open(f'{out}/members.json', 'w'), indent=1, sort_keys=True)
print(Counter(r[5] for r in rows))
print('accepted keys', sum(m['accepted'] for m in members.values()), 'of', len(members))
