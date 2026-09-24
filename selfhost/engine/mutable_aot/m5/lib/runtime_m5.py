#!/usr/bin/env python3
"""The runtime gate: A vs C, per workload, never averaged across workloads.

Design, as authorized after the first two attempts falsified parts of it:

  * balanced arm order -- samples alternate A,C and C,A, so each arm takes the
    first position equally often. The fixed A,C,A' order gave position three a
    systematic penalty large enough to swamp the effect being measured;
  * an A-vs-A floor measured in the SAME balanced shape, in the same run. This,
    not the load average, is the measurement-quality gate;
  * the fixed 2.5 load ceiling is RETIRED. Load is recorded with every sample
    as context. It was a poor proxy: a low-load run produced 15-35% floors
    because the design was biased, while a load-7 run produced a 2% floor once
    the design was fixed;
  * startup samples BATCH N consecutive launches, because a single 15-40 ms
    launch cannot be resolved on this host -- the balanced floors were still
    9-21% once the ordering bias was removed.

Still fail-closed, with no result quoted:
  * a competing build process at any observation,
  * a non-zero exit from any invocation,
  * the two arms not producing identical output,
  * a workload interrupted part way.

Nothing is ever discarded: every sample is printed in execution order.

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
D2W_PLATFORM = ('/opt/homebrew/share/flutter/bin/cache/dart-sdk/lib/'
                '_internal/dart2wasm_platform.dill')

WORK_SAMPLES = int(os.environ.get('M5_WORK_N', '20'))
STARTUP_SAMPLES = int(os.environ.get('M5_STARTUP_N', '12'))
STARTUP_BATCH = int(os.environ.get('M5_BATCH', '100'))
PREFLIGHT_GAP = int(os.environ.get('M5_PREFLIGHT_GAP', '60'))
COMPETITORS = ('gen_snapshot', 'ninja', 'flutter_tools', 'frontend_server',
               'xcodebuild', 'clang++')


def competitors():
    found = []
    for pat in COMPETITORS:
        r = subprocess.run(['pgrep', '-f', pat], capture_output=True,
                           text=True)
        if r.returncode == 0 and r.stdout.strip():
            found.append('%s x%d' % (pat, len(r.stdout.strip().splitlines())))
    return found


def observe():
    l1, l5, l15 = os.getloadavg()
    return dict(t=time.strftime('%H:%M:%S'), l1=l1, l5=l5, l15=l15,
                comp=competitors())


def ok(o):
    """Load is CONTEXT, not a gate. A competing build still is a gate."""
    return not o['comp']


def preflight():
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
            print('\nREFUSING TO MEASURE: a competing build is running.')
            sys.exit(2)
    print('   two clean observations %ds apart; load is recorded as context, '
          'not as a gate' % PREFLIGHT_GAP)
    return obs


def med(v):
    return statistics.median(v)


def sample_once(cmd, env):
    t0 = time.perf_counter()
    r = subprocess.run(cmd, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=7200, env=env)
    return (time.perf_counter() - t0) * 1000.0, [r.returncode]


def sample_batch(cmd, env, n):
    """One sample is N consecutive launches, so per-launch jitter is small
    relative to the aggregate. Every launch's exit status is kept."""
    rcs = []
    t0 = time.perf_counter()
    for _ in range(n):
        r = subprocess.run(cmd, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=7200, env=env)
        rcs.append(r.returncode)
    return (time.perf_counter() - t0) * 1000.0, rcs


def run_balanced(name, cmd_a, cmd_c, env, n, batch=0):
    if n % 2:
        n += 1
    take = ((lambda c: sample_batch(c, env, batch)) if batch
            else (lambda c: sample_once(c, env)))
    rows, watch = [], []
    for i in range(n):
        o = observe()
        watch.append(o)
        if not ok(o):
            # Abort the moment a competing build is seen. The whole workload is
            # invalidated either way, so finishing the remaining samples only
            # spends ten minutes to reach the same verdict -- and on this rig
            # the builds arrive often enough for that to matter.
            break
        order = ('A', 'C') if i % 2 == 0 else ('C', 'A')
        cmds = {'A': cmd_a, 'C': cmd_c}
        got = {}
        for arm in order:
            ms, rcs = take(cmds[arm])
            got[arm] = dict(ms=ms, rcs=rcs)
        rows.append(dict(i=i, order='->'.join(order), a=got['A'], c=got['C'],
                         load=o['l1']))
    watch.append(observe())
    return dict(name=name, rows=rows, watch=watch,
                dirty=[o for o in watch if not ok(o)], batch=batch)


def summarize(res):
    if not res['rows']:
        return [], [], [], []
    A = [r['a']['ms'] for r in res['rows']]
    C = [r['c']['ms'] for r in res['rows']]
    pair = [(r['c']['ms'] - r['a']['ms']) / r['a']['ms'] * 100.0
            for r in res['rows']]
    bad = [r['i'] for r in res['rows']
           if any(r['a']['rcs']) or any(r['c']['rcs'])]
    return A, C, pair, bad


def report_balanced(name, eff, floor, extra=None):
    print('\n--- %s ---' % name)
    if extra:
        print('    %s' % extra)
    if eff['batch']:
        print('    each sample is %d consecutive launches' % eff['batch'])
    for res, lab, n1, n2 in ((eff, 'effect  A vs C', 'A', 'C'),
                             (floor, 'floor   A vs A', 'A1', 'A2')):
        A, C, pair, bad = summarize(res)
        print('    %s' % lab)
        print('    %-4s %-8s %12s %12s %10s %8s'
              % ('n', 'order', '%s ms' % n1, '%s ms' % n2, 'ratio', 'load'))
        for r in res['rows']:
            print('    %-4d %-8s %12.2f %12.2f %10.4f %8.1f'
                  % (r['i'], r['order'], r['a']['ms'], r['c']['ms'],
                     r['c']['ms'] / r['a']['ms'], r['load']))
        if bad:
            print('    *** COMMAND VALIDITY FAILURE: non-zero exit in samples '
                  '%s ***' % bad)
        if not A:
            print('    no samples completed before the workload was '
                  'invalidated')
            continue
        print('    median   %s %.2f   %s %.2f ms' % (n1, med(A), n2, med(C)))
        print('    paired   median %+.2f%%   min %+.2f%%   max %+.2f%%'
              % (med(pair), min(pair), max(pair)))
        pos = sum(1 for v in pair if v > 0)
        print('    direction %d of %d pairs positive, %d negative'
              % (pos, len(pair), len(pair) - pos))
    if eff['dirty'] or floor['dirty']:
        print('    *** WORKLOAD INVALIDATED: a competing build appeared ***')
        for o in eff['dirty'] + floor['dirty']:
            print('        %s %s' % (o['t'], ', '.join(o['comp'])))
        print('    Rerun the whole workload. Nothing dropped, nothing quoted.')
        return
    _, _, ep, ebad = summarize(eff)
    _, _, fp, fbad = summarize(floor)
    if ebad or fbad:
        print('    VERDICT: command validity failure -- not a performance '
              'result')
        return
    env_pct = max(abs(min(fp)), abs(max(fp)))
    print('    EFFECT  C vs A  median %+.2f%%  (min %+.2f%%, max %+.2f%%)'
          % (med(ep), min(ep), max(ep)))
    print('    FLOOR   A vs A  median %+.2f%%  envelope %.2f%%'
          % (med(fp), env_pct))
    print('    VERDICT: %s'
          % ('separates -- |%.2f%%| exceeds the %.2f%% envelope'
             % (med(ep), env_pct) if abs(med(ep)) > env_pct
             else 'inside the noise, not quotable'))
    print('    samples discarded: none')


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


def agree(ca, cc, env, timeout=3600):
    oa = subprocess.run(ca, capture_output=True, env=env, timeout=timeout)
    oc = subprocess.run(cc, capture_output=True, env=env, timeout=timeout)
    same = oa.returncode == oc.returncode == 0 and oa.stdout == oc.stdout
    print('    A and C agree: rc %d/%d, %d/%d bytes of stdout, identical: %s'
          % (oa.returncode, oc.returncode, len(oa.stdout), len(oc.stdout),
             same))
    return same


def main():
    want = set(sys.argv[1:])
    env = dict(os.environ, MAOT_NAMESPACE=NS)
    rt = os.path.join(OUT, 'dartaotruntime')
    print('=== PREFLIGHT ===')
    preflight()
    print('work samples %d, startup samples %d x %d launches'
          % (WORK_SAMPLES, STARTUP_SAMPLES, STARTUP_BATCH))

    STARTUP = {
        'smith': [os.path.join(FORK, 'tools/bots/test_matrix.json')],
        'nst': ['--help'],
        'gen_kernel': ['--help'],
    }
    NOT_MEASURABLE = {
        'dart2wasm': 'no supported invocation exits 0 without compiling; '
                     'covered by the work workload',
        'analysis_server': 'a server -- enters its stdio event loop and never '
                           'returns; --help, --version, --sdk and --protocol '
                           'were all probed',
    }
    print('\n=== WORKLOAD: startup, batched ===')
    for app, why in NOT_MEASURABLE.items():
        print('\n--- startup: %s ---\n    NOT MEASURABLE WITH THIS HARNESS: %s'
              % (app, why))
    for app, args in STARTUP.items():
        key = 'startup:%s' % app
        if want and key not in want and 'startup' not in want:
            continue
        a, c = (os.path.join(POP, '%s.%s.aot' % (app, x)) for x in 'AC')
        if not (os.path.exists(a) and os.path.exists(c)):
            continue
        ca, cc = [rt, a] + args, [rt, c] + args
        print('\n--- %s ---\n    command: %s' % (key, ' '.join(args)))
        if not agree(ca, cc, env):
            print('    SKIPPED: the arms do not produce the same result.')
            continue
        eff = run_balanced(key, ca, cc, env, STARTUP_SAMPLES, STARTUP_BATCH)
        flo = run_balanced(key, ca, ca, env, STARTUP_SAMPLES, STARTUP_BATCH)
        report_balanced(key, eff, flo, selected_profile(app))

    print('\n=== WORKLOAD: application work ===')
    src = os.path.join(WD, 'work.dart')
    open(src, 'w').write("void main(){print('ok');}\n")
    pkgs = os.path.join(FORK, '.dart_tool/package_config.json')

    def gk_job(aot, tag):
        return [rt, aot, '--platform',
                os.path.join(OUT, 'vm_platform_product.dill'), '--aot',
                '--packages', pkgs, '-o',
                os.path.join(WD, 'w_%s.dill' % tag), src]

    def d2w_job(aot, tag):
        # --platform is required and is the WASM platform dill, not the VM one.
        return [rt, aot, '--platform=%s' % D2W_PLATFORM,
                '--packages=%s' % pkgs, src,
                os.path.join(WD, 'w_%s.wasm' % tag)]

    for app, mk in (('gen_kernel', gk_job), ('dart2wasm', d2w_job)):
        key = 'work:%s' % app
        if want and key not in want and 'work' not in want:
            continue
        a, c = (os.path.join(POP, '%s.%s.aot' % (app, x)) for x in 'AC')
        if not (os.path.exists(a) and os.path.exists(c)):
            continue
        ca, cc = mk(a, 'a'), mk(c, 'c')
        print('\n--- %s ---' % key)
        if not agree(ca, cc, env):
            print('    SKIPPED: the arms do not produce the same result.')
            continue
        eff = run_balanced(key, ca, cc, env, WORK_SAMPLES)
        flo = run_balanced(key, ca, ca, env, WORK_SAMPLES)
        report_balanced(key, eff, flo, selected_profile(app))

    print('\nfinal observation: %s' % observe())


main()
