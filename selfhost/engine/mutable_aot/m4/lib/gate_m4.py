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
        if a in ('fork_commit', 'fork_tree', 'built_at'):
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
        r = subprocess.run(
            [os.path.join(OUT, 'gen_snapshot'), '--snapshot_kind=app-aot-elf',
             f'--elf={self.aot}', f'--maot_namespace={NAMESPACE}']
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
            'instance_dispatch_unmodeled_blocking': sum(
                1 for d in rows if d['optimization_class'] == 'instance-dispatch'
                and d['disposition'] == 'UNMODELED_BLOCKING'),
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

        arm('H10', 'a vm:prefer-inline mutable callee that got inlined could '
                   'not observe a replacement; the rule must beat an explicit '
                   'inline request',
            calls.get('tiny.0') == 'OLD-TINY'
            and calls.get('tiny.1') == 'NEW-TINY'
            and calls.get('hot.tiny') == 'NEW-TINY',
            f"prefer-inline callee: {calls.get('tiny.0')} -> "
            f"{calls.get('tiny.1')}, still {calls.get('hot.tiny')} after "
            f"{calls.get('hot.iterations')} iterations")

        arm('H12', 'a declaration the release never calls must stay '
                   'addressable, or dead code becomes unpatchable',
            calls.get('unreachable.version.0') == 'AOT:v1'
            and calls.get('install.unreachable') == 0
            and calls.get('unreachable.version.1') == 'PATCH_CODE:v2',
            f"never called by the release: "
            f"{calls.get('unreachable.version.0')} -> "
            f"{calls.get('unreachable.version.1')}, install "
            f"{calls.get('install.unreachable')}")

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
                1 for e in reg_after.get('entries', []) if e.get('selected')),
            'prevented_inlines_note':
                'every selected declaration is marked non-inlinable, so the '
                'count of selected declarations IS the count of declarations '
                'the inliner may not take. A per-call-site count of refusals '
                'would need an inliner-side counter, which would be a '
                'statistic no decision reads.',
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
    except _NotMeasured:
        pass
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
