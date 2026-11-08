#!/usr/bin/env python3
"""MAOT-1 (#65) -- run the cases, the detectors and the arms; record the lot.

usage: gate_m1.py <m1-dir> <out.json>
"""

import datetime
import hashlib
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cases as C            # noqa: E402
import falsify_m1 as F       # noqa: E402
import harness as H          # noqa: E402
import verdict as V          # noqa: E402


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b''):
            h.update(chunk)
    return h.hexdigest()


def git_head(root):
    try:
        out = subprocess.run(['git', '-C', root, 'rev-parse', 'HEAD'],
                             capture_output=True, text=True, timeout=30)
        return out.stdout.strip() if out.returncode == 0 else None
    except Exception:
        return None


def check_consumers(record):
    meta = set()
    produced = set(record) - meta
    named = set(V.CONSUMERS)
    problems = []
    for key in sorted(produced - named):
        problems.append(
            f'{key!r} is computed but no decision is declared to consume it')
    for key in sorted(named - produced):
        problems.append(
            f'CONSUMERS names {key!r}, which the record does not produce')
    return problems


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    m1_dir, out_path = os.path.abspath(argv[1]), argv[2]
    repo = os.path.abspath(os.path.join(m1_dir, '..', '..', '..', '..'))
    run_id = datetime.datetime.now(datetime.timezone.utc).strftime(
        '%Y-%m-%dT%H:%M:%SZ')

    findings = []
    if not H.available():
        findings.append({
            'code': 'FORK_UNAVAILABLE', 'severity': 'blocking',
            'message': 'the Dart fork worktree, SDK or platform dill is not '
                       'reachable; identity cannot be measured'})
        record = {
            'schema': 'maot.m1.evidence/1', 'issue': 65,
            'generated_by': {'run_id': run_id, 'repo_revision': git_head(repo)},
            'fork_identity': None, 'manifests': {}, 'cases': [],
            'findings': findings, 'falsification': [],
            'verdict': V.derive([], findings, None, {}),
            'consumers': {},
        }
        with open(out_path, 'w', encoding='utf-8') as fh:
            json.dump(record, fh, indent=2)
        print('FORK_UNAVAILABLE')
        return 1

    fork = H.fork_identity()

    # --- the cases
    shared = {'manifests': {}}
    case_results = []
    for fn in C.ALL_CASES:
        try:
            case_results.append(fn(shared))
        except Exception as exc:  # a broken case is a finding, not a pass
            case_results.append({
                'id': fn.__name__, 'requirement': fn.__name__,
                'description': 'case raised', 'expected': {},
                'observed': {'exception': str(exc)[:400]}, 'result': 'FAIL'})

    # --- a real release/patch manifest pair for the detectors
    release = H.run_in_temp(C.BASE, package_name=C.PKG)
    patch = H.run_in_temp(C.BODY_EDIT, package_name=C.PKG)
    manifests = {
        'release_namespace': release['namespace_identity'],
        'patch_namespace': patch['namespace_identity'],
        'release_entries': release['identity']['total'],
        'patch_entries': patch['identity']['total'],
        'namespace_equal_under_body_edit':
            release['namespace_identity'] == patch['namespace_identity'],
        'private_names_namespace': None,  # filled below
    }

    V.check_manifest(release, 'release', findings)
    V.check_manifest(patch, 'patch', findings)
    V.check_namespace_binding(release, patch, findings)
    private = H.run_in_temp(C.PRIVATE_COLLIDE, package_name=C.PKG)
    V.check_manifest(private, 'private_names', findings)

    if fork.get('dirty'):
        findings.append({
            'code': 'FORK_TREE_DIRTY', 'severity': 'blocking',
            'message': 'the fork worktree has uncommitted changes, so the '
                       'commit recorded here does not describe the compiler '
                       'that actually ran'})

    manifests['private_names_namespace'] = private['namespace_identity']
    arms = F.run(release, case_results, private_manifest=private)
    V.check_population(case_results, findings, arms)
    failed_arms = [a['id'] for a in arms if a['result'] != 'pass']
    if failed_arms:
        findings.append({
            'code': 'FALSIFICATION_ARM_FAILED', 'severity': 'blocking',
            'message': f'arms not demonstrated: {", ".join(failed_arms)}; an '
                       'not-yet-demonstrated detector is not known to work'})

    record = {
        'schema': 'maot.m1.evidence/1',
        'issue': 65,
        'generated_by': {
            'run_id': run_id,
            'repo_revision': git_head(repo),
            'gate_sha256': sha256_file(os.path.abspath(__file__)),
            'verdict_sha256': sha256_file(os.path.join(
                os.path.dirname(os.path.abspath(__file__)), 'verdict.py')),
        },
        'fork_identity': fork,
        'manifests': manifests,
        'cases': case_results,
        'findings': findings,
        'falsification': arms,
        'verdict': V.derive(case_results, findings, fork, manifests),
        'consumers': {},
    }

    problems = check_consumers(record)
    record['consumers'] = {
        'map': V.CONSUMERS,
        'unconsumed_or_undeclared': problems,
        'rule': 'every computed value names the decision that reads it, and '
                'every declared consumer refers to a value produced. Checked '
                'in both directions.',
    }
    for p in problems:
        findings.append({'code': 'VALUE_NOT_CONSUMED', 'severity': 'blocking',
                         'message': p})
    if problems:
        record['verdict'] = V.derive(case_results, findings, fork, manifests)

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, 'w', encoding='utf-8') as fh:
        json.dump(record, fh, indent=2)
        fh.write('\n')

    blocking = [f for f in findings if f['severity'] == 'blocking']
    v = record['verdict']
    print(f'fork commit        {fork["commit"]}')
    print(f'fork tree          {fork["tree"]}')
    print(f'cases              {len(case_results)} '
          f'({len(v["cases_failed"])} failed)')
    print(f'falsification arms {len(arms)} ({len(failed_arms)} failed)')
    print(f'release namespace  {manifests["release_namespace"]}')
    print(f'blocking findings  {len(blocking)}')
    print(f'VERDICT            stable_identity = {v["stable_identity"]}')
    for f in blocking[:12]:
        print(f'  {f["code"]}: {f["message"][:150]}')
    return 0 if not blocking else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
