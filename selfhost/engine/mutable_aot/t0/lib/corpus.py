#!/usr/bin/env python3
"""MAOT-T0 (#64) -- the corpus, checked against #63's matrix in both directions.

The harness keeps NO list of what must work. It reads maot0/matrix.json and
requires a fixture directory per in-scope row; a fixture with no matrix row is
equally a failure, because that is how a second list starts.

usage: corpus.py <t0-dir> <matrix.json> [--scaffold]
"""

import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import schema as S            # noqa: E402


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b''):
            h.update(chunk)
    return h.hexdigest()


def load_matrix(matrix_path):
    with open(matrix_path, encoding='utf-8') as fh:
        return json.load(fh)


def corpus_dir(t0_dir):
    return os.path.join(t0_dir, 'corpus')


def fixture_path(t0_dir, row_id):
    return os.path.join(corpus_dir(t0_dir), row_id, 'fixture.json')


def load_fixture(t0_dir, row_id):
    path = fixture_path(t0_dir, row_id)
    if not os.path.isfile(path):
        return None
    with open(path, encoding='utf-8') as fh:
        return json.load(fh)


def scaffold(t0_dir, matrix):
    """Create a placeholder fixture for any in-scope row that has none.

    A placeholder is an explicit UNMODELED declaration with a written reason,
    never an absence. #64: unsupported rows "should fail or remain explicitly
    UNMODELED, never silently disappear."
    """
    created = []
    for row in matrix['rows']:
        if not row.get('in_scope', True):
            continue
        rid = row['id']
        path = fixture_path(t0_dir, rid)
        if os.path.isfile(path):
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        doc = {
            'schema': S.FIXTURE_SCHEMA,
            'row_id': rid,
            'gate_id': row['gate_id'],
            'title': row['title'],
            'executable': False,
            'placeholder_reason': (
                'Scaffolded from the matrix and not yet given executable '
                'release/patch sources. The row reports UNMODELED with reason '
                'FIXTURE_MISSING until it does; it never reports a pass.'),
            'dispatch_modes': [],
            'optimizer_modes': [],
            'heat_modes': [],
            'expected_pre': None,
            'expected_post': None,
            'old_state_required': False,
        }
        with open(path, 'w', encoding='utf-8') as fh:
            json.dump(doc, fh, indent=2)
            fh.write('\n')
        created.append(rid)
    return created


def check(t0_dir, matrix):
    """Both directions: no matrix row without a fixture, no orphan fixture."""
    findings = []
    in_scope = {r['id']: r for r in matrix['rows'] if r.get('in_scope', True)}

    present = set()
    row_dir = corpus_dir(t0_dir)
    if os.path.isdir(row_dir):
        present = {d for d in os.listdir(row_dir)
                   if os.path.isdir(os.path.join(row_dir, d))
                   and not d.startswith('_')}

    for rid in sorted(in_scope):
        if rid not in present:
            findings.append({
                'code': 'FIXTURE_ABSENT', 'severity': 'blocking',
                'message': f'{rid}: matrix row has no corpus directory',
                'row': rid})
            continue
        fx = load_fixture(t0_dir, rid)
        if fx is None:
            findings.append({
                'code': 'FIXTURE_ABSENT', 'severity': 'blocking',
                'message': f'{rid}: corpus directory has no fixture.json',
                'row': rid})
            continue
        if fx.get('schema') != S.FIXTURE_SCHEMA:
            findings.append({
                'code': 'FIXTURE_SCHEMA_INVALID', 'severity': 'blocking',
                'message': f'{rid}: fixture schema is '
                           f'{fx.get("schema")!r}, expected '
                           f'{S.FIXTURE_SCHEMA!r}', 'row': rid})
        if fx.get('gate_id') != in_scope[rid]['gate_id']:
            findings.append({
                'code': 'FIXTURE_GATE_MISMATCH', 'severity': 'blocking',
                'message': f'{rid}: fixture gate_id {fx.get("gate_id")!r} does '
                           f'not match the matrix gate_id '
                           f'{in_scope[rid]["gate_id"]!r}', 'row': rid})
        if fx.get('executable'):
            for name in ('release.dart', 'patch.dart'):
                p = os.path.join(row_dir, rid, name)
                if not os.path.isfile(p):
                    findings.append({
                        'code': 'FIXTURE_SOURCE_MISSING', 'severity': 'blocking',
                        'message': f'{rid}: declared executable but {name} is '
                                   'absent', 'row': rid})
            for field in ('expected_pre', 'expected_post', 'dispatch_modes',
                          'optimizer_modes', 'heat_modes'):
                if not fx.get(field):
                    findings.append({
                        'code': 'FIXTURE_SCHEMA_INVALID', 'severity': 'blocking',
                        'message': f'{rid}: executable fixture is missing '
                                   f'{field!r}', 'row': rid})
            for m in fx.get('dispatch_modes', []):
                if m not in S.DISPATCH_MODES:
                    findings.append({
                        'code': 'FIXTURE_MODE_UNKNOWN', 'severity': 'blocking',
                        'message': f'{rid}: unknown dispatch mode {m!r}',
                        'row': rid})
            for m in fx.get('optimizer_modes', []):
                if m not in S.OPTIMIZER_MODES:
                    findings.append({
                        'code': 'FIXTURE_MODE_UNKNOWN', 'severity': 'blocking',
                        'message': f'{rid}: unknown optimizer mode {m!r}',
                        'row': rid})
            for m in fx.get('heat_modes', []):
                if m not in S.HEAT_MODES:
                    findings.append({
                        'code': 'FIXTURE_MODE_UNKNOWN', 'severity': 'blocking',
                        'message': f'{rid}: unknown heat mode {m!r}',
                        'row': rid})
            # An executable fixture whose pre and post are the same string
            # can never distinguish a working patch from no patch at all.
            if fx.get('expected_pre') == fx.get('expected_post'):
                findings.append({
                    'code': 'FIXTURE_INDISTINGUISHABLE', 'severity': 'blocking',
                    'message': f'{rid}: expected_pre equals expected_post, so '
                               'the fixture cannot tell a patched program from '
                               'an unpatched one', 'row': rid})
        elif not fx.get('placeholder_reason'):
            findings.append({
                'code': 'FIXTURE_PLACEHOLDER_UNJUSTIFIED', 'severity': 'blocking',
                'message': f'{rid}: non-executable fixture with no written '
                           'placeholder_reason', 'row': rid})

    for rid in sorted(present - set(in_scope)):
        findings.append({
            'code': 'FIXTURE_ORPHAN', 'severity': 'blocking',
            'message': f'{rid}: corpus directory has no in-scope matrix row; '
                       'the harness must not keep a second list',
            'row': rid})

    executable = sorted(
        rid for rid in in_scope
        if (load_fixture(t0_dir, rid) or {}).get('executable'))
    return {
        'matrix_in_scope_rows': len(in_scope),
        'fixtures_present': len(present),
        'executable_fixtures': executable,
        'placeholder_fixtures': sorted(set(in_scope) - set(executable)),
        'findings': findings,
    }


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    t0_dir, matrix_path = os.path.abspath(argv[1]), os.path.abspath(argv[2])
    matrix = load_matrix(matrix_path)
    if '--scaffold' in argv:
        created = scaffold(t0_dir, matrix)
        print(f'scaffolded {len(created)} placeholder fixtures')
    rep = check(t0_dir, matrix)
    print(f'in-scope rows      {rep["matrix_in_scope_rows"]}')
    print(f'fixtures present   {rep["fixtures_present"]}')
    print(f'executable         {len(rep["executable_fixtures"])}')
    print(f'placeholders       {len(rep["placeholder_fixtures"])}')
    for f in rep['findings'][:20]:
        print(f'  {f["code"]}: {f["message"]}')
    return 0 if not rep['findings'] else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
