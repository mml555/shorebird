#!/usr/bin/env python3
"""Stage 44 -- where the production-policy bytes actually are.

Attribution only. No architecture change, no reduction applied.

Arms are exactly Stage 43's:
  A  baseline kernel                                     install OFF
  B  policy v2 kernel, --maot_disable_retention_roots    install OFF
  C  B + --maot_install_trampolines                      install ON

Each arm is profiled with --write_v8_snapshot_profile_to, which attributes
every serialized object to a type and a name. The ELF section totals from
Stage 43 are the ground truth the profile has to reconcile against; a profile
that does not add up to the section it claims to explain is not attribution.
"""
import collections, json, os, re, subprocess, sys

FORK = '/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT = '/Volumes/build/route-b/flutter/engine/src/out/maot_host'
READELF = ('/Volumes/build/route-b/flutter/engine/src/flutter/buildtools/'
           'mac-arm64/clang/bin/llvm-readelf')
NS = 'ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
WD = ('/private/tmp/claude-501/-Users-mendell-shorebird/'
      '541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/stage43')
S44 = os.path.join(WD, 's44')
os.makedirs(S44, exist_ok=True)

ARMS = {
    'A': ('k0', []),
    'B': ('k2', ['--maot_disable_retention_roots']),
    'C': ('k2', ['--maot_disable_retention_roots', '--maot_install_trampolines']),
}


def sections(aot):
    r = subprocess.run([READELF, '--sections', aot],
                       capture_output=True, text=True)
    out = {}
    for l in r.stdout.splitlines():
        m = re.match(r'\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+\S+\s+\S+\s+([0-9a-f]+)', l)
        if m:
            out[m.group(1)] = int(m.group(2), 16)
    return out


def profile(tag):
    kern, extra = ARMS[tag]
    prof = os.path.join(S44, '%s.prof.json' % tag)
    aot = os.path.join(S44, '%s.aot' % tag)
    ret = os.path.join(S44, '%s.retained' % tag)
    if not os.path.exists(prof):
        r = subprocess.run(
            [os.path.join(OUT, 'gen_snapshot'), '--snapshot_kind=app-aot-elf',
             '--elf=%s' % aot, '--maot_namespace=%s' % NS,
             '--maot_dump_retained=%s' % ret,
             '--write_v8_snapshot_profile_to=%s' % prof] + extra
            + [os.path.join(WD, '%s.dill' % kern)],
            capture_output=True, text=True, timeout=10800)
        if r.returncode != 0:
            print('%s snapshot rc=%d' % (tag, r.returncode),
                  r.stderr.strip()[-400:])
            sys.exit(1)
    return prof, aot, ret


def load(prof):
    j = json.load(open(prof))
    meta = j['snapshot']['meta']
    fields = meta['node_fields']
    types = meta['node_types'][0]
    ti, si, ni = (fields.index(x) for x in ('type', 'self_size', 'name'))
    n = len(fields)
    nodes, strings = j['nodes'], j['strings']
    by = collections.Counter()
    cnt = collections.Counter()
    names = collections.defaultdict(collections.Counter)
    for k in range(0, len(nodes), n):
        t = (types[nodes[k + ti]] if nodes[k + ti] < len(types)
             else str(nodes[k + ti]))
        sz = nodes[k + si]
        by[t] += sz
        cnt[t] += 1
        if sz:
            nm = (strings[nodes[k + ni]] if nodes[k + ni] < len(strings) else '')
            names[t][nm] += sz
    return by, cnt, names


def main():
    data = {}
    for tag in ('A', 'B', 'C'):
        prof, aot, ret = profile(tag)
        by, cnt, names = load(prof)
        sec = sections(aot)
        retained = {l.rstrip('\n') for l in open(ret, errors='replace')
                    if l.strip()} if os.path.exists(ret) else set()
        data[tag] = dict(by=by, cnt=cnt, names=names, sec=sec, aot=aot,
                         retained=retained)

    print('=== RECONCILIATION: does the profile add up to the sections? ===')
    print('%-4s %-12s %-12s %-12s %-12s %-12s'
          % ('arm', 'file', '.text', '.rodata', 'profile total',
             'profile-.text'))
    for tag in ('A', 'B', 'C'):
        d = data[tag]
        tot = sum(d['by'].values())
        instr = d['by'].get('Instructions', 0)
        print('%-4s %-12d %-12d %-12d %-12d %-12d'
              % (tag, os.path.getsize(d['aot']), d['sec'].get('.text', 0),
                 d['sec'].get('.rodata', 0), tot, instr))
    print('  (Instructions objects are what lands in .text; everything else in'
          ' the profile is the read-only data image)')

    for lo, hi, label in (('A', 'B', 'B - A   selection / retention policy'),
                          ('B', 'C', 'C - B   trampoline installation')):
        x, y = data[lo], data[hi]
        dsec = {k: y['sec'].get(k, 0) - x['sec'].get(k, 0)
                for k in ('.text', '.rodata')}
        print('\n=== %s ===' % label)
        print('sections: .text %+d   .rodata %+d' % (dsec['.text'],
                                                     dsec['.rodata']))
        delta = {t: y['by'][t] - x['by'].get(t, 0)
                 for t in set(y['by']) | set(x['by'])}
        pos = sum(v for v in delta.values() if v > 0)
        neg = sum(v for v in delta.values() if v < 0)
        print('profile delta: %+d  (grew %+d, shrank %d)'
              % (pos + neg, pos, neg))
        print('%-28s %12s %12s %12s %9s %9s %8s'
              % ('object type', 'bytes ' + lo, 'bytes ' + hi, 'delta',
                 'count ' + lo, 'count ' + hi, 'avg'))
        ranked = sorted(delta.items(), key=lambda kv: -abs(kv[1]))
        shown = 0
        for t, dv in ranked:
            if abs(dv) < 512:
                continue
            shown += dv
            dc = y['cnt'][t] - x['cnt'].get(t, 0)
            avg = (dv / dc) if dc else 0
            print('%-28s %12d %12d %+12d %9d %9d %8.1f'
                  % (t[:28], x['by'].get(t, 0), y['by'][t], dv,
                     x['cnt'].get(t, 0), y['cnt'][t], avg))
        print('rows shown account for %+d of %+d' % (shown, pos + neg))

    # Per-trampoline non-code cost.
    dC = data['C']['sec'].get('.rodata', 0) - data['B']['sec'].get('.rodata', 0)
    dT = data['C']['sec'].get('.text', 0) - data['B']['sec'].get('.text', 0)
    print('\n=== PER-TRAMPOLINE COST (1853 installed) ===')
    print('.text    %+8d  =  %6.1f B per trampoline' % (dT, dT / 1853.0))
    print('.rodata  %+8d  =  %6.1f B per trampoline' % (dC, dC / 1853.0))

    # Attribute the B - A growth to the declarations that appeared.
    extra = data['B']['retained'] - data['A']['retained']
    lost = data['A']['retained'] - data['B']['retained']
    print('\n=== B - A RETENTION DELTA ===')
    print('declarations gained = %d, lost = %d' % (len(extra), len(lost)))
    short = set()
    for d in extra:
        tail = d.rsplit('_', 1)[-1]
        if tail:
            short.add(tail)
    hit = collections.Counter()
    for t, ctr in data['B']['names'].items():
        for nm, sz in ctr.items():
            if not nm:
                continue
            base = nm.rsplit('_', 1)[-1]
            if base in short:
                hit[t] += sz
    print('bytes in arm B carried by objects whose name ends in one of the %d '
          'gained declaration names:' % len(short))
    for t, sz in hit.most_common(12):
        print('   %-28s %10d' % (t[:28], sz))
    print('   %-28s %10d' % ('TOTAL', sum(hit.values())))
    print('   (upper bound: a name match is not ownership, and objects shared '
          'with the baseline are counted here too)')


main()
