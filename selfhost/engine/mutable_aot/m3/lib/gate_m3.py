#!/usr/bin/env python3
"""MAOT-3 (#67) -- run the vertical slice and derive the verdict.

Every run drives the real chain: source -> Kernel -> gen_snapshot ->
dartaotruntime, with installation happening inside the running process. The
snapshot is hashed before and after the run, so "no recompile between OLD and
NEW" is a measurement rather than an assurance.

usage: gate_m3.py <m3-dir> <out.json>
"""

import datetime
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verdict_m3 as V          # noqa: E402

FORK = os.environ.get('MAOT_FORK',
                      '/Volumes/build/route-b/flutter/engine/src/flutter/'
                      'third_party/dart')
OUT = os.environ.get('MAOT_OUT',
                     '/Volumes/build/route-b/flutter/engine/src/out/maot_host')
DART = os.environ.get(
    'DART', '/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart')
NAMESPACE = os.environ.get(
    'MAOT_NAMESPACE',
    'ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e')

MAOT_CXX_SOURCES = (
    'runtime/vm/maot_registry.cc', 'runtime/vm/maot_registry.h',
    'runtime/vm/kernel_loader.cc', 'runtime/vm/object_store.h',
    'runtime/vm/dart.cc',
    'runtime/vm/compiler/aot/precompiler.cc',
    'runtime/vm/compiler/aot/precompiler.h',
    'runtime/vm/compiler/backend/flow_graph_compiler_arm64.cc',
    'runtime/vm/compiler/backend/inliner.cc',
    'runtime/vm/compiler/frontend/kernel_translation_helper.cc',
    'runtime/vm/compiler/frontend/kernel_translation_helper.h',
)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b''):
            h.update(chunk)
    return h.hexdigest()


def git(root, *args):
    out = subprocess.run(['git', '-C', root] + list(args),
                         capture_output=True, text=True, timeout=60)
    return out.stdout.strip() if out.returncode == 0 else None


class Build:
    """One release build of the fixture, in its own directory."""

    def __init__(self, workdir, source, name='fixture_m3.dart'):
        self.dir = workdir
        lib = os.path.join(workdir, 'pkg', 'lib')
        os.makedirs(lib, exist_ok=True)
        self.entry = name
        with open(os.path.join(lib, name), 'w') as fh:
            fh.write(source)
        tool = os.path.join(workdir, 'pkg', '.dart_tool')
        os.makedirs(tool, exist_ok=True)
        with open(os.path.join(tool, 'package_config.json'), 'w') as fh:
            json.dump({'configVersion': 2, 'packages': [{
                'name': 'm3app',
                'rootUri': f'file://{os.path.join(workdir, "pkg")}/',
                'packageUri': 'lib/', 'languageVersion': '3.9'}]}, fh)
        self.pkg_config = os.path.join(tool, 'package_config.json')
        self.dill = os.path.join(workdir, 'app.dill')
        self.aot = os.path.join(workdir, 'app.aot')
        self.dumps = os.path.join(workdir, 'dumps')
        os.makedirs(self.dumps, exist_ok=True)

    def kernel(self):
        return subprocess.run(
            [DART,
             f'--packages={os.path.join(FORK, ".dart_tool/package_config.json")}',
             os.path.join(FORK, 'pkg/vm/bin/gen_kernel.dart'),
             '--platform', os.path.join(OUT, 'vm_platform_product.dill'),
             '--aot', '--packages', self.pkg_config,
             '-o', self.dill, f'package:m3app/{self.entry}'],
            capture_output=True, text=True, timeout=1800)

    def snapshot(self, extra=()):
        return subprocess.run(
            [os.path.join(OUT, 'gen_snapshot'), '--snapshot_kind=app-aot-elf',
             f'--elf={self.aot}', f'--maot_namespace={NAMESPACE}']
            + list(extra) + [self.dill],
            capture_output=True, text=True, timeout=1800)

    def run(self, dump=True, env_extra=None):
        env = dict(os.environ, MAOT_NAMESPACE=NAMESPACE)
        if dump:
            env['MAOT_DUMP_DIR'] = self.dumps
        if env_extra:
            env.update(env_extra)
        return subprocess.run([os.path.join(OUT, 'dartaotruntime'), self.aot],
                              capture_output=True, text=True, timeout=600,
                              env=env)


def parse_calls(stdout):
    """key=value lines from the fixture, ints where they are ints."""
    out = {}
    for line in stdout.splitlines():
        if '=' not in line:
            continue
        k, _, v = line.partition('=')
        k, v = k.strip(), v.strip()
        try:
            out[k] = int(v)
        except ValueError:
            out[k] = v
    return out


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    m3_dir, out_path = os.path.abspath(argv[1]), argv[2]
    repo = os.path.abspath(os.path.join(m3_dir, '..', '..', '..', '..'))
    run_id = datetime.datetime.now(datetime.timezone.utc).strftime(
        '%Y-%m-%dT%H:%M:%SZ')
    findings, arms = [], []
    observations = {'expected_namespace': NAMESPACE}

    def finding(code, message):
        findings.append({'code': code, 'severity': 'blocking',
                         'message': message})

    def arm(aid, why, ok, observed, flipped=None):
        rec = {'id': aid, 'kind': V.BANK[aid][0],
               'description': V.BANK[aid][1], 'why': why,
               'result': 'pass' if ok else 'FAIL', 'observed': observed}
        if flipped is not None:
            rec['verdict_under_defect'] = flipped
        arms.append(rec)

    fixture = open(os.path.join(m3_dir, 'lib', 'fixture_m3.dart')).read()

    if not all(os.path.exists(p) for p in
               (FORK, DART, os.path.join(OUT, 'gen_snapshot'),
                os.path.join(OUT, 'dartaotruntime'))):
        finding('TOOLCHAIN_UNAVAILABLE', 'the fork or the built toolchain is '
                                         'not reachable')
    if not os.path.exists(os.path.join(FORK, 'runtime/vm/maot_registry.cc')):
        finding('FORK_NOT_ON_MAOT_REVISION',
                f'{FORK} has no Mutable-AOT sources; the shared rig is handed '
                f'back. See m2/rescued/R3_STATE_BEFORE_BORROW.txt.')

    work = os.path.join('/tmp', f'maot_m3_{os.getpid()}')
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    registry_before, registry_after = {}, {}
    try:
        if findings:
            raise SystemExit(0)

        # ---------------- the release run ----------------
        main_build = Build(os.path.join(work, 'release'), fixture)
        k = main_build.kernel()
        if k.returncode != 0:
            finding('KERNEL_FAILED', (k.stderr or k.stdout)[-600:])
        s = main_build.snapshot(extra=['--maot_trace_registration'])
        if s.returncode != 0:
            finding('SNAPSHOT_FAILED', (s.stderr or s.stdout)[-600:])
        emitted = [l for l in (s.stderr + s.stdout).splitlines()
                   if 'indirect call site' in l]
        observations['indirect_call_site_trace_lines'] = len(emitted)

        # Hash the snapshot on both sides of the run. "No recompile between
        # OLD and NEW" then rests on a measurement of the artifact rather than
        # on the harness promising it did not rebuild.
        observations['snapshot_sha256_before'] = sha256_file(main_build.aot)
        r = main_build.run()
        observations['snapshot_sha256_after'] = sha256_file(main_build.aot)
        if r.returncode != 0:
            finding('RUNTIME_FAILED', (r.stderr or r.stdout)[-600:])
        calls = parse_calls(r.stdout)
        observations['calls'] = calls
        observations['runtime_stderr_tail'] = (r.stderr or '')[-300:]
        for name, key in (('registry_before.json', 'registry_before'),
                          ('registry_after.json', 'registry_after')):
            p = os.path.join(main_build.dumps, name)
            if os.path.exists(p):
                observations[key] = json.load(open(p))
        registry_before = observations.get('registry_before', {})
        registry_after = observations.get('registry_after', {})

        def perturbed(**over):
            po = dict(observations)
            po.update(over)
            return V.evaluate(po, [])

        def leaf(reg, suffix):
            for e in (reg or {}).get('entries', []):
                if e['declaration_id'].endswith(suffix):
                    return e
            return None

        # ---------------- G01: bypass the cell ----------------
        bypass = Build(os.path.join(work, 'bypass'), fixture)
        bypass.kernel()
        bypass.snapshot(extra=['--maot_disable_call_indirection'])
        rb = bypass.run()
        cb = parse_calls(rb.stdout)
        vb = perturbed(calls=cb,
                       registry_after=json.load(open(os.path.join(
                           bypass.dumps, 'registry_after.json')))
                       if os.path.exists(os.path.join(
                           bypass.dumps, 'registry_after.json')) else {})
        arm('G01', 'a call permanently bound to the release implementation is '
                   'the failure this whole issue exists to rule out, and the '
                   'descriptor still advances while it happens',
            cb.get('top.call.1') == 'OLD' and cb.get('top.version.1') ==
            'PATCH_CODE:v2'
            and vb['direct_static_replacement'] == 'NOT_ESTABLISHED',
            f"without the indirection: top.call.1={cb.get('top.call.1')} "
            f"while the descriptor reports {cb.get('top.version.1')}",
            vb['direct_static_replacement'])

        # G11 rides on the same build: the strings could have matched while no
        # call site existed, so the path evidence has to be what refuses it.
        e_by = leaf(vb.get('conditions') and None, '') if False else None
        bypass_reg = os.path.join(bypass.dumps, 'registry_after.json')
        bypass_sites = None
        if os.path.exists(bypass_reg):
            e = leaf(json.load(open(bypass_reg)), '::fn:work')
            bypass_sites = e and e.get('indirect_call_sites_emitted')
        arm('G11', 'output strings are not evidence of a path; a run with no '
                   'emitted indirect call site must be refused on the path '
                   'evidence alone',
            bypass_sites == 0
            and not vb['conditions']['call_sites_traverse_the_mechanism'],
            f'the bypass build emitted {bypass_sites} indirect call sites for '
            f'fn:work, and the condition reads '
            f"{vb['conditions']['call_sites_traverse_the_mechanism']}")

        # ---------------- G02: constant-folded result ----------------
        # Not hypothetical: this is what the first working build did. The
        # fixture's bodies return constants, so a folded result is exactly the
        # release answer with every call still made.
        e_main = leaf(registry_after, '::fn:work')
        folded = dict(calls)
        folded.update({'top.call.1': 'OLD', 'top.call.2': 'OLD',
                       'top.call.1.repeat': 'OLD', 'top.call.final': 'OLD'})
        v02 = perturbed(calls=folded)
        arm('G02', 'the call is made, reaches the cell, and the caller still '
                   'uses the release answer because the RESULT was folded',
            calls.get('top.call.1') == 'NEW'
            and (e_main or {}).get('indirect_call_sites_emitted', 0) > 0
            and v02['direct_static_replacement'] == 'NOT_ESTABLISHED',
            f"{(e_main or {}).get('indirect_call_sites_emitted')} call sites "
            f"emitted and the result observed is "
            f"{calls.get('top.call.1')}; with the result folded back to OLD "
            f"the verdict is {v02['direct_static_replacement']}",
            v02['direct_static_replacement'])

        # ---------------- G03: inlined away ----------------
        no_sites = json.loads(json.dumps(registry_after))
        for e in no_sites.get('entries', []):
            e['indirect_call_sites_emitted'] = 0
        v03 = perturbed(registry_after=no_sites)
        arm('G03', 'an inlined copy of a selected declaration is a caller that '
                   'never reaches the cell',
            not v03['conditions']['call_sites_traverse_the_mechanism']
            and v03['direct_static_replacement'] == 'NOT_ESTABLISHED',
            'with every emitted call site removed the path condition reads '
            f"{v03['conditions']['call_sites_traverse_the_mechanism']}",
            v03['direct_static_replacement'])

        # ---------------- G04..G08: refusals, measured in-process ----------
        arm('G04', 'a version bump with no implementation change is not a '
                   'replacement',
            calls.get('refuse.version.not.advancing') == -3,
            f"non-advancing version returned "
            f"{calls.get('refuse.version.not.advancing')} (-3 = refused by "
            f"StageReplacement)")
        same_impl = dict(calls)
        same_impl['top.call.1'] = 'OLD'
        v05 = perturbed(calls=same_impl)
        arm('G05', 'an implementation change the version does not record leaves '
                   'the evidence describing a program that is not running',
            calls.get('top.version.1') == 'PATCH_CODE:v2'
            and v05['direct_static_replacement'] == 'NOT_ESTABLISHED',
            f"version and body move together: {calls.get('top.version.1')} "
            f"with {calls.get('top.call.1')}",
            v05['direct_static_replacement'])
        arm('G06', 'a patch built against another release must not bind here',
            calls.get('refuse.wrong.namespace') == -3
            and calls.get('top.call.after_refusals') == 'OLD',
            f"wrong namespace returned {calls.get('refuse.wrong.namespace')} "
            f"and the call still returns "
            f"{calls.get('top.call.after_refusals')}")
        arm('G07', 'an unknown declaration must be refused, never created',
            calls.get('refuse.unknown.id') == -1,
            f"unknown id returned {calls.get('refuse.unknown.id')} "
            f"(-1 = not found)")
        arm('G08', 'an incompatible ABI must be refused before anything is '
                   'visible',
            calls.get('refuse.abi.mismatch') == -3
            and calls.get('top.version.after_refusals') == 'AOT:v1',
            f"ABI mismatch returned {calls.get('refuse.abi.mismatch')} and the "
            f"descriptor is still {calls.get('top.version.after_refusals')}")

        # ---------------- G09: one arm cannot stand in for the other -------
        only_top = dict(calls)
        only_top.update({'static.call.1': 'OLD-STATIC',
                         'static.call.2': 'OLD-STATIC'})
        v09 = perturbed(calls=only_top)
        arm('G09', 'top-level and static are independent arms; proving one '
                   'cannot prove the other',
            calls.get('static.call.1') == 'NEW-STATIC'
            and not v09['conditions']['static_replacement_observed']
            and v09['direct_static_replacement'] == 'NOT_ESTABLISHED',
            'with the static arm left at its release answer the verdict is '
            f"{v09['direct_static_replacement']}",
            v09['direct_static_replacement'])

        # ---------------- G10: restart or recompile ----------------
        v10 = perturbed(snapshot_sha256_after='0' * 64)
        v10b = perturbed(calls=dict(calls, **{'process.pid.final':
                                              (calls.get('process.pid') or 0)
                                              + 1}))
        arm('G10', 'a rebuilt snapshot or a second process would make the '
                   'whole observation meaningless',
            calls.get('process.pid') == calls.get('process.pid.final')
            and observations['snapshot_sha256_before'] ==
            observations['snapshot_sha256_after']
            and not v10['conditions']['no_restart_or_recompile']
            and not v10b['conditions']['no_restart_or_recompile'],
            f"one pid ({calls.get('process.pid')}) and one snapshot "
            f"({observations['snapshot_sha256_before'][:12]}...) across the "
            f"whole run; a changed hash or a changed pid each fail the "
            f"condition")

        # ---------------- measurements ----------------
        control_src = fixture.replace("@pragma('maot:mutable')\n", '')
        control = Build(os.path.join(work, 'control'), control_src)
        control.kernel()
        cs = control.snapshot()
        control_ok = cs.returncode == 0 and os.path.exists(control.aot)

        def median_ms(build, n=5):
            xs = []
            for _ in range(n):
                t = time.perf_counter()
                build.run(dump=False)
                xs.append((time.perf_counter() - t) * 1000.0)
            xs.sort()
            return round(xs[len(xs) // 2], 2)

        # The bypass build is the control that isolates the call-site cost:
        # identical source, identical selection, identical retained bodies,
        # differing only in whether the indirection is emitted.
        bypass_bytes = (os.path.getsize(bypass.aot)
                        if os.path.exists(bypass.aot) else None)
        with_b = os.path.getsize(main_build.aot)
        without_b = os.path.getsize(control.aot) if control_ok else None
        sites = sum((e.get('indirect_call_sites_emitted') or 0)
                    for e in registry_after.get('entries', []))
        entries_n = len(registry_after.get('entries', []))
        observations['measurements'] = {
            'aot_elf_bytes_with_maot': with_b,
            'aot_elf_bytes_control_no_pragmas': without_b,
            'aot_elf_delta_bytes': (with_b - without_b) if without_b else None,
            'indirect_call_sites_total': sites,
            # NOT a per-call-site cost, and saying so matters. The control
            # has no pragmas, so it also tree-shakes away every replacement
            # body -- workNew, workNew2, staticNew, staticNew2 and the rest
            # are unreachable without selection. The delta is therefore
            # dominated by keeping six dead implementations alive, not by the
            # three extra instructions at each call site. Isolating the
            # call-site cost needs a control that keeps the same bodies and
            # differs only in emission, which is what the bypass build below
            # provides.
            'aot_elf_delta_bytes_note':
                'includes six replacement bodies the no-pragma control shakes '
                'away; not divisible by call sites',
            'aot_elf_bytes_bypass_same_bodies': bypass_bytes,
            'aot_elf_call_site_delta_bytes':
                (with_b - bypass_bytes) if bypass_bytes else None,
            'aot_elf_call_site_delta_bytes_per_site':
                round((with_b - bypass_bytes) / sites, 1)
                if (bypass_bytes and sites) else None,
            'aot_elf_call_site_delta_note':
                'measured 0 at this fixture size, which does not mean free: '
                'the emission replaces one pc-relative branch with a pool '
                'load, a compressed load and an indirect branch -- about two '
                'extra instructions per site, or roughly 8 bytes x '
                f'{sites} sites -- and ELF section alignment absorbs that '
                'entirely. A per-site byte figure needs a fixture large '
                'enough to cross an alignment boundary.',
            'indirect_call_site_instructions': 3,
            'direct_call_site_instructions': 1,
            'registry_bytes': entries_n * 17 * 8,
            'registry_entries': entries_n,
            'registry_slots_per_entry': 17,
            'startup_ms_with_maot': median_ms(main_build),
            'startup_ms_control': median_ms(control) if control_ok else None,
            'direct_call_ns_with_indirection':
                'not separable from startup at this fixture size: the whole '
                'program runs in ~17 ms and makes 14 mutable calls, so a '
                'per-call figure would be reporting timer noise. The '
                'instruction counts above are the measurable cost; a real '
                'microbenchmark belongs with the optimizer work in #68, '
                'where the call shape is what is under test.',
            'note': 'diagnostic only; no threshold is compared anywhere',
        }
    finally:
        shutil.rmtree(work, ignore_errors=True)

    live = sorted(k for k, (kind, _) in V.BANK.items() if kind == 'live')
    historical = sorted(k for k, (kind, _) in V.BANK.items()
                        if kind == 'historical')
    failed = [a['id'] for a in arms if a['result'] != 'pass']
    observations['falsifications_failed'] = failed
    if failed:
        finding('FALSIFICATION_ARM_FAILED',
                f'arms that did not demonstrate their defect: '
                f'{", ".join(failed)}')
    missing = [k for k in live if k not in {a['id'] for a in arms}]
    if missing and not any(f['code'] in ('TOOLCHAIN_UNAVAILABLE',
                                         'FORK_NOT_ON_MAOT_REVISION')
                           for f in findings):
        finding('FALSIFICATION_ARM_ABSENT',
                f'live bank entries with no arm: {", ".join(missing)}')

    record = {
        'schema': 'maot.m3.evidence/1',
        'issue': 67,
        'generated_by': {
            'run_id': run_id,
            'gate_sha256': sha256_file(os.path.abspath(__file__)),
            'verdict_sha256': sha256_file(os.path.join(
                os.path.dirname(os.path.abspath(__file__)),
                'verdict_m3.py')),
            'fixture_sha256': hashlib.sha256(
                fixture.encode()).hexdigest(),
        },
        'identities': {
            'shorebird_revision': git(repo, 'rev-parse', 'HEAD'),
            'shorebird_tree': git(repo, 'rev-parse', 'HEAD^{tree}'),
            'fork_commit': git(FORK, 'rev-parse', 'HEAD'),
            'fork_tree': git(FORK, 'rev-parse', 'HEAD^{tree}'),
            'fork_worktree_entries': [
                l for l in (git(FORK, 'status', '--porcelain') or '').split('\n')
                if l.strip()],
            'namespace_identity': NAMESPACE,
            'depends_on': {'issue_66': 'RUNTIME_IMPLEMENTATION_REGISTRY_'
                                       'ESTABLISHED'},
        },
        'observations': observations,
        'registry_before': registry_before,
        'registry_after': registry_after,
        'falsification': arms,
        'falsification_bank': {
            'live': live, 'historical': historical,
            'historical_note':
                'defects this implementation actually hit while being built. '
                'The code can no longer express them, and an arm that cannot '
                'be built is not the same as a defect that never happened.',
        },
        'findings': findings,
        'consumers': None,
        'verdict': None,
    }

    produced, named = set(record), set(V.CONSUMERS)
    problems = [f'{k!r} computed but no decision declared to consume it'
                for k in sorted(produced - named)]
    problems += [f'CONSUMERS names {k!r}, which is not produced'
                 for k in sorted(named - produced)]
    for p in problems:
        finding('VALUE_NOT_CONSUMED', p)
    record['consumers'] = {'map': V.CONSUMERS,
                           'unconsumed_or_undeclared': problems}
    record['verdict'] = V.evaluate(observations, findings)

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, 'w') as fh:
        json.dump(record, fh, indent=2)
        fh.write('\n')

    v = record['verdict']
    blocking = [f for f in findings if f['severity'] == 'blocking']
    c = observations.get('calls') or {}
    print(f"fork          {record['identities']['fork_commit']}")
    print(f"top-level     {c.get('top.call.0')} -> {c.get('top.call.1')} -> "
          f"{c.get('top.call.2')}")
    print(f"static        {c.get('static.call.0')} -> "
          f"{c.get('static.call.1')} -> {c.get('static.call.2')}")
    print(f"version       {c.get('top.version.0')} -> "
          f"{c.get('top.version.2')}")
    print(f"one process   pid {c.get('process.pid')} == "
          f"{c.get('process.pid.final')}")
    print(f"arms          {len(arms)} ({len(failed)} failed)")
    print(f"blocking      {len(blocking)}")
    print(f"conditions    {len(v['conditions'])} "
          f"({len(v['conditions_failed'])} failed)")
    for k in v['conditions_failed']:
        print(f'  unmet: {k}')
    for f in blocking[:6]:
        print(f"  {f['code']}: {f['message'][:110]}")
    print(f"VERDICT       direct_static_replacement = "
          f"{v['direct_static_replacement']}")
    return 0 if not blocking and not v['conditions_failed'] else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
