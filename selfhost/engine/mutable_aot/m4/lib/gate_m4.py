#!/usr/bin/env python3
"""MAOT-4 (#68) -- run the optimizer-invariant lane and derive the verdicts.

Every run drives the real chain, and every falsification is a real build with
a real control flag rather than an edited expectation.

usage: gate_m4.py <m4-dir> <out.json>
"""

import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verdict_m4 as V          # noqa: E402
import rules_m4 as R            # noqa: E402

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
    'runtime/vm/compiler/frontend/kernel_binary_flowgraph.cc',
    'runtime/vm/compiler/frontend/kernel_translation_helper.cc',
    'runtime/vm/compiler/frontend/kernel_translation_helper.h',
    'pkg/vm/lib/metadata/maot_declaration_id.dart',
    'pkg/vm/lib/transformations/type_flow/transformer.dart',
    'pkg/vm/lib/transformations/pragma.dart',
    'pkg/vm/lib/modular/target/vm.dart',
)

# The conservative AOT control: the same program with the optimization most
# able to erase a mutable boundary turned off globally. #64's `jit` value is
# a control concept, and per the amended #68 text test 10 is optimized AOT
# versus conservative AOT -- not a second JIT mechanism.
CONSERVATIVE_FLAGS = ['--inlining_depth_threshold=0']


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b''):
            h.update(chunk)
    return h.hexdigest()


def git(root, *args):
    r = subprocess.run(['git', '-C', root] + list(args),
                       capture_output=True, text=True, timeout=60)
    return r.stdout.strip() if r.returncode == 0 else None


def build_digests():
    return {f: (sha256_file(os.path.join(FORK, f))
                if os.path.exists(os.path.join(FORK, f)) else None)
            for f in MAOT_CXX_SOURCES}


def head_digests(sources=None):
    """sha256 of each tracked MAOT source AS THE FORK'S HEAD COMMIT CONTAINS IT.

    Separate from build_digests(), which reads the worktree. Comparing the two
    is what binds the bytes that were measured to the commit the evidence
    names -- a claim nothing checked until #68's closure review, and one that
    had already failed: HEAD was 2e4df989 while the worktree held what became
    b92efd82, so the binary matched the sources, the sources matched the
    digest, and the record still named a commit whose bytes were never
    measured.

    None for a path HEAD does not track, which is distinct from a path whose
    content differs and is reported differently.
    """
    sources = MAOT_CXX_SOURCES if sources is None else sources
    out = {}
    for f in sources:
        r = subprocess.run(['git', '-C', FORK, 'cat-file', 'blob', f'HEAD:{f}'],
                           capture_output=True)
        out[f] = (hashlib.sha256(r.stdout).hexdigest()
                  if r.returncode == 0 else None)
    return out


def fork_identity():
    def g(*args):
        r = subprocess.run(['git', '-C', FORK] + list(args),
                           capture_output=True, text=True)
        return r.stdout.strip() if r.returncode == 0 else None
    return {'head': g('rev-parse', 'HEAD'),
            'tree': g('rev-parse', 'HEAD^{tree}'),
            'branch': g('rev-parse', '--abbrev-ref', 'HEAD'),
            'worktree_dirty_paths': sorted(
                l[3:] for l in (g('status', '--porcelain') or '').splitlines()
                if l)}


def source_commit_binding(sources=None, override_head=None):
    """How the measured bytes disagree with the commit the evidence names.

    Three separate claims, and the old provenance only made the first:
      1. the binary was built from these bytes      (build_digests vs recorded)
      2. these bytes are what fork HEAD contains    (here)
      3. the record names that same HEAD            (here)
    """
    sources = MAOT_CXX_SOURCES if sources is None else sources
    ident = fork_identity()
    now = build_digests()
    want = override_head if override_head is not None else head_digests(sources)
    rec = recorded_digests()
    out = []
    for f in sorted(sources):
        if want.get(f) is None:
            out.append({'problem': 'source is not tracked at the named commit',
                        'file': f})
        elif now.get(f) != want.get(f):
            out.append({'problem': 'source differs from the named commit',
                        'file': f, 'at_head': (want[f] or '')[:16],
                        'on_disk': (now.get(f) or '')[:16]})
    recorded_head = (rec or {}).get('fork_commit')
    if rec is not None and recorded_head and ident['head'] \
            and recorded_head != ident['head']:
        out.append({'problem': 'the build record names a different commit '
                               'than the fork is on now',
                    'built_at_commit': recorded_head[:16],
                    'fork_head_now': ident['head'][:16]})
    return out, ident


def recorded_digests():
    p = os.path.join(OUT, '.maot_source_digest')
    if not os.path.exists(p):
        return None
    rec = {'files': {}}
    for line in open(p):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        a, _, b = line.partition(' ')
        # Discriminate on SHAPE, not on a list of known keys. A file line
        # begins with a 64-hex sha256; anything else is a header. Keying on a
        # known-key list meant adding one header field (fork_sources_match_head)
        # silently registered a FILE named "1", which the staleness check then
        # reported as a missing source -- a parser that was not total over its
        # own input, reporting its own gap as a defect in the subject.
        if not re.fullmatch(r'[0-9a-f]{64}', a):
            rec[a] = b
        else:
            rec['files'][b] = a
    return rec


def provenance(override=None):
    rec = recorded_digests()
    if rec is None:
        return [{'problem': 'no build digest'}]
    now = override if override is not None else build_digests()
    out = []
    for f in sorted(MAOT_CXX_SOURCES):
        want, got = rec['files'].get(f), now.get(f)
        if want is None:
            out.append({'problem': 'source not covered by the build digest',
                        'file': f})
        elif got != want:
            out.append({'problem': 'source differs from the build', 'file': f})
    return out


class Build:
    def __init__(self, workdir, source):
        self.dir = workdir
        lib = os.path.join(workdir, 'pkg', 'lib')
        os.makedirs(lib, exist_ok=True)
        with open(os.path.join(lib, 'fixture_m4.dart'), 'w') as fh:
            fh.write(source)
        tool = os.path.join(workdir, 'pkg', '.dart_tool')
        os.makedirs(tool, exist_ok=True)
        with open(os.path.join(tool, 'package_config.json'), 'w') as fh:
            json.dump({'configVersion': 2, 'packages': [{
                'name': 'm4app',
                'rootUri': f'file://{os.path.join(workdir, "pkg")}/',
                'packageUri': 'lib/', 'languageVersion': '3.9'}]}, fh)
        self.pkg_config = os.path.join(tool, 'package_config.json')
        self.dill = os.path.join(workdir, 'app.dill')
        self.aot = os.path.join(workdir, 'app.aot')
        self.precompile_dump = None
        self.dumps = os.path.join(workdir, 'dumps')
        os.makedirs(self.dumps, exist_ok=True)
        self.compile_seconds = None

    def kernel(self, env_extra=None):
        env = dict(os.environ, **(env_extra or {}))
        return subprocess.run(
            [DART,
             f'--packages={os.path.join(FORK, ".dart_tool/package_config.json")}',
             os.path.join(FORK, 'pkg/vm/bin/gen_kernel.dart'),
             '--platform', os.path.join(OUT, 'vm_platform_product.dill'),
             '--aot', '--packages', self.pkg_config,
             '-o', self.dill, 'package:m4app/fixture_m4.dart'],
            capture_output=True, text=True, timeout=1800, env=env)

    def snapshot(self, extra=()):
        t = time.perf_counter()
        # The PRECOMPILE dump, written by gen_snapshot itself. The runtime
        # dump cannot carry the materialization stats -- they are set during
        # precompilation and read back as -1 from the deserialized registry --
        # and without them a falsification cannot tell "registered then
        # dropped for want of a retention root" from "never registered".
        self.precompile_dump = os.path.join(self.dir, 'registry_precompile.json')
        r = subprocess.run(
            [os.path.join(OUT, 'gen_snapshot'), '--snapshot_kind=app-aot-elf',
             f'--elf={self.aot}', f'--maot_namespace={NAMESPACE}',
             f'--maot_dump_registry_precompile={self.precompile_dump}']
            + list(extra) + [self.dill],
            capture_output=True, text=True, timeout=1800)
        self.compile_seconds = round(time.perf_counter() - t, 2)
        return r

    def run(self, dump=True, extra=()):
        env = dict(os.environ, MAOT_NAMESPACE=NAMESPACE)
        if dump:
            env['MAOT_DUMP_DIR'] = self.dumps
        return subprocess.run(
            [os.path.join(OUT, 'dartaotruntime')] + list(extra) + [self.aot],
            capture_output=True, text=True, timeout=900, env=env)

    def registry(self, which='registry_after.json'):
        p = os.path.join(self.dumps, which)
        return json.load(open(p)) if os.path.exists(p) else {}

    def precompile_registry(self):
        p = getattr(self, 'precompile_dump', None)
        return json.load(open(p)) if p and os.path.exists(p) else {}


def _ns(calls, key, reps=3):
    """Nanoseconds per call: the minimum of the samples, divided here.

    #67 learned both halves of this -- dividing in the fixture's integers
    destroys the measurement, and a single sample at ~1 ns is dominated by
    scheduling noise.
    """
    xs = [calls[f'{key}.{r}'] for r in range(reps)
          if isinstance(calls.get(f'{key}.{r}'), int)]
    n = calls.get('bench.iterations') or 0
    if not xs or n <= 0:
        return None
    return round(min(xs) * 1000.0 / n, 3)


def parse_calls(stdout):
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


def entries_by_suffix(registry, suffix):
    """One registry entry by declaration-id suffix, or None.

    Returns None rather than {} on purpose: an arm that reads a missing
    declaration must be able to tell "absent" from "present with zeroes", and
    the retention falsification depends on exactly that distinction.
    """
    for e in (registry or {}).get('entries', []):
        if e['declaration_id'].endswith(suffix):
            return e
    return None


class _NotMeasured(Exception):
    """Raised to skip measurement when the gate cannot start. It is caught,
    so the record is still written and the exit code still reports failure."""


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    m4_dir, out_path = os.path.abspath(argv[1]), argv[2]
    repo = os.path.abspath(os.path.join(m4_dir, '..', '..', '..', '..'))
    run_id = datetime.datetime.now(datetime.timezone.utc).strftime(
        '%Y-%m-%dT%H:%M:%SZ')
    findings, arms = [], []
    obs = {'target_arch': V.TARGET_ARCH, 't0_row_linkage': V.T0_ROW_LINKAGE}

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

    fixture = open(os.path.join(m4_dir, 'lib', 'fixture_m4.dart')).read()

    if not os.path.exists(os.path.join(FORK, 'runtime/vm/maot_registry.cc')):
        finding('FORK_NOT_ON_MAOT_REVISION',
                f'{FORK} has no Mutable-AOT sources; the shared rig is handed '
                f'back. See m2/rescued/R3_STATE_BEFORE_BORROW.txt.')

    stale = provenance()
    obs['build_digest'] = recorded_digests() or {}
    obs['build_provenance_mismatches'] = stale
    obs['build_digest_matches'] = (stale == [])
    if stale:
        finding('BINARY_NOT_BUILT_FROM_THESE_SOURCES',
                '; '.join(x['problem'] + (f" ({x['file']})" if 'file' in x
                                          else '') for x in stale))


    # ---- source-to-COMMIT binding -------------------------------------
    # staleness() binds the binary to the bytes on disk. It says nothing
    # about whether those bytes are the ones the named commit contains, and
    # that gap was not hypothetical: #68's evidence was measured against a
    # dirty worktree at 2e4df989 whose content later became b92efd82, so the
    # digest matched, the binary matched, and the record named a commit whose
    # bytes had never been measured.
    unbound, fork_ident = source_commit_binding()
    obs['fork_identity'] = fork_ident
    obs['source_commit_binding_mismatches'] = unbound
    obs['sources_match_named_commit'] = (unbound == [])
    if unbound:
        finding('SOURCES_DO_NOT_MATCH_THE_NAMED_COMMIT',
                'the measured sources are not the ones the named fork commit '
                'contains, so this record would name a revision it did not '
                'measure: '
                + '; '.join(x['problem'] + (f" ({x['file']})" if 'file' in x
                                            else '') for x in unbound))

    work = os.path.join('/tmp', f'maot_m4_{os.getpid()}')
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    # NOT `raise SystemExit(0)`. That pattern exits the process silently with
    # a success code, so a gate that could not start reports the same thing as
    # a gate that passed -- which is exactly how this one first ran: no
    # output, exit 0, nothing measured.
    try:
        if findings:
            measured = False
        else:
            measured = True

        if not measured:
            raise _NotMeasured()

        def build(name, snap_extra=(), kernel_env=None):
            b = Build(os.path.join(work, name), fixture)
            k = b.kernel(kernel_env)
            if k.returncode != 0:
                finding('KERNEL_FAILED', (k.stderr or k.stdout)[-400:])
            s = b.snapshot(snap_extra)
            if s.returncode != 0:
                finding('SNAPSHOT_FAILED', (s.stderr or s.stdout)[-400:])
            return b

        def summarize(b, run_extra=()):
            r = b.run(extra=run_extra)
            c = parse_calls(r.stdout)
            reg = b.registry()
            e = next((x for x in reg.get('entries', [])
                      if x['declaration_id'].endswith('::fn:tiny')), {})
            return {'install': c.get('install.tiny'),
                    'call': c.get('tiny.1'),
                    'escapes': e.get('optimizer_escapes'),
                    'installable': e.get('installable')}, c, reg

        # ---------------- the release run ----------------
        main_b = build('release')
        r = main_b.run()
        if r.returncode != 0:
            finding('RUNTIME_FAILED', (r.stderr or r.stdout)[-400:])
        calls = parse_calls(r.stdout)
        reg_after = main_b.registry()
        obs['calls'] = calls
        obs['registry_after'] = reg_after
        obs['registry_before'] = main_b.registry('registry_before.json')
        obs['optimizer_decisions'] = reg_after.get('optimizer_decisions', [])

        def perturbed(**over):
            p = dict(obs)
            p.update(over)
            return V.evaluate(p, [])

        # ---------------- the devirtualization join, persisted ----------
        dec = obs['optimizer_decisions']
        tgt = next((d['declaration_id'] for d in dec
                    if d['declaration_id'].endswith(
                        'cls:OnlyShape::method:describe')), None)
        rows = [d for d in dec if d['declaration_id'] == tgt]
        callers = {d['caller_id'] for d in rows
                   if d['optimization_class'] in ('devirtualization',
                                                  'static-call-lowering')}
        inst = next((x for x in reg_after.get('entries', [])
                     if x['declaration_id'] == tgt), {})
        obs['devirtualization_join'] = {
            'target': tgt,
            'caller': sorted(callers)[0] if callers else None,
            'callers_agree': len(callers) == 1,
            'devirtualization_slot_preserving': sum(
                1 for d in rows if d['optimization_class'] == 'devirtualization'
                and d['disposition'] == 'SLOT_PRESERVING'),
            'static_call_lowering_slot_preserving': sum(
                1 for d in rows
                if d['optimization_class'] == 'static-call-lowering'
                and d['disposition'] == 'SLOT_PRESERVING'),
            # #69 split the single 'instance-dispatch' record into one per
            # (call form x switchable state), so an exact-name match finds
            # nothing. The condition this feeds must still mean "instance
            # dispatch is blocked", so it counts every dispatch-form record
            # that is still blocking rather than one fixed name.
            'instance_dispatch_unmodeled_blocking': sum(
                1 for d in rows
                if d['disposition'] == 'UNMODELED_BLOCKING'
                and (d['optimization_class'].startswith('instance-dispatch')
                     or d['optimization_class'].startswith('dynamic/')
                     or d['optimization_class'].startswith('interface/')
                     or d['optimization_class'].startswith('super/'))),
            'install_refused': calls.get('install.devirt') == -3,
            'records': rows,
        }
        j = obs['devirtualization_join']
        no_join = perturbed(devirtualization_join=dict(
            j, static_call_lowering_slot_preserving=0))
        arm('H09', 'a devirtualization record without a static-call-lowering '
                   'partner would mean the transform happened and the edge it '
                   'produced never reached the cell',
            j['devirtualization_slot_preserving'] > 0
            and j['static_call_lowering_slot_preserving'] > 0
            and j['callers_agree'] and j['install_refused']
            and not no_join['conditions']['devirtualization_join_present'],
            f"target {(tgt or '').split('::', 1)[-1]}, caller "
            f"{(j['caller'] or '').split('::', 1)[-1]}: "
            f"{j['devirtualization_slot_preserving']} devirtualization + "
            f"{j['static_call_lowering_slot_preserving']} static-call-lowering "
            f"records, both SLOT_PRESERVING, with "
            f"{j['instance_dispatch_unmodeled_blocking']} instance-dispatch "
            f"UNMODELED_BLOCKING and installation refused",
            no_join['arm64_aot_optimizer_invariants'])

        # ---- H19: the granular join cannot be silently zeroed -----------
        # #69 split the single 'instance-dispatch' record into one record per
        # (call form x switchable state). An exact-name match then counted
        # zero, and this condition went false -- loudly, which was correct,
        # but the next rename must not be able to do it quietly either. This
        # arm requires the count to come from the granular records AND to
        # reach zero when none of them block.
        disp_rows = [d for d in obs['optimizer_decisions']
                     if d['optimization_class'].startswith(
                         ('instance-dispatch', 'dynamic/', 'interface/',
                          'super/'))]
        blocking_forms = sorted({d['optimization_class'] for d in disp_rows
                                 if d['disposition'] == 'UNMODELED_BLOCKING'})
        all_preserving = perturbed(devirtualization_join=dict(
            j, instance_dispatch_unmodeled_blocking=0))
        obs['granular_dispatch_forms'] = {
            'records': sorted({d['optimization_class'] for d in disp_rows}),
            'blocking': blocking_forms,
        }
        arm('H19', 'the devirtualization join counts dispatch-form records by '
                   'NAME. Splitting one coarse record into several made an '
                   'exact-name match count zero; a future rename must not be '
                   'able to zero it quietly.',
            len(obs['granular_dispatch_forms']['records']) > 1
            and len(blocking_forms) > 0
            and j['instance_dispatch_unmodeled_blocking'] > 0
            and not all_preserving['conditions'][
                'devirtualization_join_present'],
            f"{len(obs['granular_dispatch_forms']['records'])} dispatch-form "
            f"records, {len(blocking_forms)} still blocking "
            f"({', '.join(x.split('/')[-1] for x in blocking_forms)}); the "
            f"join counts {j['instance_dispatch_unmodeled_blocking']}, and "
            f"with none blocking the condition goes false",
            all_preserving['arm64_aot_optimizer_invariants'])

        arm('H08', 'an instance member installable while no instance-call '
                   'path traverses the cell is the divergence this issue '
                   'exists to prevent -- it was real until this rule existed',
            inst.get('installable') is False
            and calls.get('install.devirt') == -3
            and calls.get('devirt.1') == 'OLD-DEVIRT'
            and calls.get('hot.devirt') == 'OLD-DEVIRT',
            f"install refused ({calls.get('install.devirt')}), the call still "
            f"returns {calls.get('devirt.1')} cold and "
            f"{calls.get('hot.devirt')} hot, and the descriptor never claims "
            f"otherwise")

        # ---- H16: the recognized/intrinsic class ----------------------
        # The instance-dispatch blocker does NOT cover this: `identical` and
        # several top-level Developer/FFI functions are recognized AND static.
        # The class is closed by two facts, both checked here, plus a third
        # arm that watches the blocker fire.
        rmh = os.path.join(FORK,
                           'runtime/vm/compiler/recognized_methods_list.h')
        rt_libs, rt_blocks = R.recognized_table_libraries(open(rmh).read())
        # object.cc only CHECKS a vm:recognized pragma against the table; the
        # single assignment of recognized_kind is in InitializeState().
        objcc = open(os.path.join(FORK, 'runtime/vm/object.cc')).read()
        assigners = [f for f in (
            'runtime/vm/compiler/method_recognizer.cc',
            'runtime/vm/object.cc',
        ) if 'set_recognized_kind(' in open(os.path.join(FORK, f)).read()]
        obs['recognized_table'] = {
            'header': 'runtime/vm/compiler/recognized_methods_list.h',
            'blocks_found': rt_blocks,
            'blocks_required': list(R.RECOGNIZED_TABLE_BLOCKS),
            'libraries': sorted(rt_libs),
            'non_sdk_libraries': sorted(rt_libs - R.SDK_LIBRARY_ACCESSORS),
            'files_that_assign_recognized_kind': assigners,
            # object.cc's only use is the consistency check that a recognized
            # function also carries the pragma -- the reverse direction.
            'pragma_can_assign_recognized_kind':
                'set_recognized_kind' in objcc.split(
                    'Check that the function is marked as recognized via the '
                    'vm:recognized')[-1][:400],
        }
        sdk_selected = sorted(
            e['declaration_id'] for e in reg_after.get('entries', [])
            if e.get('selected') and ':dart:' in e['declaration_id'])
        obs['selected_sdk_declarations'] = sdk_selected

        base_rec = entries_by_suffix(reg_after, '::fn:recognizedish') or {}
        base_rec_forbidden = [
            d for d in obs['optimizer_decisions']
            if d['optimization_class'] == 'recognized-or-intrinsic'
            and d['disposition'] == 'FORBIDDEN']
        frc_b = build('recognized_defect', ['--maot_force_recognized'])
        frc_r = frc_b.run()
        frc_c = parse_calls(frc_r.stdout)
        frc_reg = frc_b.registry()
        frc_e = entries_by_suffix(frc_reg, '::fn:recognizedish') or {}
        frc_forbidden = [
            d for d in frc_reg.get('optimizer_decisions', [])
            if d['optimization_class'] == 'recognized-or-intrinsic'
            and d['disposition'] == 'FORBIDDEN']
        rec = {
            'baseline_forbidden_decisions': len(base_rec_forbidden),
            'baseline_install': calls.get('install.recognizedish'),
            'baseline_installable': base_rec.get('installable'),
            'baseline_call_after_install': calls.get('recognizedish.1'),
            'defect_forbidden_decisions': len(frc_forbidden),
            'defect_install': frc_c.get('install.recognizedish'),
            'defect_installable': frc_e.get('installable'),
            'defect_escapes': frc_e.get('optimizer_escapes'),
            'defect_call_after_install': frc_c.get('recognizedish.1'),
        }
        obs['injected_recognized_defect'] = rec
        rec['verdict_under_defect'] = perturbed(
            calls=frc_c, registry_after=frc_reg,
            optimizer_decisions=frc_reg.get('optimizer_decisions', []),
        )['arm64_aot_optimizer_invariants']

        v16 = V.evaluate(dict(obs), [])['conditions']
        arm('H16', 'a recognized body can be replaced with inline code at the '
                   'call site that no dispatch cell mediates, and recognized '
                   'declarations are static as often as not -- so '
                   'instance-member blocking cannot cover the class. It is '
                   'closed instead by the tables naming only SDK libraries '
                   'and no SDK declaration being selectable. The fixture '
                   'carries vm:recognized on a user function and it is NOT '
                   'honoured, which is the point: the blocker is proven by '
                   'injecting the state the tables cannot produce.',
            v16['recognized_population_is_sdk_only']
            and v16['no_sdk_declaration_is_selected']
            and v16['injected_recognized_defect_is_caught'],
            f"tables {rt_blocks} name {len(rt_libs)} libraries, "
            f"{len(obs['recognized_table']['non_sdk_libraries'])} non-SDK; "
            f"recognized_kind assigned only in {assigners}; selected dart: "
            f"declarations {sdk_selected}; a user vm:recognized pragma is not "
            f"honoured (baseline {rec['baseline_forbidden_decisions']} "
            f"FORBIDDEN, install {rec['baseline_install']}); under "
            f"--maot_force_recognized {rec['defect_forbidden_decisions']} "
            f"FORBIDDEN, installable {rec['defect_installable']}, install "
            f"{rec['defect_install']}",
            rec['verdict_under_defect'])

        # ---- H15: the completeness check must be able to fail -----------
        # The first version only checked that whatever was in R.RULES had
        # populated fields, so deleting a class shrank what it inspected
        # instead of failing it. This arm deletes one and requires the flip.
        _saved = R.RULES
        _flip = {}
        try:
            for _cls in sorted(R.REQUIRED_CLASSES):
                R.RULES = {k: v for k, v in _saved.items() if k != _cls}
                _flip[_cls] = V.evaluate(dict(obs), [])[
                    'conditions']['every_optimizer_class_has_a_rule']
        finally:
            R.RULES = _saved
        missing_flips = sorted(k for k, v in _flip.items() if v is not False)
        obs['required_class_removal'] = {
            'required_classes': sorted(R.REQUIRED_CLASSES),
            'condition_after_removal': _flip,
            'classes_whose_removal_went_undetected': missing_flips,
        }
        arm('H15', 'an entire optimizer class can be deleted from the rule '
                   'table. A check that only inspects what is present cannot '
                   'see that, which is exactly how this one shipped.',
            len(R.REQUIRED_CLASSES) > 0
            and missing_flips == []
            and V.evaluate(dict(obs), [])[
                'conditions']['every_optimizer_class_has_a_rule'] is True,
            f"removing any one of {len(R.REQUIRED_CLASSES)} required classes "
            f"fails the completeness condition; undetected removals: "
            f"{missing_flips}",
            'NOT_ESTABLISHED' if missing_flips == [] else 'ESTABLISHED')

        # ---- H10: an INJECTED inlining defect ---------------------------
        # The previous version of this arm observed that the protection was in
        # place. That is a positive test, not a falsification. This one turns
        # the protection off, checks the inliner actually took the callee, and
        # requires the resulting defect to be caught.
        base_inl = entries_by_suffix(reg_after, '::fn:tiny') or {}
        inl_b = build('inline_defect', ['--maot_allow_inlining_mutable'])
        inl_r = inl_b.run()
        inl_c = parse_calls(inl_r.stdout)
        inl_reg = inl_b.registry()
        inl_e = entries_by_suffix(inl_reg, '::fn:tiny') or {}
        ind = {
            'baseline_inline_refusals': base_inl.get('inline_refusals'),
            'baseline_inline_admissions': base_inl.get('inline_admissions'),
            'baseline_install': calls.get('install.tiny'),
            'baseline_installable': base_inl.get('installable'),
            'baseline_escapes': base_inl.get('optimizer_escapes'),
            'baseline_call_after_install': calls.get('tiny.1'),
            'baseline_hot_call': calls.get('hot.tiny'),
            'refusal_counter_note':
                'set_is_inlinable(false) at seeding makes the inliner skip a '
                'mutable callee BEFORE ShouldWeInline is consulted, so the '
                'refusal counter reads zero on this fixture. It is non-zero '
                'at application scale (see evidence/m4_scale.json), and it is '
                'not what this arm stands on: the precondition that '
                'discriminates is that the inliner DOES take the callee once '
                'the rule is removed.',
            'defect_inline_refusals': inl_e.get('inline_refusals'),
            'defect_inline_admissions': inl_e.get('inline_admissions'),
            'defect_escapes': inl_e.get('optimizer_escapes'),
            'defect_installable': inl_e.get('installable'),
            'defect_install': inl_c.get('install.tiny'),
            'defect_call_after_install': inl_c.get('tiny.1'),
            'defect_hot_call': inl_c.get('hot.tiny'),
        }
        obs['injected_inlining_defect'] = ind
        ind['verdict_under_defect'] = perturbed(
            calls=inl_c, registry_after=inl_reg,
            optimizer_decisions=inl_reg.get('optimizer_decisions', []),
        )['arm64_aot_optimizer_invariants']
        arm('H10', 'a mutable callee the inliner actually took leaves its '
                   'caller holding a copy no dispatch cell mediates. The '
                   'protection is removed here, the inline is confirmed to '
                   'have happened, and the consequence is measured.',
            V.evaluate(dict(obs), [])['conditions'][
                'injected_inlining_defect_is_caught'],
            f"baseline admissions={ind['baseline_inline_admissions']}, "
            f"install {ind['baseline_install']}, caller returns "
            f"{ind['baseline_call_after_install']}; under "
            f"--maot_allow_inlining_mutable the inliner took the callee "
            f"{ind['defect_inline_admissions']} time(s), which recorded "
            f"{ind['defect_escapes']} escape(s), installation was refused "
            f"({ind['defect_install']}) and the caller still returns "
            f"{ind['defect_call_after_install']} cold and "
            f"{ind['defect_hot_call']} hot",
            ind['verdict_under_defect'])

        # ---- H12: an INJECTED retention defect --------------------------
        # Two instruments, run together. The first draft of this comment said
        # they fail at different points -- --maot_disable_seeding registering
        # nothing, --maot_disable_retention_roots registering and then
        # dropping. Measurement says otherwise: binding and registration
        # happen in the KERNEL LOADER, not at seeding, so both show 13 seen
        # and 13 dropped. AddFunction is the only retention effect seeding
        # has. What the two actually differ by is the disposition records
        # seeding emits, and that is what the arm asserts.
        #
        # The materialization stats still have to come from the PRECOMPILE
        # dump: they are set during precompilation and read back as -1 from
        # the deserialized runtime registry.
        #
        # FINDING. This arm was written expecting the retention root to matter
        # only for a declaration the release never calls, and to isolate that
        # case by withholding it. It does not decompose that way: withholding
        # the root removes EVERY mutable declaration, reachable ones included,
        # and the program then aborts in the AOT runtime trying to JIT-compile
        # `tiny`. The reason is #67's own lowering -- a mutable call site is an
        # indirect load from the dispatch cell, so the precompiler no longer
        # sees a static-call edge to the callee and nothing else retains it.
        # The retention root is not defence in depth. It is the only thing
        # keeping any mutable declaration alive, and that was found by running
        # the falsification rather than by reading the code.
        ret_b = build('retention_defect', ['--maot_disable_retention_roots'])
        ret_r = ret_b.run()
        ret_c = parse_calls(ret_r.stdout)
        ret_reg = ret_b.registry()
        ret_pre = ret_b.precompile_registry()
        noseed_b = build('no_seeding', ['--maot_disable_seeding'])
        noseed_r = noseed_b.run()
        noseed_pre = noseed_b.precompile_registry()
        obs['retention_defect_run'] = {
            'returncode': ret_r.returncode,
            'stderr_tail': (ret_r.stderr or '')[-600:],
            'keys_emitted': sorted(ret_c),
        }
        base_pre = main_b.precompile_registry()
        ret = {
            'baseline_registry_entries': len(reg_after.get('entries', [])),
            'baseline_selected_entries': sum(
                1 for e in reg_after.get('entries', []) if e.get('selected')),
            'baseline_dead_declaration_present': entries_by_suffix(
                reg_after, '::fn:releaseUnreachable') is not None,
            'baseline_dead_version_after_install':
                calls.get('unreachable.version.1'),
            'baseline_seen_at_materialization': base_pre.get(
                'selected_seen_at_materialization'),
            'baseline_retained_at_materialization': base_pre.get(
                'retained_at_materialization'),
            'baseline_dropped_at_materialization': base_pre.get(
                'dropped_at_materialization'),
            'baseline_returncode': r.returncode,

            'defect_registry_entries': len(ret_reg.get('entries', [])),
            'defect_selected_entries': sum(
                1 for e in ret_reg.get('entries', []) if e.get('selected')),
            'defect_dead_declaration_present': entries_by_suffix(
                ret_reg, '::fn:releaseUnreachable') is not None,
            'defect_reachable_declaration_present': entries_by_suffix(
                ret_reg, '::fn:tiny') is not None,
            'defect_install': ret_c.get('install.unreachable'),
            'defect_dead_version_after_install':
                ret_c.get('unreachable.version.1'),
            'defect_returncode': ret_r.returncode,
            'defect_runtime_error': (ret_r.stderr or '').strip()[-160:],
            # The discrimination: registered and then dropped, not absent.
            'defect_seen_at_materialization': ret_pre.get(
                'selected_seen_at_materialization'),
            'defect_retained_at_materialization': ret_pre.get(
                'retained_at_materialization'),
            'defect_dropped_at_materialization': ret_pre.get(
                'dropped_at_materialization'),
            # The other instrument, for contrast: never registered at all.
            'defect_decisions': len(ret_pre.get('optimizer_decisions', [])),
            'no_seeding_seen_at_materialization': noseed_pre.get(
                'selected_seen_at_materialization'),
            'no_seeding_dropped_at_materialization': noseed_pre.get(
                'dropped_at_materialization'),
            'no_seeding_decisions': len(
                noseed_pre.get('optimizer_decisions', [])),
            'no_seeding_returncode': noseed_r.returncode,

            'finding':
                'withholding the retention root removes EVERY mutable '
                'declaration, not only the dead one, because #67 lowering '
                'replaces the static call with an indirect load from the '
                'dispatch cell -- so the precompiler no longer sees a '
                'static-call edge to the callee. The root is not redundant '
                'with ordinary reachability; it is the only thing that '
                'retains a mutable declaration.',
        }
        obs['injected_retention_defect'] = ret
        ret['verdict_under_defect'] = perturbed(
            calls=ret_c, registry_after=ret_reg,
            optimizer_decisions=ret_reg.get('optimizer_decisions', []),
        )['arm64_aot_optimizer_invariants']
        arm('H12', 'the retention root is what keeps a mutable declaration in '
                   'the program at all. Withhold it and the precompiler drops '
                   'every one of them -- including the ones the release '
                   'calls, because the dispatch-cell lowering left no '
                   'static-call edge to follow -- so the dead-code case is '
                   'not separable and the program does not run.',
            V.evaluate(dict(obs), [])['conditions'][
                'injected_retention_defect_is_caught'],
            f"baseline: {ret['baseline_seen_at_materialization']} selected "
            f"seen, {ret['baseline_retained_at_materialization']} retained, "
            f"{ret['baseline_dropped_at_materialization']} dropped; the dead "
            f"declaration installs and goes "
            f"{calls.get('unreachable.version.0')} -> "
            f"{ret['baseline_dead_version_after_install']}. Under "
            f"--maot_disable_retention_roots: "
            f"{ret['defect_seen_at_materialization']} seen, "
            f"{ret['defect_retained_at_materialization']} retained, "
            f"{ret['defect_dropped_at_materialization']} DROPPED, registry "
            f"empty, and the program aborts "
            f"({ret['defect_returncode']}): "
            f"{ret['defect_runtime_error']}. --maot_disable_seeding reaches "
            f"the SAME retention outcome "
            f"({ret['no_seeding_seen_at_materialization']} seen, "
            f"{ret['no_seeding_dropped_at_materialization']} dropped) because "
            f"AddFunction is the only retention effect seeding has; the two "
            f"differ only in the disposition records seeding emits "
            f"({ret['defect_decisions']} vs {ret['no_seeding_decisions']})",
            ret['verdict_under_defect'])

        # ---- H17: an INJECTED TFA defect, one layer at a time -----------
        # There are two layers: the front end suppresses the constant, and the
        # VM refuses to trust that it did. Removing only the first proves the
        # backstop works; removing both produces the raw defect -- which is
        # the one that actually shipped, with eleven call sites all reaching
        # the cell and every caller printing the release answer anyway.
        #
        # Measured separately because "install refused" alone does not
        # discriminate: a refused install trivially leaves the caller on the
        # release answer, whatever the reason.
        def _const_decisions(reg):
            return [d for d in reg.get('optimizer_decisions', [])
                    if d['optimization_class'] == 'constant-folding']

        one_b = build('tfa_one_layer', (),
                      kernel_env={'MAOT_ALLOW_CONSTANT_FOLDING': '1'})
        one_r = one_b.run()
        one_c = parse_calls(one_r.stdout)
        one_reg = one_b.registry()
        both_b = build('tfa_both_layers', ['--maot_disable_constant_backstop'],
                       kernel_env={'MAOT_ALLOW_CONSTANT_FOLDING': '1'})
        both_r = both_b.run()
        both_c = parse_calls(both_r.stdout)
        both_reg = both_b.registry()
        tfa = {
            'baseline_call_after_install': calls.get('constantish.1'),
            'baseline_constant_folding_decisions': len(
                _const_decisions(reg_after)),
            'baseline_call_sites': (entries_by_suffix(
                reg_after, '::fn:constantish') or {}).get(
                    'indirect_call_sites_emitted'),
            'one_layer_removed': 'MAOT_ALLOW_CONSTANT_FOLDING=1',
            'one_layer_constant_folding_decisions': len(
                _const_decisions(one_reg)),
            'one_layer_install': one_c.get('install.constantish'),
            'one_layer_installable': (entries_by_suffix(
                one_reg, '::fn:constantish') or {}).get('installable'),
            'one_layer_call_after_install': one_c.get('constantish.1'),
            'both_layers_removed':
                'MAOT_ALLOW_CONSTANT_FOLDING=1 + '
                '--maot_disable_constant_backstop',
            'both_layers_constant_folding_decisions': len(
                _const_decisions(both_reg)),
            'both_layers_install': both_c.get('install.constantish'),
            'both_layers_installable': (entries_by_suffix(
                both_reg, '::fn:constantish') or {}).get('installable'),
            'both_layers_call_after_install': both_c.get('constantish.1'),
            'both_layers_hot_call': both_c.get('hot.constantish'),
            'both_layers_call_sites': (entries_by_suffix(
                both_reg, '::fn:constantish') or {}).get(
                    'indirect_call_sites_emitted'),
        }
        obs['injected_tfa_defect'] = tfa
        tfa['one_layer_verdict'] = perturbed(
            calls=one_c, registry_after=one_reg,
            optimizer_decisions=one_reg.get('optimizer_decisions', []),
        )['arm64_aot_optimizer_invariants']
        tfa['both_layers_verdict'] = perturbed(
            calls=both_c, registry_after=both_reg,
            optimizer_decisions=both_reg.get('optimizer_decisions', []),
        )['arm64_aot_optimizer_invariants']
        arm('H17', 'TFA can materialize a mutable result as a constant, so a '
                   'caller uses the release answer without consulting the '
                   'cell -- while the call site is still emitted and the path '
                   'evidence still looks perfect. One layer removed shows the '
                   'VM backstop refusing; both removed produce the raw defect.',
            V.evaluate(dict(obs), [])['conditions'][
                'injected_tfa_defect_is_caught'],
            f"baseline: {tfa['baseline_call_sites']} indirect call sites, "
            f"{tfa['baseline_constant_folding_decisions']} constant-folding "
            f"decisions, caller returns {tfa['baseline_call_after_install']}; "
            f"front end only: "
            f"{tfa['one_layer_constant_folding_decisions']} decisions, "
            f"install {tfa['one_layer_install']}; both layers removed: "
            f"{tfa['both_layers_constant_folding_decisions']} decisions, "
            f"install {tfa['both_layers_install']} SUCCEEDS and the caller "
            f"still returns {tfa['both_layers_call_after_install']} "
            f"(cold) / {tfa['both_layers_hot_call']} (hot) from "
            f"{tfa['both_layers_call_sites']} emitted call sites",
            tfa['both_layers_verdict'])

        # ---------------- escape controls ----------------
        BY = '--maot_disable_call_indirection'
        base_s, _, _ = summarize(main_b)
        byp = build('bypass', [BY])
        byp_s, byp_c, byp_reg = summarize(byp)
        nod = build('no_detect', [BY, '--maot_disable_escape_detection'])
        nod_s, _, _ = summarize(nod)
        drp = build('drop_state',
                    [BY, '--maot_drop_escape_state_at_materialization'])
        drp_s, _, drp_reg = summarize(drp)
        # consumption is an INSTALL-time flag: it governs dartaotruntime, not
        # gen_snapshot. Passing it to the snapshotter does nothing, which is
        # how this case first looked like it did not reproduce.
        noc_s, _, _ = summarize(byp, run_extra=['--maot_ignore_escapes_on_install'])
        obs['escape_controls'] = {'baseline': base_s, 'bypass': byp_s,
                                  'no_detect': nod_s, 'no_consume': noc_s,
                                  'drop_state': drp_s}
        for aid, key, why in (
                ('H01', 'no_detect', 'without detection a bypass installs and '
                                     'the program keeps the release answer'),
                ('H02', 'no_consume', 'metadata produced but unread must fail '
                                      'exactly like no metadata at all'),
                ('H03', 'drop_state', 'state lost in the rebuild silently '
                                      're-opens every disqualified '
                                      'declaration')):
            s = obs['escape_controls'][key]
            arm(aid, why, s['install'] == 0 and s['call'] == 'OLD-TINY',
                f"{key}: install {s['install']}, call {s['call']}, escapes "
                f"{s['escapes']} -- versus bypass install {byp_s['install']}")

        # The projection must survive to the consumer; a consumed_by string
        # must never be enough. drop_state leaves the FORBIDDEN decision
        # serialized while the descriptor's escape count is zero.
        def blocking_count(reg):
            return sum(1 for d in reg.get('optimizer_decisions', [])
                       if d['disposition'] in R.BLOCKING)

        def proj(reg, suffix='::fn:tiny'):
            e = next((x for x in reg.get('entries', [])
                      if x['declaration_id'].endswith(suffix)), {})
            return e.get('optimizer_escapes', -1)

        obs['blocking_projection'] = {
            'blocking_decisions': blocking_count(byp_reg),
            'escape_projection': proj(byp_reg),
            'install_refused': byp_s['install'] == -3,
            'drop_state_decisions': blocking_count(drp_reg),
            'drop_state_projection': proj(drp_reg),
            'drop_state_install_refused': drp_s['install'] == -3,
            'note': 'the dropped-state build still carries blocking decisions '
                    'whose consumed_by claims StageReplacement reads them, '
                    'while the projection is gone and installation succeeds. '
                    'That is why the string is not the proof.',
        }
        bp = obs['blocking_projection']
        arm('H02x' if False else 'H06',
            'a blocking disposition that does not block, and a consumed_by '
            'string that claims a consumer the projection no longer reaches',
            bp['blocking_decisions'] > 0 and bp['escape_projection'] > 0
            and bp['install_refused'] is True
            and bp['drop_state_decisions'] > 0
            and bp['drop_state_projection'] == 0
            and bp['drop_state_install_refused'] is False,
            f"bypass: {bp['blocking_decisions']} blocking decisions, "
            f"projection {bp['escape_projection']}, refused. "
            f"drop-state: {bp['drop_state_decisions']} blocking decisions "
            f"still serialized, projection {bp['drop_state_projection']}, "
            f"installed anyway")

        # ---------------- disposition effects, measured ----------------
        effects = {}
        for d in ('SLOT_PRESERVING', 'DEPENDENCY_REQUIRED',
                  'UNMODELED_BLOCKING', 'FORBIDDEN'):
            b = build(f'disp_{d}', [f'--maot_inject_disposition={d}'])
            s, _, _ = summarize(b)
            effects[d] = s
        obs['disposition_effects'] = effects
        arm('H05', 'DEPENDENCY_REQUIRED with no dependency token and no '
                   'consumer would admit an optimization on a promise',
            effects['DEPENDENCY_REQUIRED']['install'] == -3,
            f"DEPENDENCY_REQUIRED: install "
            f"{effects['DEPENDENCY_REQUIRED']['install']}, call "
            f"{effects['DEPENDENCY_REQUIRED']['call']}")
        arm('H07', 'a model that blocks every disposition carries no '
                   'information; SLOT_PRESERVING must NOT block',
            effects['SLOT_PRESERVING']['install'] == 0
            and effects['SLOT_PRESERVING']['call'] == 'NEW-TINY'
            and all(effects[d]['install'] == -3 for d in R.BLOCKING),
            'SLOT_PRESERVING installs and runs the replacement; '
            + ', '.join(f"{d}={effects[d]['install']}" for d in R.BLOCKING))

        # ---------------- the historical constant-folding defect ----------
        fold = build('constant_fold',
                     kernel_env={'MAOT_ALLOW_CONSTANT_FOLDING': '1'})
        fold_s, fold_c, fold_reg = summarize(fold)
        fold_tiny = next((x for x in fold_reg.get('entries', [])
                          if x['declaration_id'].endswith('::fn:tiny')), {})
        arm('H04', 'the call still reaches the cell and the caller uses the '
                   'folded release answer -- path evidence perfect, program '
                   'wrong. This shipped once.',
            (fold_tiny.get('indirect_call_sites_emitted') or 0) > 0
            and fold_s['escapes'] > 0 and fold_s['install'] == -3
            and fold_s['call'] == 'OLD-TINY',
            f"folding re-enabled: "
            f"{fold_tiny.get('indirect_call_sites_emitted')} call sites still "
            f"emitted, {fold_s['escapes']} escapes recorded, install "
            f"{fold_s['install']}, call {fold_s['call']}")

        # ---------------- optimized versus conservative AOT ----------------
        cons = build('conservative', CONSERVATIVE_FLAGS)
        cons_r = cons.run()
        cons_c = parse_calls(cons_r.stdout)
        # MUTATION SEMANTICS only. Timings and the pid are expected to differ
        # between two builds; comparing them would make the control fail for
        # reasons that have nothing to do with whether a replacement is
        # observed -- which is exactly what it did the first time.
        compared = [k for k in calls
                    if k not in ('process.pid', 'process.pid.final')
                    and not k.startswith('bench.')
                    and not k.startswith('hot.iterations')]
        disagreements = [
            {'key': k, 'optimized': calls[k], 'conservative': cons_c.get(k)}
            for k in compared if cons_c.get(k) != calls[k]]
        obs['conservative_control'] = {
            'flags': CONSERVATIVE_FLAGS,
            'compared': len(compared),
            'disagreements': disagreements,
            'compares': 'mutation semantics only -- installs, observed '
                        'values and versions. Timings differ between builds '
                        'by design and are reported separately.',
            'note': 'the amended #68 text makes test 10 optimized AOT versus '
                    'a conservative AOT control, not a second JIT mechanism. '
                    '#64\'s jit value stays a control concept.',
        }
        arm('H14', 'if optimization changed mutation semantics, the '
                   'conservative posture would be the only thing making them '
                   'work',
            not disagreements and len(compared) > 10,
            f'{len(compared)} observations compared against '
            f'{" ".join(CONSERVATIVE_FLAGS)}, {len(disagreements)} '
            f'disagreements')

        # ---------------- H11: no whole-row promotion ----------------
        arm('H11', 'promoting a whole #64 row from one dispatch mode is an '
                   'overclaim, and #68 adds no cell to what #67 linked',
            all(v['row_result_after_68'] == 'UNMODELED'
                for v in V.T0_ROW_LINKAGE.values())
            and V.T0_ROW_LINKAGE['RS-09']['covered_by_issue_68'] == {}
            and 't0_rows_promoted' not in obs,
            f"{len(V.T0_ROW_LINKAGE)} rows linked, all still UNMODELED; "
            f"RS-09 claims no modes at all")

        # ---------------- H13: stale build ----------------
        edited = dict(build_digests())
        victim = 'runtime/vm/compiler/backend/flow_graph_compiler_arm64.cc'
        edited[victim] = 'f' * 64
        hyp = provenance(override=edited)
        v13 = perturbed(build_digest_matches=False)
        arm('H13', 'a run that measures binaries built from other source '
                   'bytes names a program it did not test',
            obs['build_digest_matches'] is True and len(hyp) == 1
            and hyp[0].get('file') == victim
            and v13['arm64_aot_optimizer_invariants'] == 'NOT_ESTABLISHED',
            f"toolchain matches all {len(MAOT_CXX_SOURCES)} sources; against "
            f"one edited source the guard reports {len(hyp)} mismatch",
            v13['arm64_aot_optimizer_invariants'])

        # ---- H18: the source-to-COMMIT binding must be able to fire ----
        # H13 proves the binary is bound to the bytes. It cannot see a dirty
        # worktree, because the bytes it compares against are the dirty ones.
        # This arm perturbs what the NAMED COMMIT is held to contain, which is
        # the shape the real defect had: HEAD at 2e4df989, worktree holding
        # what became b92efd82, every existing check green, and the record
        # naming a revision whose bytes were never measured.
        victim18 = 'runtime/vm/maot_registry.cc'
        fake_head = dict(head_digests())
        fake_head[victim18] = 'f' * 64
        unbound18, _ = source_commit_binding(override_head=fake_head)
        v18 = perturbed(sources_match_named_commit=False,
                        source_commit_binding_mismatches=unbound18)
        untracked = dict(head_digests())
        untracked[victim18] = None
        unbound18b, _ = source_commit_binding(override_head=untracked)
        obs['source_commit_binding_falsification'] = {
            'live_mismatches': obs['source_commit_binding_mismatches'],
            'perturbed_mismatches': unbound18,
            'untracked_mismatches': unbound18b,
        }
        arm('H18', 'a dirty worktree lets a record name a commit it did not '
                   'measure. The binary matches the bytes, the bytes match '
                   'the digest, and the commit named in the evidence contains '
                   'something else entirely -- which is exactly how #68\'s '
                   'first closure attempt shipped.',
            obs['sources_match_named_commit'] is True
            and (obs['build_digest'] or {}).get('fork_commit')
                == (obs['fork_identity'] or {}).get('head')
            and len(unbound18) == 1
            and unbound18[0].get('file') == victim18
            and unbound18[0]['problem'] == 'source differs from the named commit'
            and len(unbound18b) == 1
            and unbound18b[0]['problem']
                == 'source is not tracked at the named commit'
            and v18['conditions']['build_provenance_bound'] is False
            and v18['arm64_aot_optimizer_invariants'] == 'NOT_ESTABLISHED',
            f"live: every tracked source equals its blob at "
            f"{((obs['fork_identity'] or {}).get('head') or '')[:12]}, which "
            f"is the commit the build record names; against one source "
            f"differing from that commit the guard reports "
            f"{len(unbound18)} mismatch, and against one absent from it "
            f"{len(unbound18b)}",
            v18['arm64_aot_optimizer_invariants'])

        # ---------------- measurements ----------------
        sites = sum((e.get('indirect_call_sites_emitted') or 0)
                    for e in reg_after.get('entries', []))
        decs = obs['optimizer_decisions']
        obs['measurements'] = {
            'aot_elf_bytes': os.path.getsize(main_b.aot),
            'aot_elf_bytes_conservative': os.path.getsize(cons.aot),
            'compile_seconds': main_b.compile_seconds,
            'compile_seconds_conservative': cons.compile_seconds,
            'indirect_call_sites_total': sites,
            'prevented_inlines': sum(
                (e.get('inline_refusals') or 0)
                for e in reg_after.get('entries', [])),
            'inline_admissions': sum(
                (e.get('inline_admissions') or 0)
                for e in reg_after.get('entries', [])),
            'mutable_declarations_marked_non_inlinable': sum(
                1 for e in reg_after.get('entries', []) if e.get('selected')),
            'prevented_inlines_note':
                'counted in the inliner itself, per refusal, not inferred '
                'from the size of the selected set. An earlier version of '
                'this lane reported the selected count under this name and '
                'called a per-refusal counter "a statistic no decision '
                'reads"; it has two consumers now -- refusals > 0 is the '
                'precondition for H10 (an inliner that never looked at the '
                'callee cannot have been prevented from taking it), and '
                'admissions must be 0 in any shipped build.',
            'devirtualizations_recorded': sum(
                1 for d in decs if d['optimization_class'] == 'devirtualization'),
            'blocking_decisions': sum(
                1 for d in decs if d['disposition'] in R.BLOCKING),
            'slot_preserving_decisions': sum(
                1 for d in decs if d['disposition'] == 'SLOT_PRESERVING'),
            'benchmark_iterations': calls.get('bench.iterations'),
            'direct_call_ns_mutable': _ns(calls, 'bench.mutable.us'),
            'direct_call_ns_control': _ns(calls, 'bench.control.us'),
            'call_cost_note':
                'minimum of three samples, control is a non-selected '
                'never-inlined function. #67 measured the same shape and '
                'found the difference below same-arm sample variation; this '
                'lane reports the numbers and repeats that caveat rather '
                'than publishing a per-call overhead it cannot resolve.',
            'note': 'diagnostic only; no threshold is compared anywhere.',
        }

        # ---------------- scale lane (blocker 4) ----------------
        # Produced by lib/scale_m4.py against a representative Flutter
        # application. Read from disk rather than re-run here: it compiles the
        # framework twice and takes minutes, and a gate that silently reruns
        # it would hide whether the record is from this revision. The
        # provenance check below is what makes reading a file safe.
        scale_path = os.path.join(m4_dir, 'evidence', 'm4_scale.json')
        if os.path.exists(scale_path):
            sc = json.load(open(scale_path))
            sc['from_fork_commit'] = (obs['build_digest'] or {}).get(
                'fork_commit')
            sc['fork_commit_at_measurement'] = sc.get('fork_commit')
            sc['measured_on_this_revision'] = (
                sc.get('fork_commit') is not None
                and sc.get('fork_commit') == sc['from_fork_commit'])
            obs['scale_measurements'] = sc
            if not sc.get('measured_on_this_revision'):
                finding('SCALE_LANE_FROM_ANOTHER_REVISION',
                        f"evidence/m4_scale.json names fork commit "
                        f"{sc.get('fork_commit')}, the binaries were built "
                        f"from {sc['from_fork_commit']}")
        else:
            obs['scale_measurements'] = {}
            finding('SCALE_LANE_NOT_RUN',
                    'evidence/m4_scale.json is absent; the #68 performance '
                    'accounting has no application-scale counts. Run '
                    'lib/scale_m4.py.')
    except _NotMeasured:
        pass
    except Exception:  # noqa: BLE001 -- recorded, never swallowed
        # A gate that raises writes no record at all, which reads exactly like
        # a gate that was never run. Same family as `raise SystemExit(0)`:
        # silence is indistinguishable from success. The traceback becomes a
        # blocking finding and the evidence file is still produced.
        import traceback
        obs['gate_traceback'] = traceback.format_exc()
        finding('GATE_RAISED',
                traceback.format_exc().strip().splitlines()[-1])
        print(obs['gate_traceback'], file=sys.stderr)
    finally:
        shutil.rmtree(work, ignore_errors=True)

    live = sorted(k for k, (kind, _) in V.BANK.items() if kind == 'live')
    failed = [a['id'] for a in arms if a['result'] != 'pass']
    obs['falsifications_failed'] = failed
    obs['live_arm_count'] = len(arms)
    if failed:
        finding('FALSIFICATION_ARM_FAILED', ', '.join(failed))
    missing = [k for k in live if k not in {a['id'] for a in arms}]
    if missing and not any(f['code'] == 'FORK_NOT_ON_MAOT_REVISION'
                           for f in findings):
        finding('FALSIFICATION_ARM_ABSENT', ', '.join(missing))

    verdict = V.evaluate(obs, findings)
    for u in verdict['acceptance_ledger']:
        if not u['met']:
            finding('ACCEPTANCE_ITEM_NOT_MET', f"{u['item']}: not met")

    record = {
        'schema': 'maot.m4.evidence/1',
        'issue': 68,
        'generated_by': {
            'run_id': run_id,
            'gate_sha256': sha256_file(os.path.abspath(__file__)),
            'verdict_sha256': sha256_file(os.path.join(
                os.path.dirname(os.path.abspath(__file__)), 'verdict_m4.py')),
            'rules_sha256': sha256_file(os.path.join(
                os.path.dirname(os.path.abspath(__file__)), 'rules_m4.py')),
            'fixture_sha256': hashlib.sha256(fixture.encode()).hexdigest(),
        },
        'identities': {
            'shorebird_revision': git(repo, 'rev-parse', 'HEAD'),
            'shorebird_tree': git(repo, 'rev-parse', 'HEAD^{tree}'),
            'fork_commit': git(FORK, 'rev-parse', 'HEAD'),
            'fork_tree': git(FORK, 'rev-parse', 'HEAD^{tree}'),
            'namespace_identity': NAMESPACE,
            'target_arch': V.TARGET_ARCH,
            'depends_on': {'issue_66': 'ESTABLISHED', 'issue_67': 'READY'},
        },
        'observations': obs,
        'registry_after': obs.get('registry_after', {}),
        'optimizer_decisions': obs.get('optimizer_decisions', []),
        'falsification': arms,
        'falsification_bank': {
            'live': live,
            'historical': sorted(k for k, (kind, _) in V.BANK.items()
                                 if kind == 'historical'),
            'historical_note': 'none yet in this lane',
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
    record['verdict'] = V.evaluate(obs, findings)

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, 'w') as fh:
        json.dump(record, fh, indent=2)
        fh.write('\n')

    v = record['verdict']
    blocking = [f for f in findings if f['severity'] == 'blocking']
    c = obs.get('calls') or {}
    print(f"fork          {record['identities']['fork_commit']}")
    print(f"rules         {len(R.RULES)} optimizer classes")
    print(f"variants      tiny {c.get('tiny.0')} -> {c.get('tiny.1')} -> "
          f"{c.get('tiny.2')} | chain {c.get('chain.1')}")
    print(f"devirt        install {c.get('install.devirt')} (refused: "
          f"instance dispatch is #69) | join "
          f"{(obs.get('devirtualization_join') or {}).get('devirtualization_slot_preserving')}"
          f"+{(obs.get('devirtualization_join') or {}).get('static_call_lowering_slot_preserving')}")
    print(f"arms          {len(arms)} ({len(failed)} failed)")
    print(f"blocking      {len(blocking)}")
    print(f"conditions    {len(v['conditions'])} "
          f"({len(v['conditions_failed'])} failed)")
    for k in v['conditions_failed']:
        print(f'  unmet: {k}')
    for f in blocking[:6]:
        print(f"  {f['code']}: {f['message'][:100]}")
    print(f"PHASE A       arm64_aot_optimizer_invariants = "
          f"{v['arm64_aot_optimizer_invariants']}")
    print(f"CLOSURE       issue_68_closure = {v['issue_68_closure']}")
    return 0 if v['arm64_aot_optimizer_invariants'] == 'ESTABLISHED' else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
