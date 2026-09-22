#!/usr/bin/env python3
"""Stage 44 (programme) / Stage 47 (lane) -- default-readiness population gate.

The same A/B/C matrix as Stage 43, run unchanged over a population of real
applications. Nothing is tuned per application; the policy is root-package
ownership with --maot_disable_retention_roots in every arm, exactly as
accepted.

What matters is the DISTRIBUTION of C - A, so every application is reported
individually and the spread is printed. The population is also characterized
rather than labelled: the dispatch profile and the refusal reasons are
measured per application, so "dependency-heavy" and "dynamic-heavy" are
readings rather than assertions.
"""
import collections, json, os, re, subprocess, sys, time

FORK = '/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT = '/Volumes/build/route-b/flutter/engine/src/out/maot_host'
DART = '/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart'
READELF = ('/Volumes/build/route-b/flutter/engine/src/flutter/buildtools/'
           'mac-arm64/clang/bin/llvm-readelf')
PKG = os.path.join(FORK, '.dart_tool/package_config.json')
NS = 'ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
WD = ('/private/tmp/claude-501/-Users-mendell-shorebird/'
      '541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/pop')
os.makedirs(WD, exist_ok=True)
WEAK_SITES = {'retain:inline-tree'}
DIAG = ['--maot_verify_pinned_body_traversal', '--maot_dump_trampoline_shape']

# name, entry point, root package prefix, expected class
APPS = [
    ('smith',       'pkg/smith/bin/print_configurations.dart',  'package:smith/',       'small'),
    ('nst',         'pkg/native_stack_traces/bin/decode.dart',  'package:native_stack_traces/', 'medium'),
    ('gen_kernel',  'pkg/vm/bin/gen_kernel.dart',               'package:vm/',          'large'),
    ('dart2wasm',   'pkg/dart2wasm/bin/dart2wasm.dart',         'package:dart2wasm/',   'visitor/interface heavy'),
    ('analysis_server', 'pkg/analysis_server/bin/server.dart',  'package:analysis_server/', 'dependency heavy'),
]


def sections(aot):
    r = subprocess.run([READELF, '--sections', aot], capture_output=True,
                       text=True)
    out = {}
    for l in r.stdout.splitlines():
        m = re.match(r'\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+\S+\s+\S+\s+([0-9a-f]+)', l)
        if m:
            out[m.group(1)] = int(m.group(2), 16)
    return out


def kernel(app, entry, envx, tag):
    d = os.path.join(WD, '%s.%s.dill' % (app, tag))
    if os.path.exists(d) and os.path.getsize(d) > 0:
        return d
    r = subprocess.run(
        [DART, '--packages=%s' % PKG,
         os.path.join(FORK, 'pkg/vm/bin/gen_kernel.dart'), '--platform',
         os.path.join(OUT, 'vm_platform_product.dill'), '--aot', '--packages',
         PKG, '-o', d, os.path.join(FORK, entry)],
        capture_output=True, text=True, timeout=7200,
        env=dict(os.environ, **envx))
    if r.returncode != 0:
        print('   KERNEL FAIL %s/%s: %s' % (app, tag,
                                            r.stderr.strip()[-300:]))
        return None
    return d


def arm(app, tag, dill, roots_off, install):
    aot = os.path.join(WD, '%s.%s.aot' % (app, tag))
    pre = os.path.join(WD, '%s.%s.reg.json' % (app, tag))
    ret = os.path.join(WD, '%s.%s.retained' % (app, tag))
    edg = os.path.join(WD, '%s.%s.edges' % (app, tag))
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
    t0 = time.time()
    s = subprocess.run(cmd, capture_output=True, text=True, timeout=14400)
    if s.returncode != 0:
        print('   SNAPSHOT FAIL %s/%s rc=%d %s'
              % (app, tag, s.returncode,
                 [l for l in s.stderr.splitlines() if 'si_addr' in l][:1]))
        return None
    sel = elig = 0
    reasons = collections.Counter()
    if os.path.exists(pre):
        j = json.load(open(pre))
        ents = j.get('entries', j if isinstance(j, list) else [])
        for e in ents:
            if not e.get('selected'):
                continue
            sel += 1
            if e.get('installable') is True:
                elig += 1
            else:
                reasons[(e.get('first_escape_reason') or '<none>')[:60]] += 1
    inst = dist = -1
    part = trav = '-'
    for l in s.stderr.splitlines():
        m = re.search(r'POST-DEDUP trampolines: installed=(\d+) distinct=(\d+)', l)
        if m:
            inst, dist = int(m.group(1)), int(m.group(2))
        if 'PINNED_TRAVERSAL' in l:
            trav = l.split('verdict=')[-1].strip()
        if 'BODY_PARTITION' in l:
            part = l.split('BODY_PARTITION')[-1].strip()
    retained = {l.rstrip('\n') for l in open(ret, errors='replace')
                if l.strip()} if os.path.exists(ret) else set()
    kinds = collections.defaultdict(set)
    if os.path.exists(edg):
        for l in open(edg, errors='replace'):
            p = l.rstrip('\n').split('\t')
            if len(p) == 3:
                kinds[p[1]].add(p[2])
    weak = {d for d in retained if kinds.get(d) and set(kinds[d]) <= WEAK_SITES}
    dispatch = sum(1 for d in retained
                   if 'forced via flag' in kinds.get(d, ()) or
                   'dynamic invocation forwarder' in kinds.get(d, ()))
    sec = sections(aot)
    return dict(tag=tag, secs=time.time() - t0, size=os.path.getsize(aot),
                text=sec.get('.text', 0), rodata=sec.get('.rodata', 0),
                sel=sel, elig=elig, inst=inst, dist=dist, part=part,
                trav=trav, retained=retained, weak=weak, reasons=reasons,
                dispatch=dispatch)


def main():
    only = sys.argv[1:]
    rows = []
    for app, entry, prefix, klass in APPS:
        if only and app not in only:
            continue
        print('=== %s (%s)  %s' % (app, klass, entry), flush=True)
        k0 = kernel(app, entry, {}, 'base')
        k2 = kernel(app, entry,
                    {'MAOT_SELECT_ALL_NON_SDK': '1',
                     'MAOT_SELECT_URI_PREFIX': prefix}, 'pol')
        if k0 is None or k2 is None:
            continue
        print('   kernels: base %.1f MB  policy %.1f MB'
              % (os.path.getsize(k0) / 1e6, os.path.getsize(k2) / 1e6),
              flush=True)
        A = arm(app, 'A', k0, False, False)
        B = arm(app, 'B', k2, True, False)
        C = arm(app, 'C', k2, True, True)
        if not (A and B and C):
            continue
        rows.append((app, klass, A, B, C))
        ca = 100.0 * (C['size'] - A['size']) / A['size']
        print('   A %.3f MB   B %.3f MB   C %.3f MB   C-A %+d B (%+.2f%%)'
              % (A['size'] / 1e6, B['size'] / 1e6, C['size'] / 1e6,
                 C['size'] - A['size'], ca), flush=True)
        json.dump({t: {k: v for k, v in r.items()
                       if k not in ('retained', 'weak', 'reasons')}
                   for t, r in (('A', A), ('B', B), ('C', C))},
                  open(os.path.join(WD, '%s.summary.json' % app), 'w'),
                  indent=1)

    if not rows:
        return
    print('\n%-16s %-22s %10s %10s %10s %9s %9s %8s %8s %9s %9s'
          % ('app', 'class', 'A MB', 'B MB', 'C MB', 'C-A B', 'C-A %',
             'sel', 'refused', 'installed', 'distinct'))
    for app, klass, A, B, C in rows:
        print('%-16s %-22s %10.3f %10.3f %10.3f %9d %+8.2f%% %8d %8d %9d %9d'
              % (app, klass, A['size'] / 1e6, B['size'] / 1e6, C['size'] / 1e6,
                 C['size'] - A['size'],
                 100.0 * (C['size'] - A['size']) / A['size'],
                 C['sel'], C['sel'] - C['elig'], C['inst'], C['dist']))
    pcts = [100.0 * (C['size'] - A['size']) / A['size']
            for _, _, A, B, C in rows]
    print('\nC - A distribution: min %+.2f%%  max %+.2f%%  spread %.2f pp'
          % (min(pcts), max(pcts), max(pcts) - min(pcts)))
    print('\n%-16s %10s %10s %10s %10s %9s %9s'
          % ('app', 'B-A %', 'C-B %', '.text C-A', '.rodata C-A',
             'strong +', 'weak +'))
    for app, klass, A, B, C in rows:
        sa, sc = A['retained'] - A['weak'], C['retained'] - C['weak']
        print('%-16s %+9.2f%% %+9.2f%% %10d %11d %9d %9d'
              % (app,
                 100.0 * (B['size'] - A['size']) / A['size'],
                 100.0 * (C['size'] - B['size']) / B['size'],
                 C['text'] - A['text'], C['rodata'] - A['rodata'],
                 len({d for d in (C['retained'] - A['retained'])
                      if d not in C['weak']}),
                 len((C['retained'] - A['retained']) & C['weak'])))
    print('\n=== optimizer blockers, by reason (arm C) ===')
    for app, klass, A, B, C in rows:
        tot = sum(C['reasons'].values())
        print('%-16s refused %d of %d selected' % (app, tot, C['sel']))
        for r, n in C['reasons'].most_common(6):
            print('      %5d  %s' % (n, r))
    print('\n=== dispatch profile (declarations reached by a selector or a '
          'dynamic forwarder, arm C) ===')
    for app, klass, A, B, C in rows:
        print('%-16s %7d of %d retained (%.1f%%)'
              % (app, C['dispatch'], len(C['retained']),
                 100.0 * C['dispatch'] / max(1, len(C['retained']))))


main()
