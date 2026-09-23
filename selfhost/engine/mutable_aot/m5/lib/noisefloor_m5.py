#!/usr/bin/env python3
"""Instrument characterization: how well can this machine resolve a delta?

This measures the MEASURING DEVICE, not Mutable-AOT. Arm A is compared with
arm A -- the same artifact, twice -- so no output here can be a performance
claim about the product. What it produces is the resolution of each workload
at whatever load the machine currently has.

The 2.5 load ceiling in runtime_m5.py was asserted, not measured. This is the
measurement that should decide it, per workload, because the workloads are not
equally fragile:

  hot loop    an in-process ratio of two loops run back to back in one
              process; frequency scaling and preemption hit both and largely
              cancel
  startup     tens to hundreds of milliseconds dominated by page-ins and
              scheduling
  work        seconds of CPU-bound compilation

runtime_m5.py is deliberately NOT modified or imported.
"""
import json, os, statistics, subprocess, sys, time

FORK = '/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT = '/Volumes/build/route-b/flutter/engine/src/out/maot_host'
NS = 'ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
BASE = ('/private/tmp/claude-501/-Users-mendell-shorebird/'
        '541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad')
POP = os.path.join(BASE, 'pop')
WD = os.path.join(BASE, 'runtime')
RT = os.path.join(OUT, 'dartaotruntime')
N = int(os.environ.get('M5_N', '9'))


def load():
    return os.getloadavg()[0]


def wall(cmd, env):
    t0 = time.perf_counter()
    r = subprocess.run(cmd, capture_output=True, timeout=7200, env=env)
    return (time.perf_counter() - t0) * 1000.0, r.returncode


def paired_ab(label, cmd, env, n=N):
    """A against A, interleaved exactly as the real gate interleaves A and C."""
    rows = []
    for i in range(n):
        l0 = load()
        a1, r1 = wall(cmd, env)
        a2, r2 = wall(cmd, env)
        rows.append((i, a1, a2, l0, r1 or r2))
    print('\n--- %s ---' % label)
    print('    %-4s %12s %12s %12s %8s' % ('rep', 'A1 ms', 'A2 ms',
                                           'A2-A1 %', 'load'))
    for i, a1, a2, l0, bad in rows:
        print('    %-4d %12.2f %12.2f %+12.2f %8.1f%s'
              % (i, a1, a2, (a2 - a1) / a1 * 100.0, l0,
                 '  rc!=0' if bad else ''))
    d = [(a2 - a1) / a1 * 100.0 for _, a1, a2, _, _ in rows]
    allv = [v for _, a1, a2, _, _ in rows for v in (a1, a2)]
    env_pct = max(abs(min(d)), abs(max(d)))
    print('    paired A-vs-A   median %+.2f%%   min %+.2f%%   max %+.2f%%'
          % (statistics.median(d), min(d), max(d)))
    print('    absolute        median %.2f ms   min %.2f   max %.2f'
          % (statistics.median(allv), min(allv), max(allv)))
    print('    RESOLUTION: an A-vs-C effect must exceed about %.2f%% here to '
          'be separable' % env_pct)
    return env_pct


def main():
    env = dict(os.environ, MAOT_NAMESPACE=NS)
    print('=== INSTRUMENT CHARACTERIZATION (A vs A only) ===')
    print('This makes no claim about Mutable-AOT. It measures resolution.')
    print('load average at start: %.2f / %.2f / %.2f' % os.getloadavg())
    print('repetitions per workload: %d' % N)
    res = {}

    # 1. the hot loop, via its in-process ratio
    aot = os.path.join(WD, 'bench_A.aot')
    if os.path.exists(aot):
        henv = dict(env, M5_REPS='7', M5_ITERS='20000000')
        ratios, hots = [], []
        print('\n--- hot loop: in-process hot/cold ratio, arm A only ---')
        print('    %-4s %12s %12s %12s %8s' % ('rep', 'hot ns', 'cold ns',
                                               'ratio', 'load'))
        for i in range(N):
            l0 = load()
            r = subprocess.run([RT, aot], capture_output=True, text=True,
                               timeout=7200, env=henv)
            if r.returncode != 0:
                print('    %-4d FAILED %s' % (i, r.stderr[-200:]))
                continue
            kv = dict(l.split('=', 1) for l in r.stdout.splitlines()
                      if '=' in l)
            ratios.append(float(kv['ratio']))
            hots.append(float(kv['hot.ns']))
            print('    %-4d %12s %12s %12s %8.1f'
                  % (i, kv['hot.ns'], kv['cold.ns'], kv['ratio'], l0))
        if ratios:
            spread = (max(ratios) / min(ratios) - 1) * 100.0
            hspread = (max(hots) / min(hots) - 1) * 100.0
            print('    ratio    median %.4f   min %.4f   max %.4f'
                  % (statistics.median(ratios), min(ratios), max(ratios)))
            print('    RESOLUTION on the RATIO statistic: %.2f%%' % spread)
            print('    (for contrast, the raw hot ns/call alone spreads '
                  '%.2f%% over the same runs -- that is what the ratio is '
                  'cancelling)' % hspread)
            res['hot loop (ratio)'] = spread

    # 2. startup, smallest and largest application
    for app in ('smith', 'analysis_server'):
        a = os.path.join(POP, '%s.A.aot' % app)
        if os.path.exists(a):
            res['startup: %s' % app] = paired_ab(
                'startup: %s (A vs A)' % app, [RT, a, '--help'], env)

    # 3. real compile work
    src = os.path.join(WD, 'work.dart')
    if not os.path.exists(src):
        open(src, 'w').write("void main(){print('ok');}\n")
    gk = os.path.join(POP, 'gen_kernel.A.aot')
    if os.path.exists(gk):
        cmd = [RT, gk, '--platform',
               os.path.join(OUT, 'vm_platform_product.dill'), '--aot',
               '--packages', os.path.join(FORK, '.dart_tool/package_config.json'),
               '-o', os.path.join(WD, 'nf.dill'), src]
        res['work: gen_kernel'] = paired_ab('work: gen_kernel (A vs A)', cmd,
                                            env, n=max(5, N // 2))

    print('\n=== RESOLUTION SUMMARY at load %.1f ===' % os.getloadavg()[0])
    print('%-28s %s' % ('workload', 'smallest separable A-vs-C effect'))
    for k, v in res.items():
        print('%-28s %.2f%%' % (k, v))
    print('\nload average at end: %.2f / %.2f / %.2f' % os.getloadavg())


main()
