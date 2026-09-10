#!/usr/bin/env python3
"""MAOT-T0 (#64) -- run the corpus and record what happened.

Evidence is REGENERATED, never merged. `evidence/rows/` is cleared before the
run, and every record is stamped with this run's id; the aggregate refuses any
record carrying a different stamp. That is what makes "stale evidence must
never survive a failed current run as apparent success" a mechanism rather
than a habit -- a record from last time cannot be mistaken for this time's
answer even if the file is still on disk.

usage: gate_t0.py <t0-dir> <matrix.json> <out.json>
"""

import datetime
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aggregate_t0 as AGG    # noqa: E402
import corpus as CORPUS       # noqa: E402
import runner as R            # noqa: E402
import schema as S            # noqa: E402


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b''):
            h.update(chunk)
    return h.hexdigest()


def git_head(repo_root):
    try:
        out = subprocess.run(['git', '-C', repo_root, 'rev-parse', 'HEAD'],
                             capture_output=True, text=True, timeout=30)
        return out.stdout.strip() if out.returncode == 0 else None
    except Exception:
        return None


def main(argv):
    if len(argv) != 4:
        print(__doc__)
        return 2
    t0_dir = os.path.abspath(argv[1])
    matrix_path = os.path.abspath(argv[2])
    out_path = argv[3]
    repo_root = os.path.abspath(os.path.join(t0_dir, '..', '..', '..', '..'))

    run_id = datetime.datetime.now(datetime.timezone.utc).strftime(
        '%Y-%m-%dT%H:%M:%SZ')

    with open(matrix_path, encoding='utf-8') as fh:
        matrix = json.load(fh)

    findings = []
    corpus_report = CORPUS.check(t0_dir, matrix)
    findings.extend(corpus_report['findings'])

    # Regenerate, never merge. A surviving record from an earlier run is the
    # false positive this clearing removes.
    rows_dir = os.path.join(t0_dir, 'evidence', 'rows')
    if os.path.isdir(rows_dir):
        shutil.rmtree(rows_dir)
    os.makedirs(rows_dir, exist_ok=True)

    tool = R.find_toolchain()
    if tool is None:
        findings.append({
            'code': 'TOOLCHAIN_ABSENT', 'severity': 'blocking',
            'message': 'no Dart SDK with both dart and dartaotruntime was '
                       'found; the executable fixtures cannot run'})

    row_results = []
    workdir = tempfile.mkdtemp(prefix='t0_gate_')
    try:
        for row in matrix['rows']:
            if not row.get('in_scope', True):
                continue
            rid = row['id']
            fixture = CORPUS.load_fixture(t0_dir, rid)
            if fixture is None:
                continue
            rec = R.run_fixture(t0_dir, rid, fixture, tool, 'none', None,
                                workdir)
            rec['generated_at'] = run_id
            rec['run_id'] = run_id
            row_results.append(rec)
            with open(os.path.join(rows_dir, f'{rid}.json'), 'w',
                      encoding='utf-8') as fh:
                json.dump(rec, fh, indent=2)
                fh.write('\n')
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    # Every record must belong to THIS run.
    for rec in row_results:
        if rec.get('run_id') != run_id:
            findings.append({
                'code': 'STALE_ROW_RECORD', 'severity': 'blocking',
                'message': f'{rec.get("row_id")}: record is stamped '
                           f'{rec.get("run_id")!r}, not this run',
                'row': rec.get('row_id')})

    findings.extend(AGG.check_rows(matrix['rows'], row_results))
    aggregate = AGG.derive(matrix['rows'], row_results, findings)

    executable = corpus_report['executable_fixtures']
    record = {
        'schema': S.EVIDENCE_SCHEMA,
        'issue': 64,
        'program': 'MUTABLE-AOT (#62)',
        'run_id': run_id,
        'generated_by': {
            'gate_sha256': sha256_file(os.path.abspath(__file__)),
            'runner_sha256': sha256_file(
                os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             'runner.py')),
            'mechanism_sha256': sha256_file(
                os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             'mechanism.py')),
            'repo_revision': git_head(repo_root),
        },
        'matrix_identity': {
            'matrix_sha256': sha256_file(matrix_path),
            'in_scope_rows': corpus_report['matrix_in_scope_rows'],
            'source': 'maot0/matrix.json -- the harness keeps no second list',
        },
        'toolchain': ({k: v for k, v in tool.items()
                       if k in ('sdk_revision', 'version_string',
                                'identity_note')} if tool else None),
        'corpus': {
            'fixtures_present': corpus_report['fixtures_present'],
            'executable_fixtures': executable,
            'placeholder_fixtures': corpus_report['placeholder_fixtures'],
            'modes': {
                'dispatch': list(S.DISPATCH_MODES),
                'optimizer': list(S.OPTIMIZER_MODES),
                'heat': list(S.HEAT_MODES),
                'heat_iterations': S.HEAT_ITERATIONS,
            },
        },
        'mechanism_backend': {
            'name': 'none',
            'why': ('The Mutable-AOT declaration/implementation mechanism '
                    'does not exist yet -- #65 through #70 build it. Until '
                    'then every row reports UNMODELED and no row can be '
                    'PROVEN. The mock backend exists only for the adversarial '
                    'controls and its results can never count as proof.'),
        },
        'row_results': [
            {'row_id': r['row_id'], 'result': r['result'],
             'reasons': r['reasons'],
             'executable': r['row_id'] in executable,
             'pre_observations': len(r.get('pre_observation') or []),
             'process_restarted': r.get('process_restarted')}
            for r in row_results],
        'findings': findings,
        'aggregate': aggregate,
    }

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, 'w', encoding='utf-8') as fh:
        json.dump(record, fh, indent=2)
        fh.write('\n')

    blocking = [f for f in findings if f.get('severity') == 'blocking']
    print(f'run_id             {run_id}')
    print(f'in-scope rows      {aggregate["in_scope_rows"]}')
    print(f'executable         {len(executable)}')
    print(f'placeholders       {len(corpus_report["placeholder_fixtures"])}')
    print(f'result counts      {aggregate["result_counts"]}')
    print(f'blocking findings  {len(blocking)}')
    print(f'VERDICT            universal_dart_patchability = '
          f'{aggregate["universal_dart_patchability"]}')
    for f in blocking[:15]:
        print(f'  {f["code"]}: {f["message"]}')
    return 0 if not blocking else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
