#!/usr/bin/env python3
"""The population report: reads what Stage 47 left on disk, runs nothing.

Columns are the ones the gate asks for, plus the fit of the one-parameter
model -- a stable cost per selected declaration -- against every application.
"""
import collections, json, os, re, statistics, subprocess, sys

P = ('/private/tmp/claude-501/-Users-mendell-shorebird/'
     '541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/pop')
READELF = ('/Volumes/build/route-b/flutter/engine/src/flutter/buildtools/'
           'mac-arm64/clang/bin/llvm-readelf')
APPS = [('smith', 'small'), ('nst', 'medium'), ('gen_kernel', 'large'),
        ('dart2wasm', 'visitor/interface heavy'),
        ('analysis_server', 'dependency heavy')]
WEAK = {'retain:inline-tree'}


def sections(p):
    r = subprocess.run([READELF, '--sections', p], capture_output=True,
                       text=True)
    out = {}
    for l in r.stdout.splitlines():
        m = re.match(r'\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+\S+\s+\S+\s+([0-9a-f]+)', l)
        if m:
            out[m.group(1)] = int(m.group(2), 16)
    return out


def entries(app, arm):
    p = os.path.join(P, '%s.%s.reg.json' % (app, arm))
    if not os.path.exists(p):
        return []
    j = json.load(open(p))
    return j.get('entries', j if isinstance(j, list) else [])


def retained(app, arm):
    p = os.path.join(P, '%s.%s.retained' % (app, arm))
    return ({l.rstrip('\n') for l in open(p, errors='replace') if l.strip()}
            if os.path.exists(p) else set())


def kinds(app, arm):
    p = os.path.join(P, '%s.%s.edges' % (app, arm))
    k = collections.defaultdict(set)
    if os.path.exists(p):
        for l in open(p, errors='replace'):
            q = l.rstrip('\n').split('\t')
            if len(q) == 3:
                k[q[1]].add(q[2])
    return k


rows = []
for app, klass in APPS:
    f = {a: os.path.join(P, '%s.%s.aot' % (app, a)) for a in 'ABC'}
    if not all(os.path.exists(v) for v in f.values()):
        print('%-16s INCOMPLETE -- skipped' % app)
        continue
    sz = {a: os.path.getsize(f[a]) for a in 'ABC'}
    sec = {a: sections(f[a]) for a in 'ABC'}
    ents = entries(app, 'C')
    sel = [e for e in ents if e.get('selected')]
    elig = [e for e in sel if e.get('installable') is True]
    rows.append(dict(app=app, klass=klass, sz=sz, sec=sec, sel=sel, elig=elig,
                     retA=retained(app, 'A'), retC=retained(app, 'C'),
                     kC=kinds(app, 'C')))

print('=== SIZE, A / B / C ===')
print('%-16s %-22s %10s %10s %10s %11s %9s %11s %11s'
      % ('app', 'class', 'A MB', 'B MB', 'C MB', 'C-A B', 'C-A %',
         '.text C-A', '.rodata C-A'))
for r in rows:
    a, b, c = r['sz']['A'], r['sz']['B'], r['sz']['C']
    print('%-16s %-22s %10.3f %10.3f %10.3f %11d %+8.2f%% %11d %11d'
          % (r['app'], r['klass'], a / 1e6, b / 1e6, c / 1e6, c - a,
             100.0 * (c - a) / a,
             r['sec']['C'].get('.text', 0) - r['sec']['A'].get('.text', 0),
             r['sec']['C'].get('.rodata', 0) - r['sec']['A'].get('.rodata', 0)))

print('\n=== POPULATION AND DENSITY ===')
print('%-16s %9s %9s %9s %10s %12s %12s %14s'
      % ('app', 'selected', 'eligible', 'refused', 'retained A',
         'sel/retained', 'sel per MB', 'B per selected'))
for r in rows:
    a = r['sz']['A']
    n = len(r['sel'])
    print('%-16s %9d %9d %9d %10d %12.4f %12.1f %14.1f'
          % (r['app'], n, len(r['elig']), n - len(r['elig']), len(r['retA']),
             n / max(1, len(r['retA'])), n / (a / 1e6),
             (r['sz']['C'] - a) / max(1, n)))

print('\n=== RETENTION DELTA (strong vs weak), C against A ===')
print('%-16s %10s %10s %10s %10s' % ('app', 'strong +', 'strong -', 'weak +',
                                     'weak -'))
for r in rows:
    k = r['kC']
    weakC = {d for d in r['retC'] if k.get(d) and set(k[d]) <= WEAK}
    gained, lost = r['retC'] - r['retA'], r['retA'] - r['retC']
    print('%-16s %10d %10d %10d %10d'
          % (r['app'], len({d for d in gained if d not in weakC}),
             len(lost), len(gained & weakC), 0))

print('\n=== OPTIMIZER BLOCKERS, granular (arm C) ===')
for r in rows:
    ref = [e for e in r['sel'] if e.get('installable') is not True]
    print('%-16s refused %d of %d selected (%.1f%%)'
          % (r['app'], len(ref), len(r['sel']),
             100.0 * len(ref) / max(1, len(r['sel']))))
    cat = collections.Counter((e.get('first_escape_reason') or '<none>')
                              for e in ref)
    for reason, n in cat.most_common(8):
        print('      %5d  %s' % (n, reason[:96]))

print('\n=== DISPATCH PROFILE (arm C) ===')
print('%-16s %14s %14s %14s %12s'
      % ('app', 'with >=1 cell', 'no cell site', 'median sites',
         'max sites'))
for r in rows:
    sites = [e.get('indirect_call_sites_emitted', 0) for e in r['sel']]
    withs = [s for s in sites if s > 0]
    print('%-16s %14d %14d %14.1f %12d'
          % (r['app'], len(withs), len(sites) - len(withs),
             statistics.median(withs) if withs else 0,
             max(sites) if sites else 0))
print('   "no cell site" = the declaration has no static call site that #67'
      ' lowered;\n   it is reached through the trampoline (virtual, interface'
      ' or dynamic) or not called.')

print('\n=== MODEL FIT:  C - A  ~  unit cost x selected ===')
big = [r for r in rows if len(r['sel']) >= 200]
unit = (sum(r['sz']['C'] - r['sz']['A'] for r in big) /
        max(1, sum(len(r['sel']) for r in big)))
print('unit cost fitted on the %d populations with >=200 selected '
      'declarations: %.1f B per selected declaration' % (len(big), unit))
print('%-16s %9s %13s %13s %9s %9s %8s'
      % ('app', 'selected', 'measured B', 'predicted B', 'meas %', 'pred %',
         'error pp'))
for r in rows:
    a = r['sz']['A']
    m = r['sz']['C'] - a
    p = unit * len(r['sel'])
    mp, pp = 100.0 * m / a, 100.0 * p / a
    print('%-16s %9d %13d %13.0f %+8.2f%% %+8.2f%% %+7.2f'
          % (r['app'], len(r['sel']), m, p, mp, pp, pp - mp))
