#!/usr/bin/env python3
"""The runtime gate: A vs C, per workload, never averaged across workloads.

Methodology, as approved:
  * A and C are INTERLEAVED inside each repetition, so thermal and frequency
    drift hits both arms equally;
  * every raw repetition is kept, in execution order;
  * a paired C/A delta is computed per repetition;
  * an A-vs-A noise floor is measured in the same shape, in the same run;
  * results are reported per workload -- a regression in a hot workload is
    never cancelled by a quiet one.

Harness conditions, which are NOT result filters:
  * the machine must be quiet on TWO consecutive preflight observations
    before the first timed sample, so a run cannot begin in the wake of a
    large build while caches and thermals are still settling;
  * if a competitor appears during a workload, that WHOLE workload is
    invalidated and must be rerun from the beginning. Individual repetitions
    are never dropped.

Usage:  runtime_m5.py [workload ...]      default: all
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
LOAD_CEILING = float(os.environ.get('M5_LOAD_CEILING', '2.5'))
PREFLIGHT_GAP = int(os.environ.get('M5_PREFLIGHT_GAP', '60'))
# Processes that mean another lane is building. dartaotruntime is absent on
# purpose: that is this harness's own workload.
COMPETITORS = ('gen_snapshot', 'ninja', 'flutter_tools', 'frontend_server',
               'dart2wasm.snapshot', 'xcodebuild', 'clang++')


def competitors():
    found = []
    for pat in COMPETITORS:
        r = subprocess.run(['pgrep', '-f', pat], capture_output=True,
                           text=True)
        if r.returncode == 0:
            n = len(r.stdout.strip().splitlines())
            if n:
                found.append('%s x%d' % (pat, n))
    return found


def observe():
    l1, l5, l15 = os.getloadavg()
    return dict(t=time.strftime('%H:%M:%S'), l1=l1, l5=l5, l15=l15,
                comp=competitors())


def ok(o):
    return o['l1'] <= LOAD_CEILING and not o['comp']


def preflight():
    """Two consecutive clean observations, both recorded with the evidence."""
    obs = []
    for i in range(2):
        if i:
            time.sleep(PREFLIGHT_GAP)
        o = observe()
        obs.append(o)
        print('   preflight %d at %s: load %.2f / %.2f / %.2f  competitors: %s'
              % (i + 1, o['t'], o['l1'], o['l5'], o['l15'],
                 ', '.join(o['comp']) if o['comp'] else 'none'))
        if not ok(o):
            print('\nREFUSING TO MEASURE: the machine is not quiet '
                  '(ceiling %.2f, two consecutive clean observations '
                  'required).' % LOAD_CEILING)
            print('A contaminated timing result is worse than no timing '
                  'result.')
            sys.exit(2)
    print('   two consecutive clean observations %ds apart; proceeding'
          % PREFLIGHT_GAP)
    return obs


def timed(cmd, env):
    t0 = time.perf_counter()
    r = subprocess.run(cmd, capture_output=True, timeout=7200, env=env)
    return dict(ms=(time.perf_counter() - t0) * 1000.0, rc=r.returncode,
                out=r.stdout.decode('utf8', 'replace'))


def med(v):
    return statistics.median(v)


def run_paired(name, cmd_a, cmd_c, cmd_a2, env, n):
    """A, C, A' interleaved per repetition. Watches for competitors."""
    rows, watch = [], []
    for i in range(n):
        watch.append(observe())
        a = timed(cmd_a, env)
        c = timed(cmd_c, env)
        a2 = timed(cmd_a2, env)
        rows.append(dict(i=i, a=a, c=c, a2=a2))
    watch.append(observe())
    dirty = [o for o in watch if not ok(o)]
    return dict(name=name, rows=rows, watch=watch, dirty=dirty)


def report_paired(res, extra=None):
    print('\n--- %s ---' % res['name'])
    if extra:
        print('    %s' % extra)
    rows = res['rows']
    A = [r['a']['ms'] for r in rows]
    C = [r['c']['ms'] for r in rows]
    A2 = [r['a2']['ms'] for r in rows]
    print('    %-4s %12s %12s %12s %12s %10s'
          % ('rep', 'A ms', 'C ms', "A' ms", 'C-A ms', 'C/A'))
    for r in rows:
        print('    %-4d %12.2f %12.2f %12.2f %12.2f %10.4f'
              % (r['i'], r['a']['ms'], r['c']['ms'], r['a2']['ms'],
                 r['c']['ms'] - r['a']['ms'], r['c']['ms'] / r['a']['ms']))
    if res['dirty']:
        print('    *** WORKLOAD INVALIDATED: a competitor appeared during the '
              'run ***')
        for o in res['dirty']:
            print('        %s load %.2f competitors: %s'
                  % (o['t'], o['l1'], ', '.join(o['comp']) or 'none'))
        print('    The whole workload must be rerun from the beginning. No '
              'repetition was dropped and no number above is quoted.')
        return
    pair = [(r['c']['ms'] - r['a']['ms']) / r['a']['ms'] * 100.0 for r in rows]
    floor = [(r['a2']['ms'] - r['a']['ms']) / r['a']['ms'] * 100.0
             for r in rows]
    q = statistics.quantiles
    print('    median   A %.2f   C %.2f   A\' %.2f ms' % (med(A), med(C),
                                                          med(A2)))
    print('    min-max  A %.2f-%.2f   C %.2f-%.2f' % (min(A), max(A),
                                                      min(C), max(C)))
    if len(A) >= 4:
        print('    IQR      A %.2f   C %.2f'
              % (q(A, n=4)[2] - q(A, n=4)[0], q(C, n=4)[2] - q(C, n=4)[0]))
    print('    paired  C vs A   median %+.2f%%   min %+.2f%%   max %+.2f%%'
          % (med(pair), min(pair), max(pair)))
    print("    paired  A' vs A  median %+.2f%%   min %+.2f%%   max %+.2f%%"
          '   <- NOISE FLOOR' % (med(floor), min(floor), max(floor)))
    nf = max(abs(min(floor)), abs(max(floor)))
    print('    verdict  |effect| %.2f%% vs noise envelope %.2f%%  ->  %s'
          % (abs(med(pair)), nf,
             'SEPARATES' if abs(med(pair)) > nf
             else 'INSIDE THE NOISE, not quotable'))
    print('    non-zero exits: %s'
          % ([r['i'] for r in rows
              if r['a']['rc'] or r['c']['rc'] or r['a2']['rc']] or 'none'))
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
                [DART, '--packages=%s' % os.path.join(
                    FORK, '.dart_tool/package_config.json'),
                 os.path.join(FORK, 'pkg/vm/bin/gen_kernel.dart'),
                 '--platform', os.path.join(OUT, 'vm_platform_product.dill'),
                 '--aot', '--packages',
                 os.path.join(tool, 'package_config.json'), '-o', d,
                 'package:%s/%s' % (PKGNAME, FIXTURE)],
                capture_output=True, text=True, timeout=1800)
            assert r.returncode == 0, r.stderr[-1200:]
        out[tag] = d
    aots = {}
    for name, dill, extra in (('A', out['base'], []),
                              ('C', out['pol'],
                               ['--maot_disable_retention_roots',
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


def selected_profile(app):
    rp = os.path.join(POP, '%s.C.reg.json' % app)
    if not os.path.exists(rp):
        return ''
    j = json.load(open(rp))
    ents = j.get('entries', j if isinstance(j, list) else [])
    s = [e for e in ents if e.get('selected')]
    w = sum(1 for e in s if (e.get('indirect_call_sites_emitted') or 0) > 0)
    return ('selected %d, of which %d have >=1 #67-lowered site, %d reached '
            'only through the trampoline' % (len(s), w, len(s) - w))


def wl_hot(env, rt, aots):
    print('\n=== WORKLOAD: hot mutable instance-call loop (synthetic) ===')
    print('    in-process ns/call; hot = mutable (cell-indirect in C), '
          'cold = an identical non-mutable method in the same process')
    henv = dict(env, M5_REPS='7', M5_ITERS='20000000')
    watch = []
    ratios = {'A': [], 'C': []}
    raw = []
    print('    %-4s %10s %10s %10s %10s %10s %10s'
          % ('rep', 'A hot', 'A cold', 'C hot', 'C cold', 'A ratio',
             'C ratio'))
    for i in range(REPS):
        watch.append(observe())
        got = {}
        for arm in ('A', 'C'):
            r = subprocess.run([rt, aots[arm]], capture_output=True,
                               text=True, timeout=7200, env=henv)
            assert r.returncode == 0, r.stderr[-400:]
            kv = dict(l.split('=', 1) for l in r.stdout.splitlines()
                      if '=' in l)
            got[arm] = kv
            ratios[arm].append(float(kv['ratio']))
        raw.append(got)
        print('    %-4d %10s %10s %10s %10s %10s %10s'
              % (i, got['A']['hot.ns'], got['A']['cold.ns'],
                 got['C']['hot.ns'], got['C']['cold.ns'],
                 got['A']['ratio'], got['C']['ratio']))
    watch.append(observe())
    dirty = [o for o in watch if not ok(o)]
    if dirty:
        print('    *** WORKLOAD INVALIDATED: competitor during the run ***')
        for o in dirty:
            print('        %s load %.2f %s' % (o['t'], o['l1'],
                                               ', '.join(o['comp'])))
        return
    ra, rc = med(ratios['A']), med(ratios['C'])
    print('    median hot/cold ratio   A %.4f   C %.4f' % (ra, rc))
    print('    ratio min-max           A %.4f-%.4f   C %.4f-%.4f'
          % (min(ratios['A']), max(ratios['A']), min(ratios['C']),
             max(ratios['C'])))
    print('    C ratio / A ratio = %.4f  ->  the indirection costs %+.2f%% '
          'on this call' % (rc / ra, (rc / ra - 1) * 100.0))
    print('    noise floor: arm A ratio spread over the same run = %.2f%%'
          % ((max(ratios['A']) / min(ratios['A']) - 1) * 100.0))
    print('    absolute: C hot - C cold = %+.4f ns/call'
          % (float(raw[len(raw) // 2]['C']['hot.ns'])
             - float(raw[len(raw) // 2]['C']['cold.ns'])))
    print('    repetitions discarded: none')


def main():
    want = set(sys.argv[1:])
    env = dict(os.environ, MAOT_NAMESPACE=NS)
    rt = os.path.join(OUT, 'dartaotruntime')
    # Build before preflight: this harness's own gen_snapshot must not be
    # mistaken for another lane's.
    aots = build_fixture()
    print('=== PREFLIGHT ===')
    preflight()
    print('repetitions per workload: %d' % REPS)

    if not want or 'hot' in want:
        wl_hot(env, rt, aots)

    print('\n=== WORKLOAD: startup (process launch + snapshot load) ===')
    for app in ('smith', 'nst', 'gen_kernel', 'dart2wasm', 'analysis_server'):
        key = 'startup:%s' % app
        if want and key not in want and 'startup' not in want:
            continue
        a = os.path.join(POP, '%s.A.aot' % app)
        c = os.path.join(POP, '%s.C.aot' % app)
        if not (os.path.exists(a) and os.path.exists(c)):
            continue
        report_paired(run_paired(key, [rt, a, '--help'], [rt, c, '--help'],
                                 [rt, a, '--help'], env, REPS),
                      selected_profile(app))

    print('\n=== WORKLOAD: application work ===')
    src = os.path.join(WD, 'work.dart')
    open(src, 'w').write("void main(){print('ok');}\n")
    gk = {k: os.path.join(POP, 'gen_kernel.%s.aot' % k) for k in 'AC'}
    if (not want or 'work:gen_kernel' in want or 'work' in want) and \
            all(os.path.exists(v) for v in gk.values()):
        def job(aot, tag):
            return [rt, aot, '--platform',
                    os.path.join(OUT, 'vm_platform_product.dill'), '--aot',
                    '--packages',
                    os.path.join(FORK, '.dart_tool/package_config.json'),
                    '-o', os.path.join(WD, 'w_%s.dill' % tag), src]
        report_paired(run_paired('work: gen_kernel compiles a file',
                                 job(gk['A'], 'a'), job(gk['C'], 'c'),
                                 job(gk['A'], 'a2'), env, max(5, REPS // 2)),
                      selected_profile('gen_kernel'))
    d2w = {k: os.path.join(POP, 'dart2wasm.%s.aot' % k) for k in 'AC'}
    if (not want or 'work:dart2wasm' in want or 'work' in want) and \
            all(os.path.exists(v) for v in d2w.values()):
        def wjob(aot, tag):
            return [rt, aot, '--platform',
                    os.path.join(OUT, 'vm_platform_product.dill'),
                    '--packages',
                    os.path.join(FORK, '.dart_tool/package_config.json'),
                    src, os.path.join(WD, 'w_%s.wasm' % tag)]
        report_paired(run_paired('work: dart2wasm compiles a file',
                                 wjob(d2w['A'], 'a'), wjob(d2w['C'], 'c'),
                                 wjob(d2w['A'], 'a2'), env, max(5, REPS // 2)),
                      selected_profile('dart2wasm'))
    print('\nfinal observation: %s' % observe())


main()
