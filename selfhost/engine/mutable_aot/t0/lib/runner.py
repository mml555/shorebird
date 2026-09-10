#!/usr/bin/env python3
"""MAOT-T0 (#64) -- compile and run one fixture, and record what happened.

What runs today is real: the release program is compiled in both optimizer
modes, executed cold and hot, and every dispatch mode's observation is checked
against the fixture's declared pre-patch value. That already catches a broken
or non-discriminating fixture, which is why the harness is useful before the
mechanism exists.

What does NOT happen today is the patch. The `none` backend refuses, so every
row lands on UNMODELED.

`patch.dart` is also compiled and run STANDALONE, and its result is recorded
as `patch_source_baseline`. It proves the fixture's expected_post is
achievable by a rebuilt program. It is NEVER used as a post-patch observation:
a rebuilt process is exactly the "restart and call it a patch" false positive
(#64 control 9), and control A09 exists to prove the harness rejects the
substitution.
"""

import hashlib
import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mechanism as MECH      # noqa: E402
import schema as S            # noqa: E402

OBS_PREFIX = 'T0OBS '


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b''):
            h.update(chunk)
    return h.hexdigest()


def find_toolchain():
    """Identify the Dart SDK by revision, never by the path it sits at."""
    candidates = [
        os.environ.get('DART_SDK'),
        '/opt/homebrew/share/flutter/bin/cache/dart-sdk',
    ]
    for base in candidates:
        if not base:
            continue
        dart = os.path.join(base, 'bin', 'dart')
        aot = os.path.join(base, 'bin', 'dartaotruntime')
        if os.path.isfile(dart) and os.path.isfile(aot):
            rev = None
            rev_path = os.path.join(base, 'revision')
            if os.path.isfile(rev_path):
                with open(rev_path, encoding='utf-8') as fh:
                    rev = fh.read().strip()
            try:
                ver = subprocess.run([dart, '--version'], capture_output=True,
                                     text=True, timeout=60).stderr.strip() or \
                    subprocess.run([dart, '--version'], capture_output=True,
                                   text=True, timeout=60).stdout.strip()
            except Exception:
                ver = None
            return {
                'dart': dart, 'dartaotruntime': aot,
                'sdk_revision': rev, 'version_string': ver,
                'identity_note': (
                    'The SDK is identified by its revision, not by the path '
                    'this machine keeps it at. A path is a location; the '
                    'revision is the identity.'),
            }
    return None


def parse_observations(stdout, optimizer_mode, heat_mode):
    out = []
    for line in stdout.splitlines():
        if not line.startswith(OBS_PREFIX):
            continue
        rec = json.loads(line[len(OBS_PREFIX):])
        rec['optimizer_mode'] = optimizer_mode
        rec['heat_mode'] = heat_mode
        out.append(rec)
    return out


def run_source(tool, source_path, optimizer_mode, heat_mode, phase, workdir):
    """Compile and run one source in one mode. Returns (observations, error)."""
    heat = S.HEAT_ITERATIONS[heat_mode]
    args = [f'--phase={phase}', f'--heat={heat}']
    try:
        if optimizer_mode == 'jit':
            proc = subprocess.run(
                [tool['dart'], 'run', source_path] + args,
                capture_output=True, text=True, timeout=900)
        elif optimizer_mode == 'aot':
            snap = os.path.join(
                workdir,
                os.path.basename(os.path.dirname(source_path)) + '_' +
                os.path.basename(source_path) + '.aot')
            if not os.path.isfile(snap):
                comp = subprocess.run(
                    [tool['dart'], 'compile', 'aot-snapshot', source_path,
                     '-o', snap],
                    capture_output=True, text=True, timeout=900)
                if comp.returncode != 0 or not os.path.isfile(snap):
                    return [], {'reason': 'COMPILE_FAILED',
                                'detail': (comp.stderr or comp.stdout)[-800:]}
            proc = subprocess.run([tool['dartaotruntime'], snap] + args,
                                  capture_output=True, text=True, timeout=900)
        else:
            return [], {'reason': 'RUN_FAILED',
                        'detail': f'unknown optimizer mode {optimizer_mode!r}'}
    except subprocess.TimeoutExpired:
        return [], {'reason': 'RUN_FAILED', 'detail': 'timeout'}

    if proc.returncode != 0:
        return [], {'reason': 'RUN_FAILED',
                    'detail': (proc.stderr or proc.stdout)[-800:]}
    obs = parse_observations(proc.stdout, optimizer_mode, heat_mode)
    if not obs:
        return [], {'reason': 'RUN_FAILED',
                    'detail': 'the program emitted no observations'}
    return obs, None


def run_fixture(t0_dir, row_id, fixture, tool, mechanism_name='none',
                mock_defect=None, workdir=None):
    result = S.blank_row_result(row_id, fixture.get('gate_id'))
    result['expected_pre'] = fixture.get('expected_pre')
    result['expected_post'] = fixture.get('expected_post')
    result['mechanism'] = mechanism_name
    result['toolchain'] = {k: v for k, v in (tool or {}).items()
                           if k in ('sdk_revision', 'version_string')}
    result['old_state_existed'] = bool(fixture.get('old_state_required'))
    result['generator'] = 'runner.py'
    result['executable'] = bool(fixture.get('executable'))

    if not fixture.get('executable'):
        result['result'] = 'UNMODELED'
        result['reasons'] = ['FIXTURE_MISSING']
        result['install_result'] = {
            'attempted': False,
            'detail': fixture.get('placeholder_reason')}
        return result

    if tool is None:
        result['result'] = 'INFRA_FAILURE'
        result['reasons'] = ['RUN_FAILED']
        result['install_result'] = {'attempted': False,
                                    'detail': 'no Dart SDK found'}
        return result

    row_dir = os.path.join(t0_dir, 'corpus', row_id)
    rel_src = os.path.join(row_dir, 'release.dart')
    pat_src = os.path.join(row_dir, 'patch.dart')
    result['release_source_sha256'] = sha256_file(rel_src)
    result['patch_source_sha256'] = sha256_file(pat_src)

    owns_workdir = workdir is None
    workdir = workdir or tempfile.mkdtemp(prefix='t0_')

    pre, errors = [], []
    for om in fixture['optimizer_modes']:
        for hm in fixture['heat_modes']:
            obs, err = run_source(tool, rel_src, om, hm, 'pre', workdir)
            if err:
                errors.append({'mode': f'{om}/{hm}', **err})
            pre.extend(obs)
    result['pre_observation'] = pre

    # The rebuilt-patch baseline. Recorded, never a post observation.
    baseline, baseline_err = run_source(
        tool, pat_src, fixture['optimizer_modes'][0], 'cold', 'pre', workdir)
    result['patch_source_baseline'] = {
        'observations': baseline,
        'error': baseline_err,
        'is_not_a_post_observation': (
            'A standalone run of patch.dart is a REBUILT PROGRAM in a NEW '
            'process. It shows the expectation is achievable; it says nothing '
            'about installing a patch into a running one. Substituting it for '
            'post_observation is #64 control 9, and A09 proves it is caught.'),
    }

    if errors:
        result['result'] = 'INFRA_FAILURE'
        result['reasons'] = sorted({e['reason'] for e in errors})
        result['install_result'] = {'attempted': False, 'errors': errors}
        return result

    backend = MECH.backend(mechanism_name, mock_defect)
    install, post = backend.install(fixture, pre)
    result['install_result'] = install
    result['post_observation'] = post
    result['process_restarted'] = (
        None if not post else
        {o['nonce'] for o in post} != {o['nonce'] for o in pre})

    verdict, reasons = MECH.classify(fixture, pre, install, post,
                                     mechanism_name)
    result['result'] = verdict
    result['reasons'] = reasons
    result['mode_results'] = [
        {'dispatch': o['dispatch'], 'optimizer_mode': o['optimizer_mode'],
         'heat_mode': o['heat_mode'], 'pre_value': o['value'],
         'post_value': next(
             (p['value'] for p in (post or [])
              if p['dispatch'] == o['dispatch'] and
              p['optimizer_mode'] == o['optimizer_mode'] and
              p['heat_mode'] == o['heat_mode']), None)}
        for o in pre]
    result['path_evidence'] = {
        'available': False,
        'why': (
            'Answering "did this invocation reach the mutable mechanism" '
            'needs IR or runtime tracing from a mechanism that does not '
            'exist yet. The field is carried so #67 fills it rather than '
            'inventing a schema, and its absence is recorded rather than '
            'implied. Behavioural agreement alone is NOT path evidence.'),
    }
    if owns_workdir:
        pass  # left in place; the caller's temp dir cleanup owns it
    return result
