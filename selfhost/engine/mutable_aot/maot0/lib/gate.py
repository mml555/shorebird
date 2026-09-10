#!/usr/bin/env python3
"""MAOT-0 (#63) -- the gate. Reads the matrix, refuses, and records why.

Writes one structured record. The aggregate in it is computed by
contract.derive_aggregate and by nothing else, so there is exactly one place
in this lane where a 100% claim can be produced.

`--accept-lock` advances matrix.lock.json. It refuses while any blocking
finding other than the lock's own stands, so the lock can never be used to
launder a promotion past a real defect.

usage: gate.py <maot0-dir> <repo-root> <out.json> [--accept-lock]
"""

import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import contract as C          # noqa: E402
import validate as V          # noqa: E402

LOCK_CODES = {'LOCK_MISSING', 'LOCK_ROW_STATE_DRIFT', 'LOCK_ROW_ADDED',
              'LOCK_ROW_REMOVED'}

# Which decision consumes each computed value. #62's closure discipline item
# 6: a correctly computed value that affects no decision is still a defect.
# The gate asserts this map and the record have exactly the same keys, in
# both directions -- an unconsumed value fails, and so does a consumer naming
# a value that is not produced.
CONSUMERS = {
    'aggregate':
        'the gate exit code, and every later issue\'s claim about universal '
        'support',
    'findings':
        'aggregate.blocking_findings, which refuses the 100% claim, and the '
        'gate exit code',
    'coverage':
        'the UNIVERSE_ENTRY_UNCOVERED findings, which are blocking; and the '
        'reviewer deciding whether a blanket is honest',
    'lock':
        'the LOCK_* findings, and --accept-lock\'s refusal to advance',
    'matrix_identity':
        'the completion report and any later claim that a result came from '
        'this exact row set',
    'universe_identity':
        'whether a coverage result may be quoted at all -- a universe from a '
        'different Dart tree is a different question',
    'row_states':
        'aggregate.rows_not_proven; and MAOT-T0, which must build a fixture '
        'for every row that is not yet PROVEN',
    'axis_states':
        'the per-axis obligations each later issue owns; MAOT-1..13 report '
        'against these four columns rather than a single row status',
    'scope':
        'which rows the aggregate quantifies over, and the machine-readable '
        'fixed-native-binary boundary later issues must not silently widen',
}


def sha256_file(path):
    return V.sha256_file(path)


def git_head(repo_root):
    try:
        out = subprocess.run(['git', '-C', repo_root, 'rev-parse', 'HEAD'],
                             capture_output=True, text=True, timeout=30)
        return out.stdout.strip() if out.returncode == 0 else None
    except Exception:
        return None


def build_record(maot_dir, repo_root):
    matrix_path = os.path.join(maot_dir, 'matrix.json')
    lock_path = os.path.join(maot_dir, 'matrix.lock.json')
    universe_dir = os.path.join(maot_dir, 'universe')

    with open(matrix_path, encoding='utf-8') as fh:
        matrix = json.load(fh)

    lock = None
    if os.path.isfile(lock_path):
        with open(lock_path, encoding='utf-8') as fh:
            lock = json.load(fh)

    universes, universe_findings = V.load_universes(universe_dir)
    report = V.validate(matrix, universes, repo_root, lock=lock)
    findings = universe_findings + report['findings']
    aggregate = C.derive_aggregate(matrix, findings)

    rows = matrix.get('rows', [])
    row_states = {r['id']: C.derive_row_state(r) for r in rows if r.get('id')}
    axis_states = {}
    for axis in C.AXES:
        counts = {}
        for r in rows:
            val = C.row_axis_values(r)[axis]
            counts[val] = counts.get(val, 0) + 1
        axis_states[axis] = {'meaning': C.AXIS_MEANING[axis],
                             'counts': dict(sorted(counts.items()))}

    universe_identity = {}
    for name in ('kernel_declarations.json', 'vm_runtime_state.json'):
        path = os.path.join(universe_dir, name)
        if os.path.isfile(path):
            with open(path, encoding='utf-8') as fh:
                doc = json.load(fh)
            universe_identity[name] = {
                'frozen_file_sha256': sha256_file(path),
                'dart_tree_head': doc['provenance'].get('dart_tree_head'),
                'source_digests': doc['provenance'].get('source_digests'),
                'extractor_sha256': doc['provenance'].get('extractor_sha256'),
                'total': doc.get('total'),
            }

    record = {
        'schema': 'maot0.gate/1',
        'issue': 63,
        'program': 'MUTABLE-AOT (#62)',
        'generated_by': {
            'gate_sha256': sha256_file(os.path.abspath(__file__)),
            'contract_sha256': sha256_file(
                os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             'contract.py')),
            'validate_sha256': sha256_file(
                os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             'validate.py')),
            'repo_head': git_head(repo_root),
        },
        'matrix_identity': {
            'matrix_sha256': sha256_file(matrix_path),
            'row_count': len(rows),
            'row_ids': sorted(row_states),
        },
        'universe_identity': universe_identity,
        'scope': {
            'in_scope_rows': [r['id'] for r in C.in_scope_rows(matrix)],
            'out_of_scope_rows': [
                {'id': r['id'], 'boundary_ref': r.get('boundary_ref')}
                for r in rows if not r.get('in_scope', True)],
            'boundaries': matrix.get('boundaries', []),
            'exclusion_classes': matrix.get('exclusion_classes', []),
        },
        'row_states': row_states,
        'axis_states': axis_states,
        'coverage': report['coverage'],
        'lock': report['lock'],
        'findings': findings,
        'aggregate': aggregate,
    }
    return matrix, lock, record


def check_consumers(record):
    """Every computed value must feed a decision, and vice versa."""
    meta = {'schema', 'issue', 'program', 'generated_by', 'consumers'}
    produced = set(record) - meta
    named = set(CONSUMERS)
    problems = []
    for key in sorted(produced - named):
        problems.append(
            f'{key!r} is computed but no decision is declared to consume it')
    for key in sorted(named - produced):
        problems.append(
            f'CONSUMERS names {key!r}, which the record does not produce')
    return problems


def main(argv):
    args = [a for a in argv[1:] if not a.startswith('--')]
    flags = {a for a in argv[1:] if a.startswith('--')}
    if len(args) != 3:
        print(__doc__)
        return 2
    maot_dir, repo_root, out_path = (os.path.abspath(args[0]),
                                     os.path.abspath(args[1]), args[2])

    matrix, lock, record = build_record(maot_dir, repo_root)

    consumer_problems = check_consumers(record)
    record['consumers'] = {
        'map': CONSUMERS,
        'unconsumed_or_undeclared': consumer_problems,
        'rule': ('Every computed value in this record must name the decision '
                 'that consumes it, and every named consumer must refer to a '
                 'value actually produced. Checked in both directions.'),
    }
    for problem in consumer_problems:
        record['findings'].append({
            'code': 'VALUE_NOT_CONSUMED', 'severity': 'blocking',
            'message': problem})
    if consumer_problems:
        record['aggregate'] = C.derive_aggregate(matrix, record['findings'])

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, 'w', encoding='utf-8') as fh:
        json.dump(record, fh, indent=2)
        fh.write('\n')

    blocking = [f for f in record['findings'] if f['severity'] == 'blocking']

    if '--accept-lock' in flags:
        non_lock = [f for f in blocking if f['code'] not in LOCK_CODES]
        if non_lock:
            print('REFUSING to advance the lock: '
                  f'{len(non_lock)} blocking finding(s) stand')
            for f in non_lock[:10]:
                print(f'  {f["code"]}: {f["message"]}')
            return 1
        new_lock = V.compute_lock(matrix['rows'])
        lock_path = os.path.join(maot_dir, 'matrix.lock.json')
        with open(lock_path, 'w', encoding='utf-8') as fh:
            json.dump(new_lock, fh, indent=2)
            fh.write('\n')
        print(f'lock advanced: {len(new_lock["rows"])} rows, '
              f'set_digest {new_lock["set_digest"][:16]}')
        return 0

    return 0 if not blocking else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
