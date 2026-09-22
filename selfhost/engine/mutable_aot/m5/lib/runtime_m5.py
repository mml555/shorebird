#!/usr/bin/env python3
"""The runtime gate: A vs C, per workload, never averaged across workloads.

Methodology, as approved:
  * A and C are INTERLEAVED inside each repetition, so thermal and frequency
    drift hits both arms equally;
  * every raw repetition is kept, in execution order;
  * a paired C/A delta is computed per repetition;
  * an A-vs-A noise floor is measured on the same machine in the same shape;
  * no repetition is discarded without a mechanically identified interruption,
    and the detector is stated rather than applied silently;
  * results are reported per workload. A regression in a hot workload is not
    cancelled by a quiet one.
"""
import json, os, shutil, statistics, subprocess, sys, time

FORK = '/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT = '/Volumes/build/route-b/flutter/engine/src/out/maot_host'
DART = '/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart'
M5 = os.path.dirname(os.path.abspath(__file__))
NS = 'ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
BASE = ('/private/tmp/claude-501/-Users-mendell-shorebird/'
        '541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad')
POP = os.path.join(BASE, 'pop')
WD = os.path.join(BASE, 'runtime')
os.makedirs(WD, exist_ok=True)
PKGNAME = 'm5bench'
FIXTURE = 'fixture_m5_bench.dart'

REPS = int(os.environ.get('M5_N', '11'))


def load_avg():
    return os.getloadavg()[0]


def timed(cmd, env):
    """One sample: wall ms, plus the load average before and after, which is
    the mechanical interruption detector. Nothing is dropped here."""
    l0 = load_avg()
    t0 = time.perf_counter()
    r = subprocess.run(cmd, capture_output=True, timeout=7200, env=env)
    ms = (time.perf_counter() - t0) * 1000.0
    return dict(ms=ms, rc=r.returncode, load_before=l0, load_after=load_avg())


def paired(name, cmd_a, cmd_c, env, n=REPS, cmd_a2=None):
    """Interleave A and C within each repetition; also A vs A' for the floor."""
    rows = []
    for i in range(n):
        a = timed(cmd_a, env)
        c = timed(cmd_c, env)
        a2 = timed(cmd_a2 or cmd_a, env)
        rows.append(dict(i=i, a=a, c=c, a2=a2))
    return dict(name=name, rows=rows)


def med(v):
    return statistics.median(v)


def report(res, selected=None, sites=None):
    rows = res['rows']
    A = [r['a']['ms'] for r in rows]
    C = [r['c']['ms'] for r in rows]
    A2 = [r['a2']['ms'] for r in rows]
    bad = [r['i'] for r in rows
           if r['a']['rc'] or r['c']['rc'] or r['a2']['rc']]
    print('\n--- %s ---' % res['name'])
    if selected is not None:
        print('    selected declarations = %d ; with >=1 lowered site = %s'
              % (selected, sites))
    print('    %-4s %12s %12s %12s %12s %10s'
          % ('rep', 'A ms', 'C ms', "A' ms", 'C-A ms', 'C/A'))
    for r in rows:
        print('    %-4d %12.2f %12.2f %12.2f %12.2f %10.4f'
              % (r['i'], r['a']['ms'], r['c']['ms'], r['a2']['ms'],
                 r['c']['ms'] - r['a']['ms'],
                 r['c']['ms'] / r['a']['ms']))
    mA, mC, mA2 = med(A), med(C), med(A2)
    print('    median   A %.2f   C %.2f   A\' %.2f ms' % (mA, mC, mA2))
    print('    spread   A %.2f-%.2f   C %.2f-%.2f   (min-max)'
          % (min(A), max(A), min(C), max(C)))
    print('    IQR      A %.2f   C %.2f'
          % (statistics.quantiles(A, n=4)[2] - statistics.quantiles(A, n=4)[0],
             statistics.quantiles(C, n=4)[2] - statistics.quantiles(C, n=4)[0])
          if len(A) >= 4 else '')
    pair = [(r['c']['ms'] - r['a']['ms']) / r['a']['ms'] * 100.0 for r in rows]
    floor = [(r['a2']['ms'] - r['a']['ms']) / r['a']['ms'] * 100.0
             for r in rows]
    print('    paired  C vs A   median %+.2f%%   min %+.2f%%   max %+.2f%%'
          % (med(pair), min(pair), max(pair)))
    print("    paired  A' vs A  median %+.2f%%   min %+.2f%%   max %+.2f%%"
          "   <- NOISE FLOOR" % (med(floor), min(floor), max(floor)))
    nf = max(abs(min(floor)), abs(max(floor)))
    ef = abs(med(pair))
    print('    verdict  effect %.2f%% vs noise envelope %.2f%%  ->  %s'
          % (ef, nf,
             'SEPARATES' if ef > nf else 'INSIDE THE NOISE, not quotable'))
    loads = [max(r[k]['load_after'] for k in ('a', 'c', 'a2')) for r in rows]
    print('    load average during the run: %.2f - %.2f' % (min(loads),
                                                            max(loads)))
    print('    non-zero exit codes: %s' % (bad if bad else 'none'))
    print('    repetitions discarded: none')


def build_fixture():
    root = os.path.join(WD, 'pkg')
    lib = os.path.join(root, 'lib')
    os.makedirs(lib, exist_ok=True)
    shutil.copy(os.path.join(M5, FIXTURE), os.path.join(lib, FIXTURE))
    tool = os.path.join(root, '.dart_tool')
    os.makedirs(tool, exist_ok=True)
    json.dump({'configVersion': 2, 'packages': [
        {'name': PKGNAME, 'rootUri': 'file://%s/' % root,
         'packageUri': 'lib/', 'languageVersion': '3.9'}]},
        open(os.path.join(tool, 'package_config.json'), 'w'))
    out = {}
    for tag, envx in (('base', {}),
                      ('pol', {'MAOT_SELECT_ALL_NON_SDK': '1',
                               'MAOT_SELECT_URI_PREFIX':
                                   'package:%s/' % PKGNAME})):
        d = os.path.join(WD, 'bench.%s.dill' % tag)
        if not os.path.exists(d):
            r = subprocess.run(
                [DART, '--packages=%s' % os.path.join(FORK, '.dart_tool/package_config.json'),
                 os.path.join(FORK, 'pkg/vm/bin/gen_kernel.dart'), '--platform',
                 os.path.join(OUT, 'vm_platform_product.dill'), '--aot',
                 '--packages', os.path.join(tool, 'package_config.json'),
                 '-o', d, 'package:%s/%s' % (PKGNAME, FIXTURE)],
                capture_output=True, text=True, timeout=1800)
            assert r.returncode == 0, r.stderr[-1200:]
        out[tag] = d
    aots = {}
    for name, dill, extra in (
            ('A', out['base'], []),
            ('C', out['pol'], ['--maot_disable_retention_roots',
                               '--maot_install_trampolines'])):
        p = os.path.join(WD, 'bench_%s.aot' % name)
        if not os.path.exists(p):
            r = subprocess.run(
                [os.path.join(OUT, 'gen_snapshot'),
                 '--snapshot_kind=app-aot-elf', '--elf=%s' % p,
                 '--maot_namespace=%s' % NS] + extra + [dill],
                capture_output=True, text=True, timeout=3600)
            assert r.returncode == 0, r.stderr[-800:]
        aots[name] = p
    return aots


# The rig is shared. A timing result taken under someone else's build is not
# a slower result, it is a meaningless one -- this lane has already had to
# withdraw a set of time percentages for exactly that reason. The harness
# refuses rather than producing a number it would have to caveat.
LOAD_CEILING = float(os.environ.get('M5_LOAD_CEILING', '2.5'))


def require_quiet():
    l1, l5, l15 = os.getloadavg()
    busy = []
    for pat in ('gen_snapshot', 'ninja', 'flutter_tools', 'frontend_server',
                'dart2wasm'):
        r = subprocess.run(['pgrep', '-fl', pat], capture_output=True,
                           text=True)
        if r.returncode == 0:
            busy.append('%s (%d)' % (pat, len(r.stdout.strip().splitlines())))
    print('load average %.2f / %.2f / %.2f   ceiling %.2f' %
          (l1, l5, l15, LOAD_CEILING))
    if busy:
        print('competing build processes: %s' % ', '.join(busy))
    if l1 > LOAD_CEILING or busy:
        print('\nREFUSING TO MEASURE: the machine is not quiet.')
        print('A contaminated timing result is worse than no timing result.')
        sys.exit(2)
    print('machine is quiet; proceeding')


def main():
    env = dict(os.environ, MAOT_NAMESPACE=NS)
    rt = os.path.join(OUT, 'dartaotruntime')
    require_quiet()
    print('repetitions per workload: %d' % REPS)

    # ---- 1. the intrinsic cost: a hot mutable instance call ----
    aots = build_fixture()
    print('\n=== WORKLOAD: hot mutable instance-call loop (synthetic) ===')
    print('    in-process ns/call, hot = mutable (cell-indirect in C), '
          'cold = identical non-mutable method in the same process')
    henv = dict(env, M5_REPS='7', M5_ITERS='20000000')
    print('    %-4s %10s %10s %10s %10s %10s %10s'
          % ('rep', 'A hot', 'A cold', 'C hot', 'C cold', 'A ratio', 'C ratio'))
    ratios = {'A': [], 'C': []}
    for i in range(REPS):
        got = {}
        for arm in ('A', 'C'):
            r = subprocess.run([rt, aots[arm]], capture_output=True, text=True,
                               timeout=7200, env=henv)
            assert r.returncode == 0, r.stderr[-400:]
            kv = dict(l.split('=', 1) for l in r.stdout.splitlines()
                      if '=' in l)
            got[arm] = kv
            ratios[arm].append(float(kv['ratio']))
        print('    %-4d %10s %10s %10s %10s %10s %10s'
              % (i, got['A']['hot.ns'], got['A']['cold.ns'],
                 got['C']['hot.ns'], got['C']['cold.ns'],
                 got['A']['ratio'], got['C']['ratio']))
    ra, rc = med(ratios['A']), med(ratios['C'])
    print('    median hot/cold ratio   A %.4f   C %.4f' % (ra, rc))
    print('    spread ratio            A %.4f-%.4f   C %.4f-%.4f'
          % (min(ratios['A']), max(ratios['A']),
             min(ratios['C']), max(ratios['C'])))
    print('    C ratio / A ratio = %.4f  ->  the indirection costs %+.2f%% '
          'on this call' % (rc / ra, (rc / ra - 1) * 100.0))
    print('    arm A ratio range is the noise floor for this statistic: '
          '%+.2f%%' % ((max(ratios['A']) / min(ratios['A']) - 1) * 100.0))

    # ---- 2. startup, per application ----
    print('\n=== WORKLOAD: startup (process launch + snapshot load) ===')
    for app in ('smith', 'nst', 'gen_kernel', 'dart2wasm', 'analysis_server'):
        a = os.path.join(POP, '%s.A.aot' % app)
        c = os.path.join(POP, '%s.C.aot' % app)
        if not (os.path.exists(a) and os.path.exists(c)):
            continue
        sel = None
        rp = os.path.join(POP, '%s.C.reg.json' % app)
        if os.path.exists(rp):
            j = json.load(open(rp))
            ents = j.get('entries', j if isinstance(j, list) else [])
            s = [e for e in ents if e.get('selected')]
            sel = len(s)
            sites = sum(1 for e in s
                        if (e.get('indirect_call_sites_emitted') or 0) > 0)
        report(paired('startup: %s' % app, [rt, a, '--help'],
                      [rt, c, '--help'], env), sel, sites)

    # ---- 3. real application workloads ----
    print('\n=== WORKLOAD: application work ===')
    src = os.path.join(WD, 'work.dart')
    open(src, 'w').write("void main(){print('ok');}\n")
    gk = {k: os.path.join(POP, 'gen_kernel.%s.aot' % k) for k in 'AC'}
    if all(os.path.exists(v) for v in gk.values()):
        def job(aot, tag):
            return [rt, aot, '--platform',
                    os.path.join(OUT, 'vm_platform_product.dill'), '--aot',
                    '--packages',
                    os.path.join(FORK, '.dart_tool/package_config.json'),
                    '-o', os.path.join(WD, 'w_%s.dill' % tag), src]
        report(paired('gen_kernel compiles a file',
                      job(gk['A'], 'a'), job(gk['C'], 'c'), env,
                      n=max(5, REPS // 2), cmd_a2=job(gk['A'], 'a2')))
    d2w = {k: os.path.join(POP, 'dart2wasm.%s.aot' % k) for k in 'AC'}
    if all(os.path.exists(v) for v in d2w.values()):
        def wjob(aot, tag):
            return [rt, aot, '--platform',
                    os.path.join(OUT, 'vm_platform_product.dill'),
                    '--packages',
                    os.path.join(FORK, '.dart_tool/package_config.json'),
                    src, os.path.join(WD, 'w_%s.wasm' % tag)]
        report(paired('dart2wasm compiles a file',
                      wjob(d2w['A'], 'a'), wjob(d2w['C'], 'c'), env,
                      n=max(5, REPS // 2), cmd_a2=wjob(d2w['A'], 'a2')))
    print('\nmachine load average at end: %.2f' % load_avg())


main()
