#!/usr/bin/env python3
"""Stage 43 -- the honest production-policy size.

  A  baseline kernel, no selection      indirection n/a   install OFF
  B  policy v2 kernel                   indirection ON    install OFF
  C  policy v2 kernel                   indirection ON    install ON

Policy v2 is root-package ownership (MAOT_SELECT_ALL_NON_SDK=1,
MAOT_SELECT_URI_PREFIX=package:vm/) with --maot_disable_retention_roots, so
selection CONSUMES retention instead of causing it.

Every arm is given the same diagnostic flags, so the deltas are policy and not
instrumentation -- that mistake cost four rounds in Stage 31 and it is not
going to be repeated by leaving a dump flag on one arm only.

  B - A = selection + non-inlining + routing
  C - B = trampoline and installation
  C - A = the production-policy cost
"""
import collections, json, os, re, subprocess, sys

FORK = '/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT = '/Volumes/build/route-b/flutter/engine/src/out/maot_host'
DART = '/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart'
READELF = ('/Volumes/build/route-b/flutter/engine/src/flutter/buildtools/'
           'mac-arm64/clang/bin/llvm-readelf')
PKG = os.path.join(FORK, '.dart_tool/package_config.json')
APP = os.path.join(FORK, 'pkg/vm/bin/gen_kernel.dart')
NS = 'ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
WD = ('/private/tmp/claude-501/-Users-mendell-shorebird/'
      '541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/stage43')
os.makedirs(WD, exist_ok=True)
POLICY_V2 = {'MAOT_SELECT_ALL_NON_SDK': '1',
             'MAOT_SELECT_URI_PREFIX': 'package:vm/'}
WEAK_SITES = {'retain:inline-tree'}

src = os.path.join(WD, 'work.dart')
open(src, 'w').write("void main(){print('ok');}\n")

# Identical on every arm. Named once so no arm can drift.
DIAG = ['--maot_verify_pinned_body_traversal', '--maot_dump_trampoline_shape']


def kernel(tag, envx):
    d = os.path.join(WD, '%s.dill' % tag)
    if not os.path.exists(d):
        r = subprocess.run(
            [DART, '--packages=%s' % PKG, APP,
             '--platform', os.path.join(OUT, 'vm_platform_product.dill'),
             '--aot', '--packages', PKG, '-o', d, APP],
            capture_output=True, text=True, timeout=3600,
            env=dict(os.environ, **envx))
        assert r.returncode == 0, r.stderr[-900:]
    return d


def sections(aot):
    r = subprocess.run([READELF, '--sections', aot],
                       capture_output=True, text=True)
    out = {}
    for l in r.stdout.splitlines():
        m = re.match(r'\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+\S+\s+\S+\s+([0-9a-f]+)', l)
        if m:
            out[m.group(1)] = int(m.group(2), 16)
    return out


def arm(tag, dill, roots_off, install):
    aot = os.path.join(WD, '%s.aot' % tag)
    pre = os.path.join(WD, '%s.reg.json' % tag)
    ret = os.path.join(WD, '%s.retained' % tag)
    edg = os.path.join(WD, '%s.edges' % tag)
    cmd = [os.path.join(OUT, 'gen_snapshot'), '--snapshot_kind=app-aot-elf',
           '--elf=%s' % aot, '--maot_namespace=%s' % NS,
           '--maot_dump_registry_precompile=%s' % pre,
           '--maot_dump_retained=%s' % ret,
           '--maot_dump_reach_edges=%s' % edg] + DIAG
    if roots_off:
        cmd.append('--maot_disable_retention_roots')
    if install:
        cmd.append('--maot_install_trampolines')
    cmd.append(dill)
    s = subprocess.run(cmd, capture_output=True, text=True, timeout=10800)
    assert s.returncode == 0, [l for l in s.stderr.splitlines()
                               if 'si_addr' in l][:2]
    sel = elig = 0
    if os.path.exists(pre):
        j = json.load(open(pre))
        ents = j.get('entries', j if isinstance(j, list) else [])
        for e in ents:
            if e.get('selected'):
                sel += 1
                if e.get('installable') is True:
                    elig += 1
    inst = dist = -1
    part = trav = edges = '-'
    for l in s.stderr.splitlines():
        m = re.search(r'POST-DEDUP trampolines: installed=(\d+) distinct=(\d+)', l)
        if m:
            inst, dist = int(m.group(1)), int(m.group(2))
        if 'PINNED_TRAVERSAL' in l:
            trav = l.split('verdict=')[-1].strip()
        if 'BODY_PARTITION' in l:
            part = l.split('BODY_PARTITION')[-1].strip()
        if 'RELEASE_EDGES' in l:
            edges = l.split('RELEASE_EDGES')[-1].strip()
    retained = {l.rstrip('\n') for l in open(ret, errors='replace') if l.strip()}
    kinds = collections.defaultdict(set)
    for l in open(edg, errors='replace'):
        p = l.rstrip('\n').split('\t')
        if len(p) == 3:
            kinds[p[1]].add(p[2])
    weak = {d for d in retained if kinds.get(d) and set(kinds[d]) <= WEAK_SITES}
    sec = sections(aot)
    # The workload has to still run, or a smaller snapshot means nothing.
    od = os.path.join(WD, 'o_%s.dill' % tag)
    if os.path.exists(od):
        os.remove(od)
    q = subprocess.run(
        [os.path.join(OUT, 'dartaotruntime'), aot, '--platform',
         os.path.join(OUT, 'vm_platform_product.dill'), '--aot', '--packages',
         PKG, '-o', od, src],
        capture_output=True, text=True, timeout=900,
        env=dict(os.environ, MAOT_NAMESPACE=NS))
    ok = q.returncode == 0 and os.path.exists(od) and os.path.getsize(od) > 0
    return dict(tag=tag, size=os.path.getsize(aot), text=sec.get('.text', 0),
                rodata=sec.get('.rodata', 0), sel=sel, elig=elig,
                inst=inst, dist=dist, part=part, trav=trav, edges=edges,
                retained=retained, weak=weak, ok=ok)


def main():
    k0 = kernel('k0', {})
    k2 = kernel('k2', POLICY_V2)
    print('kernels: baseline %.1f MB, policy v2 %.1f MB'
          % (os.path.getsize(k0) / 1e6, os.path.getsize(k2) / 1e6))
    A = arm('A', k0, roots_off=False, install=False)
    B = arm('B', k2, roots_off=True, install=False)
    C = arm('C', k2, roots_off=True, install=True)

    print('\n%-3s %-9s %-9s %-9s %-7s %-7s %-7s %-9s %-9s %s'
          % ('arm', 'MB', '.text', '.rodata', 'sel', 'elig', 'refused',
             'installed', 'distinct', 'workload'))
    for r in (A, B, C):
        print('%-3s %-9.3f %-9d %-9d %-7d %-7d %-7d %-9s %-9s %s'
              % (r['tag'], r['size'] / 1e6, r['text'], r['rodata'], r['sel'],
                 r['elig'], r['sel'] - r['elig'],
                 r['inst'] if r['inst'] >= 0 else '-',
                 r['dist'] if r['dist'] >= 0 else '-',
                 'ok' if r['ok'] else 'FAIL'))

    print('\nbody partition / traversal / release edges')
    for r in (A, B, C):
        print('  %s  traversal=%s' % (r['tag'], r['trav']))
        print('     partition=%s' % r['part'])
        print('     %s' % r['edges'])

    print('\n=== RETENTION ===')
    print('%-3s %-10s %-10s %-10s' % ('arm', 'retained', 'strong', 'weak'))
    for r in (A, B, C):
        print('%-3s %-10d %-10d %-10d'
              % (r['tag'], len(r['retained']),
                 len(r['retained']) - len(r['weak']), len(r['weak'])))

    def delta(x, y, label):
        # Membership first, then class -- taking the difference of the two
        # strong sets would count a declaration both arms retain whose class
        # differs, which is not a retention change at all.
        lost, extra = x['retained'] - y['retained'], y['retained'] - x['retained']
        print('%-8s  size %+8d B (%+6.2f%%)   .text %+8d   .rodata %+8d'
              % (label, y['size'] - x['size'],
                 100.0 * (y['size'] - x['size']) / x['size'],
                 y['text'] - x['text'], y['rodata'] - x['rodata']))
        print('%-8s  strong retention  -%d / +%d      weak inline-only  -%d / +%d'
              % ('', len({d for d in lost if d not in x['weak']}),
                 len({d for d in extra if d not in y['weak']}),
                 len(lost & x['weak']), len(extra & y['weak'])))

    print('\n=== DERIVED COSTS ===')
    delta(A, B, 'B - A')
    print('          selection + non-inlining + routing')
    delta(B, C, 'C - B')
    print('          trampoline and installation')
    delta(A, C, 'C - A')
    print('          THE PRODUCTION-POLICY COST')
    print('\nall three workloads succeeded: %s'
          % ('yes' if all(r['ok'] for r in (A, B, C)) else 'NO'))


main()
