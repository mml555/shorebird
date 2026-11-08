#!/usr/bin/env python3
"""Stage 44c -- is the registry metadata duplicated, and by how much.

A string that appears N times as N distinct objects costs N copies. The
profile reports every node separately, so counting nodes per exact content
answers "duplicate/redundant" without guessing.
"""
import collections, json, os

WD = ('/private/tmp/claude-501/-Users-mendell-shorebird/'
      '541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/stage43')
S44 = os.path.join(WD, 's44')


def load(tag):
    j = json.load(open(os.path.join(S44, '%s.prof.json' % tag)))
    meta = j['snapshot']['meta']
    fields = meta['node_fields']
    types = meta['node_types'][0]
    ti, si, ni = (fields.index(x) for x in ('type', 'self_size', 'name'))
    n = len(fields)
    nodes, strings = j['nodes'], j['strings']
    rows = []
    for k in range(0, len(nodes), n):
        t = (types[nodes[k + ti]] if nodes[k + ti] < len(types)
             else str(nodes[k + ti]))
        rows.append((t, nodes[k + si],
                     strings[nodes[k + ni]] if nodes[k + ni] < len(strings)
                     else ''))
    return rows


A = load('A')
B = load('B')
C = load('C')


def copies(rows, pred):
    c = collections.Counter()
    b = collections.Counter()
    for t, sz, nm in rows:
        if t == '(RO) String' and pred(nm):
            c[nm] += 1
            b[nm] += sz
    return c, b


print('=== registry metadata strings: how many COPIES of each value ===')
print('%-46s %7s %7s %10s %10s' % ('content', 'n in A', 'n in B', 'bytes B',
                                   'if interned'))
tot_b = tot_i = 0
for pred, label in ((lambda s: s.startswith('cc1;'), 'calling convention'),
                    (lambda s: s.startswith('the dispatch cell has no seeded'),
                     'escape reason'),
                    (lambda s: s == 'C', 'abi literal "C"')):
    ca, _ = copies(A, pred)
    cb, bb = copies(B, pred)
    for nm in sorted(cb, key=lambda k: -bb[k]):
        one = bb[nm] // cb[nm] if cb[nm] else 0
        tot_b += bb[nm]
        tot_i += one
        print('%-46s %7d %7d %10d %10d'
              % ((nm[:44] + '..') if len(nm) > 46 else nm,
                 ca.get(nm, 0), cb[nm], bb[nm], one))
print('%-46s %7s %7s %10d %10d   -> recoverable %d B'
      % ('TOTAL of the above', '', '', tot_b, tot_i, tot_b - tot_i))

print('\n=== declaration ids ===')
ca, _ = copies(A, lambda s: s.startswith('lib:'))
cb, bb = copies(B, lambda s: s.startswith('lib:'))
dup = {nm: n for nm, n in cb.items() if n > 1}
print('distinct declaration-id strings: A=%d  B=%d' % (len(ca), len(cb)))
print('total string objects:            A=%d  B=%d'
      % (sum(ca.values()), sum(cb.values())))
print('bytes in B:                      %d   (avg %.1f)'
      % (sum(bb.values()), sum(bb.values()) / max(1, sum(cb.values()))))
print('values stored more than once:    %d   (%d duplicate objects)'
      % (len(dup), sum(n - 1 for n in dup.values())))

print('\n=== the new Arrays in B - A, by size ===')
sa = collections.Counter(sz for t, sz, _ in A if t == 'Array')
sb = collections.Counter(sz for t, sz, _ in B if t == 'Array')
print('%8s %9s %9s %9s %12s' % ('size', 'n in A', 'n in B', 'delta n',
                                'delta bytes'))
rows = sorted(set(sa) | set(sb), key=lambda s: -(sb[s] - sa[s]) * s)
for s in rows[:10]:
    d = sb[s] - sa[s]
    if d == 0:
        continue
    print('%8d %9d %9d %+9d %+12d' % (s, sa[s], sb[s], d, d * s))

print('\n=== C - B, by type, per installed trampoline (1853) ===')
def by_type(rows):
    c = collections.Counter()
    n = collections.Counter()
    for t, sz, _ in rows:
        c[t] += sz
        n[t] += 1
    return c, n
cb_, nb_ = by_type(B)
cc_, nc_ = by_type(C)
print('%-28s %12s %9s %10s' % ('type', 'delta bytes', 'delta n', 'B / tramp'))
for t in sorted(set(cc_) | set(cb_), key=lambda t: -(cc_[t] - cb_[t])):
    d = cc_[t] - cb_[t]
    if abs(d) < 64:
        continue
    print('%-28s %+12d %+9d %10.2f'
          % (t[:28], d, nc_[t] - nb_[t], d / 1853.0))
