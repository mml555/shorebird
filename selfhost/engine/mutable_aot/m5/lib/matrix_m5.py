#!/usr/bin/env python3
"""#69 instance-member matrix with mechanical acceptance.

Each row runs a real production StageReplacement at V2 and V3 against a warmed
site and is judged by comparing ROUTING IDENTITIES across the baseline/V2/V3
registry dumps, not by reading behavior. Behavior OLD->NEW->NEW2 is necessary
and explicitly not sufficient: a row where any frozen identity moved fails
even though its behavior looks right.
"""
import json, os, shutil, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from judge_m5 import judge

FORK = '/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT = '/Volumes/build/route-b/flutter/engine/src/out/maot_host'
DART = '/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart'
M5 = '/Users/mendell/shorebird/selfhost/engine/mutable_aot/m5/lib'
SCRATCH = os.path.dirname(os.path.abspath(__file__))
NS = 'ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'

# (row, fixture, package, subject decl suffix, unrelated decl suffix)
SUBJECTS = [
    ('method',   'fixture_m5_prod.dart',     'm5prod',     'cls:Alpha::method:v',    'cls:Beta::method:v'),
    ('getter',   'fixture_m5_getter.dart',   'm5getter',   'cls:Alpha::get:v',       'cls:Beta::get:v'),
    ('setter',   'fixture_m5_setter.dart',   'm5setter',   'cls:Alpha::set:v',       'cls:Beta::set:v'),
    ('operator', 'fixture_m5_operator.dart', 'm5operator', 'cls:Alpha::op:+',        'cls:Beta::op:+'),
    ('callable', 'fixture_m5_callable.dart', 'm5callable', 'cls:Alpha::method:call', 'cls:Beta::method:call'),
    ('tearoff',  'fixture_m5_tearoff.dart',  'm5tearoff',  'cls:Alpha::method:v',    'cls:Beta::method:v'),
]
# The tear-off call site is a CLOSURE call, not a receiver dispatch, so the
# megamorphic inspector reports on the fixture's direct dynamic call instead.
# Reading that as tear-off evidence would be attributing one site's freeze to
# a different site, so the cache checks are withheld for this row and the
# tear-off arms carry it instead.
NO_SITE_EVIDENCE = {'tearoff'}

FROZEN = ['id_declaration_function', 'id_declaration_current_code',
          'id_trampoline_code', 'id_trampoline_entry', 'id_dispatch_cell',
          'id_release_body']
MOVING = ['id_cell_impl_function', 'id_cell_impl_code',
          'id_pinned_current_body']


def entry_for(path, suffix):
    if not os.path.exists(path):
        return None
    j = json.load(open(path))
    ents = j.get('entries', j if isinstance(j, list) else [])
    for e in ents:
        if e.get('declaration_id', '').endswith('::' + suffix):
            return e
    return None


def build_and_run(tag, fixture, pkg):
    wd = tempfile.mkdtemp(prefix=f'v5_{tag}_')
    lib = os.path.join(wd, 'pkg', 'lib'); os.makedirs(lib)
    shutil.copy(os.path.join(M5, fixture), os.path.join(lib, fixture))
    tool = os.path.join(wd, 'pkg', '.dart_tool'); os.makedirs(tool)
    json.dump({'configVersion': 2, 'packages': [{
        'name': pkg, 'rootUri': f'file://{os.path.join(wd, "pkg")}/',
        'packageUri': 'lib/', 'languageVersion': '3.9'}]},
        open(os.path.join(tool, 'package_config.json'), 'w'))
    dill = os.path.join(wd, 'app.dill')
    k = subprocess.run(
        [DART, f'--packages={os.path.join(FORK, ".dart_tool/package_config.json")}',
         os.path.join(FORK, 'pkg/vm/bin/gen_kernel.dart'),
         '--platform', os.path.join(OUT, 'vm_platform_product.dill'),
         '--aot', '--packages', os.path.join(tool, 'package_config.json'),
         '-o', dill, f'package:{pkg}/{fixture}'],
        capture_output=True, text=True, timeout=1800)
    if k.returncode != 0:
        return None, f'KERNEL {k.stderr.strip().splitlines()[-1][:140]}', {}, wd
    aot = os.path.join(wd, 'app.aot')
    s = subprocess.run(
        [os.path.join(OUT, 'gen_snapshot'), '--snapshot_kind=app-aot-elf',
         f'--elf={aot}', f'--maot_namespace={NS}', '--maot_install_trampolines',
         f'--maot_dump_registry_precompile={os.path.join(wd, "pre.json")}', dill],
        capture_output=True, text=True, timeout=1800)
    if s.returncode != 0:
        sig = [l.strip() for l in s.stderr.splitlines() if 'si_addr' in l]
        return None, f'SNAPSHOT rc={s.returncode} {sig[:1]}', {}, wd
    dumps = os.path.join(wd, 'dumps'); os.makedirs(dumps, exist_ok=True)
    r = subprocess.run([os.path.join(OUT, 'dartaotruntime'), aot],
                       capture_output=True, text=True, timeout=900,
                       env=dict(os.environ, MAOT_NAMESPACE=NS,
                                MAOT_DUMP_DIR=dumps,
                                M5_SITE_REPORT=os.path.join(wd, 'site.txt')))
    kv = {}
    for line in r.stdout.splitlines():
        if '=' in line:
            k2, _, v = line.partition('=')
            kv[k2] = v
    if r.returncode != 0:
        return None, f'RUN rc={r.returncode} {r.stderr.strip()[-160:]}', kv, wd
    return dumps, None, kv, wd


results = []
for tag, fixture, pkg, subj, other in SUBJECTS:
    dumps, err, kv, wd = build_and_run(tag, fixture, pkg)
    if err:
        print(f'{tag:9s} BLOCKED  {err}')
        results.append((tag, 'BLOCKED', [err])); continue

    stages = {n: entry_for(os.path.join(dumps, f'registry_{n}.json'), subj)
              for n in ('before', 'v2', 'v3')}
    beta = {n: entry_for(os.path.join(dumps, f'registry_{n}.json'), other)
            for n in ('before', 'v2', 'v3')}
    if not all(stages.values()):
        missing = [n for n, v in stages.items() if not v]
        print(f'{tag:9s} BLOCKED  no dump entry for {subj} at {missing}')
        results.append((tag, 'BLOCKED', [f'missing dumps {missing}'])); continue

    site_path = os.path.join(wd, 'site.txt')
    site_report = (open(site_path, errors='replace').read()
                   if os.path.exists(site_path) else None)
    json.dump({'stages': stages, 'beta': beta, 'kv': kv,
               'site_report': site_report},
              open(os.path.join(SCRATCH, f'evidence_{tag}.json'), 'w'), indent=1)
    if tag in NO_SITE_EVIDENCE:
        site_report = None
    n_checks, fails = judge(stages, beta, kv, site_report)
    verdict = 'PASS' if not fails else 'FAIL'
    results.append((tag, verdict, fails))
    print(f'{tag:9s} {verdict}  ({n_checks} checks, {len(fails)} failed)')
    for f in fails:
        print(f'            FAILED: {f}')

print('\n=== matrix ===')
for tag, verdict, fails in results:
    print(f'  {tag:9s} {verdict}')
json.dump([{'row': t, 'verdict': v, 'failures': f} for t, v, f in results],
          open(os.path.join(SCRATCH, 'matrix_verdict.json'), 'w'), indent=1)
