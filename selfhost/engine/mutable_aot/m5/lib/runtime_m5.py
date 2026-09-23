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


def run_balanced(name, cmd_a, cmd_c, env, n):
    """Balanced A/C order: rep 0 runs A then C, rep 1 runs C then A, and so on.

    The fixed A, C, A' order used in the first attempt gave the third position
    a systematic penalty -- the A'-vs-A median was positive in all four startup
    workloads -- so part of every C-vs-A delta was position rather than arm.
    Balancing removes the bias instead of correcting for it afterwards.
    """
    if n % 2:
        n += 1  # even, so each arm gets the first position equally often
    rows, watch = [], []
    for i in range(n):
        watch.append(observe())
        order = ('A', 'C') if i % 2 == 0 else ('C', 'A')
        cmds = {'A': cmd_a, 'C': cmd_c}
        got = {}
        for arm in order:
            got[arm] = timed(cmds[arm], env)
        rows.append(dict(i=i, order='->'.join(order), a=got['A'], c=got['C']))
    watch.append(observe())
    return dict(name=name, rows=rows, watch=watch,
                dirty=[o for o in watch if not ok(o)], kind='effect')


def run_floor(name, cmd_a, env, n):
    """The noise floor, in the same balanced shape, with A on both sides."""
    res = run_balanced(name, cmd_a, cmd_a, env, n)
    res['kind'] = 'floor'
    return res


def summarize(res):
    rows = res['rows']
    A = [r['a']['ms'] for r in rows]
    C = [r['c']['ms'] for r in rows]
    pair = [(r['c']['ms'] - r['a']['ms']) / r['a']['ms'] * 100.0 for r in rows]
    bad = [r['i'] for r in rows if r['a']['rc'] or r['c']['rc']]
    return A, C, pair, bad


def report_balanced(name, eff, floor, extra=None):
    print('\n--- %s ---' % name)
    if extra:
        print('    %s' % extra)
    for res, lab in ((eff, 'effect  A vs C'), (floor, 'floor   A vs A')):
        A, C, pair, bad = summarize(res)
        print('    %s' % lab)
        print('    %-4s %-8s %12s %12s %12s %10s'
              % ('rep', 'order', 'first ms', 'second ms', 'delta ms', 'ratio'))
        for r in res['rows']:
            first, second = ((r['a'], r['c']) if r['order'].startswith('A')
                             else (r['c'], r['a']))
            print('    %-4d %-8s %12.2f %12.2f %12.2f %10.4f'
                  % (r['i'], r['order'], first['ms'], second['ms'],
                     r['c']['ms'] - r['a']['ms'],
                     r['c']['ms'] / r['a']['ms']))
        if bad:
            print('    *** COMMAND VALIDITY FAILURE: non-zero exit in reps %s'
                  ' ***' % bad)
        print('    median   %s %.2f ms   %s %.2f ms'
              % ('A' if res is eff else 'A1', med(A),
                 'C' if res is eff else 'A2', med(C)))
        print('    paired   median %+.2f%%   min %+.2f%%   max %+.2f%%'
              % (med(pair), min(pair), max(pair)))
    if eff['dirty'] or floor['dirty']:
        print('    *** WORKLOAD INVALIDATED: a competitor appeared ***')
        for o in eff['dirty'] + floor['dirty']:
            print('        %s load %.2f %s' % (o['t'], o['l1'],
                                               ', '.join(o['comp']) or ''))
        print('    Rerun the whole workload. No repetition dropped, nothing'
              ' quoted.')
        return
    _, _, ep, ebad = summarize(eff)
    _, _, fp, fbad = summarize(floor)
    if ebad or fbad:
        print('    VERDICT: command validity failure -- not a performance'
              ' result')
        return
    env_pct = max(abs(min(fp)), abs(max(fp)))
    print('    EFFECT  C vs A  median %+.2f%%' % med(ep))
    print('    FLOOR   A vs A  median %+.2f%%   envelope %.2f%%'
          % (med(fp), env_pct))
    print('    VERDICT: %s'
          % ('separates -- |%.2f%%| exceeds the %.2f%% envelope'
             % (med(ep), env_pct) if abs(med(ep)) > env_pct
             else 'inside the noise, not quotable'))
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

    # ---- startup: only invocations that are valid, exit 0 and terminate ----
    #
    # The first attempt timed `--help` everywhere. smith and dart2wasm reject
    # it and exited non-zero, so those rows timed an argument-parser failure,
    # and analysis_server never returned at all because it is a server waiting
    # on stdin. Each command below was probed for exit status and termination
    # before being used.
    STARTUP = {
        'smith': [os.path.join(FORK, 'tools/bots/test_matrix.json')],
        'nst': ['--help'],
        'gen_kernel': ['--help'],
    }
    NOT_MEASURABLE = {
        'dart2wasm': 'no supported invocation exits 0 without compiling: -h '
                     'and --help print correct usage but exit 64. Covered by '
                     'the work workload instead.',
        'analysis_server': 'a server; it enters its stdio event loop and never '
                           'returns. --help, --version, --sdk and '
                           '--protocol were all probed; none terminates with '
                           'status 0.',
    }
    print('\n=== WORKLOAD: startup (process launch + snapshot load) ===')
    for app, why in NOT_MEASURABLE.items():
        print('\n--- startup: %s ---\n    NOT MEASURABLE WITH THIS HARNESS: %s'
              % (app, why))
    for app, args in STARTUP.items():
        key = 'startup:%s' % app
        if want and key not in want and 'startup' not in want:
            continue
        a = os.path.join(POP, '%s.A.aot' % app)
        c = os.path.join(POP, '%s.C.aot' % app)
        if not (os.path.exists(a) and os.path.exists(c)):
            continue
        ca, cc = [rt, a] + args, [rt, c] + args
        # Same semantic result under both arms, checked before timing.
        oa = subprocess.run(ca, capture_output=True, env=env, timeout=600)
        oc = subprocess.run(cc, capture_output=True, env=env, timeout=600)
        same = (oa.returncode == oc.returncode == 0 and oa.stdout == oc.stdout)
        print('\n--- %s ---' % key)
        print('    command: %s' % ' '.join(args))
        print('    A and C agree: rc %d/%d, %d/%d bytes of stdout, identical: '
              '%s' % (oa.returncode, oc.returncode, len(oa.stdout),
                      len(oc.stdout), same))
        if not same:
            print('    SKIPPED: the arms do not produce the same result, so a '
                  'timing comparison would not be like for like.')
            continue
        eff = run_balanced(key, ca, cc, env, REPS)
        floor = run_floor(key, ca, env, REPS)
        report_balanced(key, eff, floor, selected_profile(app))

    # ---- real application work ----
    print('\n=== WORKLOAD: application work ===')
    src = os.path.join(WD, 'work.dart')
    open(src, 'w').write("void main(){print('ok');}\n")
    def gk_job(aot, tag):
        return [rt, aot, '--platform',
                os.path.join(OUT, 'vm_platform_product.dill'), '--aot',
                '--packages',
                os.path.join(FORK, '.dart_tool/package_config.json'),
                '-o', os.path.join(WD, 'w_%s.dill' % tag), src]
    def d2w_job(aot, tag):
        return [rt, aot, '--packages',
                os.path.join(FORK, '.dart_tool/package_config.json'),
                src, os.path.join(WD, 'w_%s.wasm' % tag)]
    for app, mk in (('gen_kernel', gk_job), ('dart2wasm', d2w_job)):
        key = 'work:%s' % app
        if want and key not in want and 'work' not in want:
            continue
        a = os.path.join(POP, '%s.A.aot' % app)
        c = os.path.join(POP, '%s.C.aot' % app)
        if not (os.path.exists(a) and os.path.exists(c)):
            continue
        ca, cc = mk(a, 'a'), mk(c, 'c')
        oa = subprocess.run(ca, capture_output=True, env=env, timeout=3600)
        oc = subprocess.run(cc, capture_output=True, env=env, timeout=3600)
        same = oa.returncode == oc.returncode == 0
        print('\n--- %s ---' % key)
        print('    A and C agree: rc %d/%d -> %s' % (oa.returncode,
                                                     oc.returncode, same))
        if not same:
            print('    SKIPPED: %s' % (oa.stderr.decode('utf8', 'replace')
                                       [-300:] or oc.stderr.decode(
                                           'utf8', 'replace')[-300:]))
            continue
        n = max(6, REPS // 2)
        eff = run_balanced(key, ca, cc, env, n)
        floor = run_floor(key, ca, env, n)
        report_balanced(key, eff, floor, selected_profile(app))

    print('\nfinal observation: %s' % observe())


main()
