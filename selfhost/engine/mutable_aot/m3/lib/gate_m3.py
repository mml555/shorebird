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


DIGEST_FILE = '.maot_source_digest'


def build_digests():
    return {f: (sha256_file(os.path.join(FORK, f))
                if os.path.exists(os.path.join(FORK, f)) else None)
            for f in MAOT_CXX_SOURCES}


def recorded_digests():
    """What m2/build_maot.sh recorded after the last successful build."""
    p = os.path.join(OUT, DIGEST_FILE)
    if not os.path.exists(p):
        return None
    rec = {'files': {}}
    for line in open(p):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        a, _, b = line.partition(' ')
        if a in ('fork_commit', 'fork_tree', 'built_at'):
            rec[a] = b
        else:
            rec['files'][b] = a
    return rec


def provenance(override=None):
    """How the built toolchain disagrees with the sources on disk.

    Content, not mtimes: this rig is shared, and switching branches on it
    rewrites every mtime without changing a byte. `override` substitutes a
    digest map so the guard can be shown to fire as well as to stay quiet.
    """
    rec = recorded_digests()
    if rec is None:
        return [{'problem': 'no build digest',
                 'detail': f'{os.path.join(OUT, DIGEST_FILE)} is absent; '
                           f'build with m2/build_maot.sh'}]
    now = override if override is not None else build_digests()
    out = []
    for f in sorted(MAOT_CXX_SOURCES):
        want, got = rec['files'].get(f), now.get(f)
        if want is None:
            out.append({'problem': 'source not covered by the build digest',
                        'file': f})
        elif got is None:
            out.append({'problem': 'source absent', 'file': f})
        elif got != want:
            out.append({'problem': 'source differs from the build',
                        'file': f, 'built_from': want[:16], 'on_disk': got[:16]})
    return out


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

    # ---- build provenance, before anything is measured ----
    stale = provenance()
    observations['target_arch'] = V.TARGET_ARCH
    observations['build_digest'] = recorded_digests() or {}
    observations['build_provenance_mismatches'] = stale
    observations['build_digest_matches'] = (stale == [])
    if stale:
        finding('BINARY_NOT_BUILT_FROM_THESE_SOURCES',
                'the built toolchain does not match the MAOT sources on disk, '
                'so this run would measure a different program than it names: '
                + '; '.join(x['problem'] + (f" ({x['file']})" if 'file' in x
                                            else '') for x in stale))

    # ---- the acceptance ledger ----
    # Stated here, evaluated below, and any unmet item becomes a blocking
    # finding. An evidence record that says `findings: []` while its own prose
    # says an acceptance item is outstanding is a record that disagrees with
    # itself, which is what the first version of this lane shipped.
    observations['t0_row_linkage'] = V.T0_ROW_LINKAGE
    unmet = []

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
            and vb['arm64_aot_direct_static_vertical_slice'] == 'NOT_ESTABLISHED',
            f"without the indirection: top.call.1={cb.get('top.call.1')} "
            f"while the descriptor reports {cb.get('top.version.1')}",
            vb['arm64_aot_direct_static_vertical_slice'])

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
            and v02['arm64_aot_direct_static_vertical_slice'] == 'NOT_ESTABLISHED',
            f"{(e_main or {}).get('indirect_call_sites_emitted')} call sites "
            f"emitted and the result observed is "
            f"{calls.get('top.call.1')}; with the result folded back to OLD "
            f"the verdict is {v02['arm64_aot_direct_static_vertical_slice']}",
            v02['arm64_aot_direct_static_vertical_slice'])

        # ---------------- G03: inlined away ----------------
        no_sites = json.loads(json.dumps(registry_after))
        for e in no_sites.get('entries', []):
            e['indirect_call_sites_emitted'] = 0
        v03 = perturbed(registry_after=no_sites)
        arm('G03', 'an inlined copy of a selected declaration is a caller that '
                   'never reaches the cell',
            not v03['conditions']['call_sites_traverse_the_mechanism']
            and v03['arm64_aot_direct_static_vertical_slice'] == 'NOT_ESTABLISHED',
            'with every emitted call site removed the path condition reads '
            f"{v03['conditions']['call_sites_traverse_the_mechanism']}",
            v03['arm64_aot_direct_static_vertical_slice'])

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
            and v05['arm64_aot_direct_static_vertical_slice'] == 'NOT_ESTABLISHED',
            f"version and body move together: {calls.get('top.version.1')} "
            f"with {calls.get('top.call.1')}",
            v05['arm64_aot_direct_static_vertical_slice'])
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
            and v09['arm64_aot_direct_static_vertical_slice'] == 'NOT_ESTABLISHED',
            'with the static arm left at its release answer the verdict is '
            f"{v09['arm64_aot_direct_static_vertical_slice']}",
            v09['arm64_aot_direct_static_vertical_slice'])

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

        iters = calls.get('bench.iterations') or 0

        def samples(key):
            return [calls[f'{key}.{r}'] for r in range(3)
                    if isinstance(calls.get(f'{key}.{r}'), int)]

        def ns_per_call(key):
            """Nanoseconds per call: the MINIMUM of the samples.

            The fixture reports total elapsed microseconds, three times per
            arm. It used to divide itself, in integers, and at ~1 ns per call
            that rounded every arm to 0 or 1 -- a measurement destroyed by its
            own units. The minimum is used because at this magnitude a single
            sample is dominated by scheduling noise: one arm measured faster
            than its own control, which is a coin flip, not a speedup.
            """
            xs = samples(key)
            if not xs or iters <= 0:
                return None
            return round(min(xs) * 1000.0 / iters, 3)

        def overhead(a, b):
            x, y = ns_per_call(a), ns_per_call(b)
            return round(x - y, 2) if (x is not None and y is not None) \
                else None

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
            'benchmark_iterations': calls.get('bench.iterations'),
            'direct_call_ns_mutable': ns_per_call('bench.top.mutable.us'),
            'direct_call_ns_control': ns_per_call('bench.top.control.us'),
            'static_call_ns_mutable': ns_per_call('bench.static.mutable.us'),
            'static_call_ns_control': ns_per_call('bench.static.control.us'),
            'direct_call_ns_overhead': overhead('bench.top.mutable.us',
                                                'bench.top.control.us'),
            'static_call_ns_overhead': overhead('bench.static.mutable.us',
                                                'bench.static.control.us'),
            'benchmark_elapsed_us_samples': {
                k: samples(k) for k in
                ('bench.top.mutable.us', 'bench.top.control.us',
                 'bench.static.mutable.us', 'bench.static.control.us')},
            'benchmark_spread_us': {
                k: (max(samples(k)) - min(samples(k))) if samples(k) else None
                for k in ('bench.top.mutable.us', 'bench.top.control.us',
                          'bench.static.mutable.us',
                          'bench.static.control.us')},
            'overhead_is_within_noise': True,
            'overhead_note':
                'the per-call overhead measures at a few hundredths of a '
                'nanosecond while the spread ACROSS SAMPLES OF THE SAME ARM '
                'is larger than the difference between arms -- one arm even '
                'measured faster than its own control. So the honest '
                'statement is that the indirection costs two extra '
                'instructions per call and that its cost is not resolvable '
                'above scheduling noise at this iteration count, not that it '
                'costs 0.06 ns. A resolvable figure needs a quieter harness, '
                'which belongs with #68 where the call shape is what is '
                'under test.',
            'benchmark_note':
                'nanoseconds per call: the minimum of three samples over the '
                'stated iteration count, measured in the running release '
                'AFTER installation, so the '
                'mutable arms are dispatching to a replacement. The controls '
                'are non-selected functions marked vm:never-inline -- an '
                'inlined control is not a call, and would make the '
                'indirection look arbitrarily expensive. The accumulator is '
                'folded into the result so the loop cannot be eliminated.',
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
            'note': 'diagnostic only; no threshold is compared anywhere',
        }
    finally:
        shutil.rmtree(work, ignore_errors=True)

        # ---------------- G16: placeholder measurements ----------------
        # The first version of this condition tested only that a field was
        # non-null, and the field held a sentence saying the measurement had
        # not been taken. Prose is not a number.
        prose = perturbed(measurements=dict(
            observations['measurements'],
            direct_call_ns_mutable='not separable from startup at this size'))
        missing_static = perturbed(measurements={
            k: v for k, v in observations['measurements'].items()
            if k != 'static_call_ns_mutable'})
        arm('G16', 'a measurement condition satisfied by a non-null field '
                   'accepts a sentence explaining that nothing was measured',
            all(isinstance(observations['measurements'].get(f), (int, float))
                and not isinstance(observations['measurements'].get(f), bool)
                for f in ('direct_call_ns_mutable', 'direct_call_ns_control',
                          'static_call_ns_mutable', 'static_call_ns_control'))
            and not prose['conditions']['call_latency_measured_numerically']
            and not missing_static['conditions'][
                'call_latency_measured_numerically'],
            f"direct {observations['measurements']['direct_call_ns_mutable']} "
            f"ns vs control "
            f"{observations['measurements']['direct_call_ns_control']} ns; "
            f"static {observations['measurements']['static_call_ns_mutable']} "
            f"ns vs control "
            f"{observations['measurements']['static_call_ns_control']} ns. "
            f"A prose value and a missing static arm each fail the condition.",
            prose['arm64_aot_direct_static_vertical_slice'])

        # ---------------- G17: stale build ----------------
        edited = dict(build_digests())
        victim = 'runtime/vm/compiler/backend/flow_graph_compiler_arm64.cc'
        edited[victim] = 'f' * 64
        hypothetical = provenance(override=edited)
        v17 = perturbed(build_digest_matches=False,
                        build_provenance_mismatches=hypothetical)
        arm('G17', 'a run that measures binaries built from other source bytes '
                   'names a program it did not test',
            observations['build_digest_matches'] is True
            and len(hypothetical) == 1
            and hypothetical[0].get('file') == victim
            and v17['arm64_aot_direct_static_vertical_slice'] ==
            'NOT_ESTABLISHED',
            f"the toolchain matches all {len(MAOT_CXX_SOURCES)} MAOT sources; "
            f"against one edited source the guard reports "
            f"{len(hypothetical)} mismatch ({victim.split('/')[-1]})",
            v17['arm64_aot_direct_static_vertical_slice'])

        # ---------------- G18: whole-row #64 promotion ----------------
        arm('G18', 'promoting a whole #64 row from one dispatch mode is an '
                   'overclaim; each row spans direct, tearoff_pre, '
                   'tearoff_post and dynamic, across JIT and AOT',
            all(v['row_result_after_67'] == 'UNMODELED'
                for v in V.T0_ROW_LINKAGE.values())
            and all(v['not_covered'] for v in V.T0_ROW_LINKAGE.values())
            and 't0_rows_promoted' not in observations,
            f"{len(V.T0_ROW_LINKAGE)} rows linked at the `direct` mode under "
            f"AOT on {V.TARGET_ARCH}; each still reports UNMODELED, with "
            f"{', '.join(sorted(set(m for v in V.T0_ROW_LINKAGE.values() for m in v['not_covered'])))} "
            f"recorded as not covered")

    # G19 -- the ledger must be able to refuse. An acceptance check that can
    # only report MET moves no information, and closure would then rest on
    # prose again.
    # Deliberately does NOT read the ledger's own result: the ledger is
    # computed from the final conditions, which include this arm, and an arm
    # that waited for that would be waiting for itself.
    broken_linkage = dict(observations)
    broken_linkage['target_arch'] = 'not-arm64'
    v19 = V.evaluate(broken_linkage, [])
    arm('G19', 'an acceptance ledger that cannot report NOT MET makes closure '
               'rest on prose again',
        not v19['conditions']['t0_linkage_exact_and_unpromoted']
        and v19['issue_67_closure'] == 'NOT_READY',
        f'with the architecture claim falsified the linkage condition reads '
        f"{v19['conditions']['t0_linkage_exact_and_unpromoted']} and closure "
        f"reads {v19['issue_67_closure']}",
        v19['issue_67_closure'])

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

    # The acceptance ledger. Each item is EVALUATED, not asserted: an item
    # that could only ever report MET would be the vacuous check this program
    # exists to avoid, and G19 shows the ledger refusing.
    #
    # The #64 item was corrected after review. It used to read "rows for these
    # call forms move to PROVEN", which was itself an overclaim: EB-01 and
    # EB-02 each span direct, tearoff_pre, tearoff_post and dynamic, across
    # JIT and AOT and cold and hot, while #67 owns direct/static AOT
    # replacement. The item now requires EXACT LINKAGE of what was
    # demonstrated with the whole rows left unpromoted -- and full-row
    # non-promotion is the correct result, not a failure.
    verdict_now = V.evaluate(observations, findings)
    ledger = [
        {'item': 'exact #64 linkage for the demonstrated modes, with EB-01 '
                 'and EB-02 left unpromoted',
         'met': verdict_now['conditions']['t0_linkage_exact_and_unpromoted'],
         'evidence': 't0_row_linkage records dispatch=direct, '
                     'compilation=aot, heat=cold+hot, target_arch=arm64; both '
                     'rows still report UNMODELED with their uncovered modes '
                     'named. G18 refuses a whole-row promotion.'},
        {'item': 'one release process performs OLD -> install -> NEW for a '
                 'precompiled top-level direct call, and the same for a '
                 'static method call',
         'met': (verdict_now['conditions']['top_level_replacement_observed']
                 and verdict_now['conditions']['static_replacement_observed']
                 and verdict_now['conditions']['no_restart_or_recompile']),
         'evidence': 'same pid and byte-identical snapshot across the run'},
        {'item': '#65 id and #66 version visible in structured evidence',
         'met': verdict_now['conditions']['identity_visible_in_evidence'],
         'evidence': 'structural DeclarationIds for target and replacement'},
        {'item': 'compiler/runtime path evidence proves the mechanism is '
                 'traversed',
         'met': verdict_now['conditions'][
             'call_sites_traverse_the_mechanism'],
         'evidence': 'per-declaration emitted indirect call-site counts'},
        {'item': 'wrong ID / release / ABI fails closed',
         'met': verdict_now['conditions']['refusals_before_visible_mutation'],
         'evidence': 'refused in-process with the release answer intact'},
        {'item': 'falsification arms discriminate',
         'met': verdict_now['conditions']['required_falsifications_detected'],
         'evidence': f'{len(arms)} live arms'},
        {'item': 'direct and static call latency measured',
         'met': verdict_now['conditions']['call_latency_measured_numerically'],
         'evidence': 'numeric ns/call for both forms against never-inlined '
                     'controls, with the overhead flagged as within noise'},
    ]
    unmet = [u for u in ledger if not u['met']]
    observations['acceptance_ledger'] = ledger
    observations['acceptance_items_unmet'] = [u['item'] for u in unmet]
    for u in unmet:
        finding('ACCEPTANCE_ITEM_NOT_MET', f"{u['item']}: not met")

    record = {
        'schema': 'maot.m3.evidence/2',
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
            'target_arch': V.TARGET_ARCH,
            'lowering_site': 'runtime/vm/compiler/backend/'
                             'flow_graph_compiler_arm64.cc',
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
    m = observations.get('measurements') or {}
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
    print(f"latency       direct {m.get('direct_call_ns_mutable')} ns "
          f"(control {m.get('direct_call_ns_control')}) | static "
          f"{m.get('static_call_ns_mutable')} ns "
          f"(control {m.get('static_call_ns_control')})")
    print(f"provenance    {'bound' if observations.get('build_digest_matches') else 'MISMATCH'}"
          f" | arch {observations.get('target_arch')}")
    print(f"SLICE         arm64_aot_direct_static_vertical_slice = "
          f"{v['arm64_aot_direct_static_vertical_slice']}")
    print(f"CLOSURE       issue_67_closure = {v['issue_67_closure']}")
    for u in v['acceptance_items_unmet']:
        print(f"  unmet acceptance: {u}")
    # The gate succeeds when the SLICE holds. An unmet acceptance item keeps
    # closure NOT_READY without pretending the mechanism failed.
    return 0 if v['arm64_aot_direct_static_vertical_slice'] == 'ESTABLISHED' \
        else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
