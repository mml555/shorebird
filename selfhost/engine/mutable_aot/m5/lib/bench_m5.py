#!/usr/bin/env python3
"""Runtime-cost gate: A vs C on ARM64.

This rig has already produced one unusable timing result -- two arms doing
identical work differed by 75% -- so the harness measures its own
discriminating power BEFORE reporting any A-vs-C delta:

  * the noise floor is A against a SECOND, byte-different build of A, so
    build-to-build and run-to-run variance are both in it;
  * the hot-loop statistic is a RATIO taken inside one process between a
    mutable call and an identical non-mutable call, which cancels machine
    state entirely;
  * every raw number is printed. Nothing is tuned to make a delta small.

Three workloads: startup, an application workload, and a deliberately hot
mutable instance-call loop.
"""
import json, os, re, shutil, statistics, subprocess, sys, tempfile, time

FORK = '/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT = '/Volumes/build/route-b/flutter/engine/src/out/maot_host'
DART = '/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart'
M5 = os.path.dirname(os.path.abspath(__file__))
NS = 'ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
BASE = ('/private/tmp/claude-501/-Users-mendell-shorebird/'
        '541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad')
WD = os.path.join(BASE, 'bench')
STAGE43 = os.path.join(BASE, 'stage43')
os.makedirs(WD, exist_ok=True)
PKGNAME = 'm5bench'
FIXTURE = 'fixture_m5_bench.dart'


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
    return out


def snapshot(name, dill, extra):
    aot = os.path.join(WD, '%s.aot' % name)
    r = subprocess.run(
        [os.path.join(OUT, 'gen_snapshot'), '--snapshot_kind=app-aot-elf',
         '--elf=%s' % aot, '--maot_namespace=%s' % NS] + extra + [dill],
        capture_output=True, text=True, timeout=3600)
    assert r.returncode == 0, r.stderr[-800:]
    return aot


def run_bench(aot, reps, iters):
    r = subprocess.run([os.path.join(OUT, 'dartaotruntime'), aot],
                       capture_output=True, text=True, timeout=3600,
                       env=dict(os.environ, MAOT_NAMESPACE=NS,
                                M5_REPS=str(reps), M5_ITERS=str(iters)))
    assert r.returncode == 0, r.stderr[-600:]
    kv = {}
    for l in r.stdout.splitlines():
        if '=' in l:
            a, _, b = l.partition('=')
            kv[a] = b
    return kv


def wall(cmd, n, env=None):
    """n wall-clock samples of cmd, in milliseconds."""
    out = []
    for _ in range(n):
        t0 = time.perf_counter()
        subprocess.run(cmd, capture_output=True, timeout=3600,
                       env=env or os.environ)
        out.append((time.perf_counter() - t0) * 1000.0)
    out.sort()
    return out


def stat(v):
    return (statistics.median(v), min(v), max(v))


def main():
    dills = build_fixture()
    print('=== artifacts ===')
    arms = {
        'A':  snapshot('bench_A', dills['base'], []),
        "A'": snapshot('bench_A2', dills['base'], []),
        'C':  snapshot('bench_C', dills['pol'],
                       ['--maot_disable_retention_roots',
                        '--maot_install_trampolines']),
    }
    for k, v in arms.items():
        print('   %-3s %s  %d bytes' % (k, os.path.basename(v),
                                        os.path.getsize(v)))
    same = (open(arms['A'], 'rb').read() == open(arms["A'"], 'rb').read())
    print("   A and A' are byte-identical: %s" % same)

    reps = int(os.environ.get('M5_REPS', '9'))
    iters = int(os.environ.get('M5_ITERS', '20000000'))
    print('\n=== 1. HOT MUTABLE INSTANCE-CALL LOOP (in-process) ===')
    print('%-4s %12s %12s %10s %12s %12s'
          % ('arm', 'hot ns/call', 'cold ns/call', 'hot/cold', 'hot min-max',
             'cold min-max'))
    res = {}
    for k in ('A', "A'", 'C'):
        kv = run_bench(arms[k], reps, iters)
        res[k] = kv
        print('%-4s %12s %12s %10s %12s %12s'
              % (k, kv['hot.ns'], kv['cold.ns'], kv['ratio'],
                 '%s-%s' % (kv['hot.min'], kv['hot.max']),
                 '%s-%s' % (kv['cold.min'], kv['cold.max'])))
    ra, ra2, rc = (float(res[k]['ratio']) for k in ('A', "A'", 'C'))
    noise = abs(ra2 - ra) / ra * 100.0
    effect = (rc - ra) / ra * 100.0
    print('\n   noise floor  |ratio(A\') - ratio(A)| / ratio(A) = %.2f%%' % noise)
    print('   effect       |ratio(C)  - ratio(A)| / ratio(A) = %+.2f%%' % effect)
    print('   absolute cost of the indirection = %+.4f ns per call'
          % (float(res['C']['hot.ns']) - float(res['C']['cold.ns'])))
    print('   %s' % ('DISCRIMINATES: the effect is %.1fx the noise floor'
                     % (abs(effect) / noise) if noise > 0 and
                     abs(effect) > 3 * noise else
                     'DOES NOT DISCRIMINATE at this sample size'))

    print('\n=== 2. STARTUP (process launch + snapshot load, gen_kernel arms) ===')
    n = int(os.environ.get('M5_WALL_N', '15'))
    gk = {}
    for k, f in (('A', 'A.aot'), ('C', 'C.aot')):
        p = os.path.join(STAGE43, f)
        gk[k] = p if os.path.exists(p) else None
    if all(gk.values()):
        env = dict(os.environ, MAOT_NAMESPACE=NS)
        s = {}
        for k in ('A', 'C'):
            s[k] = wall([os.path.join(OUT, 'dartaotruntime'), gk[k], '--help'],
                        n, env)
        s["A'"] = wall([os.path.join(OUT, 'dartaotruntime'), gk['A'], '--help'],
                       n, env)
        print('%-4s %10s %10s %10s' % ('arm', 'median ms', 'min', 'max'))
        for k in ('A', "A'", 'C'):
            m, lo, hi = stat(s[k])
            print('%-4s %10.2f %10.2f %10.2f' % (k, m, lo, hi))
        ma, ma2, mc = (statistics.median(s[k]) for k in ('A', "A'", 'C'))
        nf = abs(ma2 - ma) / ma * 100.0
        ef = (mc - ma) / ma * 100.0
        print('   noise floor (A vs A, same binary) = %.2f%%' % nf)
        print('   effect      (C vs A)              = %+.2f%%' % ef)
        print('   %s' % ('DISCRIMINATES' if nf > 0 and abs(ef) > 3 * nf
                         else 'DOES NOT DISCRIMINATE at this sample size'))
    else:
        print('   gen_kernel arms not present; skipped')

    print('\n=== 3. APPLICATION WORKLOAD (gen_kernel compiles a file) ===')
    if all(gk.values()):
        src = os.path.join(WD, 'work.dart')
        open(src, 'w').write("void main(){print('ok');}\n")
        env = dict(os.environ, MAOT_NAMESPACE=NS)
        def job(aot, i):
            return [os.path.join(OUT, 'dartaotruntime'), aot, '--platform',
                    os.path.join(OUT, 'vm_platform_product.dill'), '--aot',
                    '--packages', os.path.join(FORK, '.dart_tool/package_config.json'),
                    '-o', os.path.join(WD, 'w_%s.dill' % i), src]
        m = int(os.environ.get('M5_WORK_N', '7'))
        w = {'A': wall(job(gk['A'], 'a'), m, env),
             "A'": wall(job(gk['A'], 'a2'), m, env),
             'C': wall(job(gk['C'], 'c'), m, env)}
        print('%-4s %10s %10s %10s' % ('arm', 'median ms', 'min', 'max'))
        for k in ('A', "A'", 'C'):
            md, lo, hi = stat(w[k])
            print('%-4s %10.1f %10.1f %10.1f' % (k, md, lo, hi))
        ma, ma2, mc = (statistics.median(w[k]) for k in ('A', "A'", 'C'))
        nf = abs(ma2 - ma) / ma * 100.0
        ef = (mc - ma) / ma * 100.0
        print('   noise floor (A vs A, same binary) = %.2f%%' % nf)
        print('   effect      (C vs A)              = %+.2f%%' % ef)
        print('   %s' % ('DISCRIMINATES' if nf > 0 and abs(ef) > 3 * nf
                         else 'DOES NOT DISCRIMINATE at this sample size'))
    else:
        print('   gen_kernel arms not present; skipped')


main()
