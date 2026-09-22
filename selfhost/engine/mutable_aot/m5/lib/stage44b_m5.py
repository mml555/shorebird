#!/usr/bin/env python3
"""Stage 44b -- drill the two types that carry the growth.

Reads the profiles Stage 44 already wrote. Strings and Arrays are 96% of the
B - A read-only growth, so the question is which strings and which arrays.
"""
import collections, json, os, sys

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
    out = collections.defaultdict(collections.Counter)   # type -> name -> bytes
    num = collections.defaultdict(collections.Counter)   # type -> name -> count
    for k in range(0, len(nodes), n):
        t = (types[nodes[k + ti]] if nodes[k + ti] < len(types)
             else str(nodes[k + ti]))
        sz = nodes[k + si]
        nm = (strings[nodes[k + ni]] if nodes[k + ni] < len(strings) else '')
        out[t][nm] += sz
        num[t][nm] += 1
    return out, num


A, An = load('A')
B, Bn = load('B')
C, Cn = load('C')


def bucket(nm):
    if nm.startswith('lib:'):
        return 'MAOT declaration id (lib:...::...)'
    if nm in ('C', 'Dart', 'dart', 'aot', 'arm64'):
        return 'MAOT abi / calling-convention literal'
    if nm.startswith('package:'):
        return 'package: uri'
    if nm.startswith('dart:'):
        return 'dart: uri'
    if nm.startswith('file:'):
        return 'file: uri'
    return 'other'


for lo, hi, X, Xn, Y, Yn, label in (
        ('A', 'B', A, An, B, Bn, 'B - A'),
        ('B', 'C', B, Bn, C, Cn, 'C - B')):
    print('=== %s : (RO) String, by content bucket ===' % label)
    tot = collections.Counter()
    cnt = collections.Counter()
    keys = set(Y['(RO) String']) | set(X['(RO) String'])
    for nm in keys:
        d = Y['(RO) String'][nm] - X['(RO) String'].get(nm, 0)
        dc = Yn['(RO) String'][nm] - Xn['(RO) String'].get(nm, 0)
        if d:
            tot[bucket(nm)] += d
            cnt[bucket(nm)] += dc
    print('%-40s %12s %10s %8s' % ('bucket', 'delta bytes', 'delta n', 'avg'))
    for k, v in tot.most_common():
        print('%-40s %+12d %+10d %8.1f'
              % (k, v, cnt[k], (v / cnt[k]) if cnt[k] else 0))
    print('%-40s %+12d %+10d' % ('TOTAL', sum(tot.values()), sum(cnt.values())))
    newest = sorted(((Y['(RO) String'][nm] - X['(RO) String'].get(nm, 0), nm)
                     for nm in keys), reverse=True)[:8]
    print('largest individual string deltas:')
    for d, nm in newest:
        print('   %+9d  %s' % (d, (nm[:110] if nm else '<empty>')))

    print('\n=== %s : Array, by name ===' % label)
    keys = set(Y['Array']) | set(X['Array'])
    rows = sorted(((Y['Array'][nm] - X['Array'].get(nm, 0),
                    Yn['Array'][nm] - Xn['Array'].get(nm, 0), nm)
                   for nm in keys), key=lambda r: -abs(r[0]))[:12]
    print('%12s %8s  %s' % ('delta bytes', 'delta n', 'name'))
    for d, dc, nm in rows:
        if d == 0:
            continue
        print('%+12d %+8d  %s' % (d, dc, (nm[:90] if nm else '<no name>')))
    print()
