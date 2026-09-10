#!/usr/bin/env python3
"""MAOT-0 (#63) -- falsify every gate the matrix rests on.

A check that has only ever been seen to pass is not known to work, and a gate
that can only ever say NOT_PROVEN is not a gate -- it is a constant. So the
arms run in BOTH directions:

  P0  the real matrix, unmodified, with its real lock -> no blocking finding.
      Without this, every negative arm below is satisfied by a validator that
      simply always complains.

  P1  a synthetic matrix in which every in-scope row is genuinely PROVEN,
      with real evidence files, real digests and a matching lock
      -> aggregate PROVEN. This is the arm that proves the 100% claim is
      REACHABLE. Its absence would make "fail closed" unfalsifiable.

  N*  one defect introduced at a time, each expected to raise a named finding
      or flip the aggregate. Several are #63's own required arms.

usage: falsify_maot0.py <matrix.json> <universe-dir> <repo-root> <out.json>
"""

import copy
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import contract as C          # noqa: E402
import validate as V          # noqa: E402


def _codes(findings):
    return {f['code'] for f in findings}


def _all_proven(matrix, evidence_path, evidence_sha):
    """Every in-scope row genuinely PROVEN, with evidence that really exists."""
    m = copy.deepcopy(matrix)
    for row in m['rows']:
        if not row.get('in_scope', True):
            continue
        row['axes'] = {a: 'PROVEN' for a in C.AXES}
        row['axis_notes'] = {}
        row['evidence'] = {'path': evidence_path, 'sha256': evidence_sha}
    return m


def run(matrix, universes, repo_root, real_lock):
    arms = []

    def arm(aid, desc, matrix_in, lock_in, expect_codes=(),
            expect_absent_codes=(), expect_aggregate=None,
            expect_no_blocking=False):
        rep = V.validate(matrix_in, universes, repo_root, lock=lock_in)
        agg = C.derive_aggregate(matrix_in, rep['findings'])
        got = _codes(rep['findings'])
        blocking = sorted({f['code'] for f in rep['findings']
                           if f['severity'] == 'blocking'})
        problems = []
        for code in expect_codes:
            if code not in got:
                problems.append(f'expected finding {code}, not raised')
        for code in expect_absent_codes:
            if code in got:
                problems.append(f'finding {code} was raised and should not be')
        if expect_no_blocking and blocking:
            problems.append(f'blocking findings raised: {blocking}')
        if expect_aggregate and \
                agg['universal_dart_patchability'] != expect_aggregate:
            problems.append(
                f'expected aggregate {expect_aggregate}, got '
                f'{agg["universal_dart_patchability"]}')
        arms.append({
            'id': aid,
            'description': desc,
            'expected_codes': sorted(expect_codes),
            'expected_absent_codes': sorted(expect_absent_codes),
            'expected_no_blocking': expect_no_blocking,
            'expected_aggregate': expect_aggregate,
            'observed_codes': sorted(got),
            'observed_blocking_codes': blocking,
            'observed_aggregate': agg['universal_dart_patchability'],
            'result': 'pass' if not problems else 'FAIL',
            'problems': problems,
        })

    # ---------------------------------------------------------------- P0
    arm('P0',
        'the real matrix with its real lock raises NO blocking finding -- '
        'without this control every negative arm below would also be '
        'satisfied by a validator that always complains',
        matrix, real_lock,
        expect_no_blocking=True,
        expect_aggregate='NOT_PROVEN')

    # ---------------------------------------------------------------- P1
    with tempfile.TemporaryDirectory() as td:
        rel = os.path.relpath(os.path.join(td, 'evidence.json'), repo_root)
        abs_path = os.path.join(repo_root, rel)
        with open(abs_path, 'w', encoding='utf-8') as fh:
            json.dump({'synthetic': 'P1 reachability control'}, fh)
        sha = V.sha256_file(abs_path)

        proven = _all_proven(matrix, rel, sha)
        proven_lock = V.compute_lock(proven['rows'])
        arm('P1',
            'a matrix whose every in-scope row is PROVEN with real evidence '
            'and a matching lock reaches aggregate PROVEN -- the gate is '
            'capable of green, so its red is informative',
            proven, proven_lock,
            expect_absent_codes=['PROVEN_ROW_WITHOUT_EVIDENCE',
                                 'EVIDENCE_FILE_MISSING',
                                 'EVIDENCE_DIGEST_MISMATCH',
                                 'LOCK_ROW_STATE_DRIFT',
                                 'UNIVERSE_ENTRY_UNCOVERED'],
            expect_aggregate='PROVEN')

        # ------------------------------------------------------------ N01
        # #63: "the final aggregate claims 100% while any in-scope row is not
        # PROVEN". One row demoted out of an otherwise perfect matrix.
        m = copy.deepcopy(proven)
        m['rows'][0]['axes']['dispatch_correctness'] = 'IMPLEMENTED'
        arm('N01',
            'one in-scope row demoted to IMPLEMENTED in an otherwise fully '
            'proven matrix flips the aggregate; no threshold rescues it',
            m, V.compute_lock(m['rows']),
            expect_aggregate='NOT_PROVEN')

        # ------------------------------------------------------------ N02
        # The same defect stated as a percentage: N-1 of N proven.
        m = copy.deepcopy(proven)
        m['rows'][-1]['axes']['live_state_compatibility'] = 'DESIGNED'
        rep = V.validate(m, universes, repo_root, lock=V.compute_lock(m['rows']))
        agg = C.derive_aggregate(m, rep['findings'])
        pct = 100.0 * (agg['in_scope_rows'] - len(agg['rows_not_proven'])) \
            / max(agg['in_scope_rows'], 1)
        arms.append({
            'id': 'N02',
            'description': (
                f'{pct:.2f}% of in-scope rows proven is still NOT_PROVEN -- '
                'the aggregate is a conjunction, not a threshold'),
            'expected_aggregate': 'NOT_PROVEN',
            'observed_aggregate': agg['universal_dart_patchability'],
            'observed_percentage_diagnostic': round(pct, 2),
            'result': ('pass' if agg['universal_dart_patchability'] ==
                       'NOT_PROVEN' else 'FAIL'),
            'problems': ([] if agg['universal_dart_patchability'] ==
                         'NOT_PROVEN' else ['a high percentage passed']),
        })

        # ------------------------------------------------------------ N03
        # #63: "a required matrix row is missing". Deleting a row must not be
        # a way to reach 100% -- the constructs it covered become uncovered.
        m = copy.deepcopy(proven)
        m['rows'] = [r for r in m['rows'] if r['id'] != 'EB-16']
        arm('N03',
            'deleting a row from a fully proven matrix raises uncovered '
            'universe entries and refuses the aggregate',
            m, V.compute_lock(m['rows']),
            expect_codes=['UNIVERSE_ENTRY_UNCOVERED'],
            expect_aggregate='NOT_PROVEN')

        # ------------------------------------------------------------ N04
        # #63: "a PROVEN row lacks evidence".
        m = copy.deepcopy(proven)
        m['rows'][3]['evidence'] = None
        arm('N04', 'a PROVEN row with no evidence reference is refused',
            m, V.compute_lock(m['rows']),
            expect_codes=['PROVEN_ROW_WITHOUT_EVIDENCE'],
            expect_aggregate='NOT_PROVEN')

        # ------------------------------------------------------------ N05
        m = copy.deepcopy(proven)
        m['rows'][4]['evidence'] = {'path': 'selfhost/engine/mutable_aot/'
                                            'maot0/evidence/absent.json',
                                    'sha256': '0' * 64}
        arm('N05', 'a PROVEN row whose evidence file does not exist is refused',
            m, V.compute_lock(m['rows']),
            expect_codes=['EVIDENCE_FILE_MISSING'],
            expect_aggregate='NOT_PROVEN')

        # ------------------------------------------------------------ N06
        m = copy.deepcopy(proven)
        m['rows'][5]['evidence'] = {'path': rel, 'sha256': 'f' * 64}
        arm('N06',
            'a PROVEN row whose evidence exists but does not match its '
            'recorded digest is refused -- a stamp is not the bytes',
            m, V.compute_lock(m['rows']),
            expect_codes=['EVIDENCE_DIGEST_MISMATCH'],
            expect_aggregate='NOT_PROVEN')

        # ------------------------------------------------------------ N07
        # #63: "an IMPLEMENTED/PROVEN row has no executable gate ID".
        m = copy.deepcopy(matrix)
        m['rows'][6]['axes'] = {a: 'IMPLEMENTED' for a in C.AXES}
        m['rows'][6]['axis_notes'] = {}
        m['rows'][6]['gate_id'] = ''
        arm('N07', 'an IMPLEMENTED row with no gate id is refused',
            m, V.compute_lock(m['rows']),
            expect_codes=['IMPLEMENTED_ROW_WITHOUT_GATE'],
            expect_aggregate='NOT_PROVEN')

        # ------------------------------------------------------------ N08
        # #63: "a row silently moves from unsupported/unmodeled to supported
        # without evidence" -- layer one, the lock catches the move.
        m = copy.deepcopy(matrix)
        m['rows'][7]['axes'] = {a: 'PROVEN' for a in C.AXES}
        m['rows'][7]['axis_notes'] = {}
        arm('N08',
            'promoting a row without advancing the lock is caught as drift',
            m, real_lock,
            expect_codes=['LOCK_ROW_STATE_DRIFT'],
            expect_aggregate='NOT_PROVEN')

        # ------------------------------------------------------------ N09
        # ...and layer two: regenerating the lock to match the promotion does
        # NOT launder it, because the evidence is still absent. A single-layer
        # defence would fall to exactly this.
        m = copy.deepcopy(matrix)
        m['rows'][7]['axes'] = {a: 'PROVEN' for a in C.AXES}
        m['rows'][7]['axis_notes'] = {}
        arm('N09',
            'promoting a row AND regenerating the lock to match still fails, '
            'because the promotion has no evidence behind it',
            m, V.compute_lock(m['rows']),
            expect_codes=['PROVEN_ROW_WITHOUT_EVIDENCE'],
            expect_absent_codes=['LOCK_ROW_STATE_DRIFT'],
            expect_aggregate='NOT_PROVEN')

        # ------------------------------------------------------------ N10
        m = copy.deepcopy(matrix)
        m['rows'] = [r for r in m['rows'] if r['id'] != 'RS-05']
        arm('N10',
            'a locked row deleted from the matrix is caught; a required row '
            'cannot be retired by deletion',
            m, real_lock,
            expect_codes=['LOCK_ROW_REMOVED'],
            expect_aggregate='NOT_PROVEN')

        # ------------------------------------------------------------ N11
        m = copy.deepcopy(matrix)
        m['rows'][8]['covers'] = list(m['rows'][8].get('covers', [])) + \
            ['K:members:NoSuchNodeClass']
        arm('N11',
            'a row covering a construct no frozen universe contains is '
            'refused, so coverage cannot be faked by inventing ids',
            m, real_lock,
            expect_codes=['COVERS_UNKNOWN_UNIVERSE_ID'])

        # ------------------------------------------------------------ N12
        m = copy.deepcopy(matrix)
        m['universe_exclusions'] = list(m['universe_exclusions']) + [
            {'universe_id': 'V:object.h:Closure', 'class': 'X-INVENTED',
             'note': 'excluded on no declared grounds'}]
        arm('N12',
            'an exclusion using an undeclared class is refused, so a hard '
            'construct cannot be excluded by inventing a reason',
            m, real_lock,
            expect_codes=['EXCLUSION_CLASS_UNKNOWN'])

        # ------------------------------------------------------------ N13
        m = copy.deepcopy(matrix)
        m['rows'][9]['axes']['live_state_compatibility'] = 'NOT_APPLICABLE'
        m['rows'][9]['axis_notes'] = {}
        arm('N13',
            'declaring an axis NOT_APPLICABLE with no justification is '
            'refused -- the cheapest way to make a hard row look finished',
            m, V.compute_lock(m['rows']),
            expect_codes=['AXIS_NOT_APPLICABLE_UNJUSTIFIED'])

        # ------------------------------------------------------------ N14
        m = copy.deepcopy(matrix)
        del m['rows'][10]['axes']['dispatch_correctness']
        arm('N14',
            'an axis omitted entirely is refused; an absent axis must never '
            'read as a satisfied one',
            m, V.compute_lock(m['rows']),
            expect_codes=['AXIS_MISSING'])

        # ------------------------------------------------------------ N15
        m = copy.deepcopy(matrix)
        m['rows'][11]['in_scope'] = False
        m['rows'][11].pop('boundary_ref', None)
        arm('N15',
            'a row moved out of scope with no boundary reference is refused, '
            'so scope cannot be shrunk silently',
            m, V.compute_lock(m['rows']),
            expect_codes=['OUT_OF_SCOPE_ROW_WITHOUT_BOUNDARY'])

        # ------------------------------------------------------------ N16
        m = copy.deepcopy(matrix)
        m['rows'][12]['boundary_ref'] = 'NB-99'
        m['rows'][12]['in_scope'] = False
        arm('N16', 'a row citing an undeclared boundary is refused',
            m, V.compute_lock(m['rows']),
            expect_codes=['BOUNDARY_REF_UNKNOWN'])

        # ------------------------------------------------------------ N17
        m = copy.deepcopy(matrix)
        for row in m['rows']:
            if row['id'] == 'BL-01':
                row['covers_tiers'] = ['declaration']
        arm('N17',
            'claiming blanket coverage of a per-row tier is refused, so the '
            'declaration space cannot be waved through in one line',
            m, V.compute_lock(m['rows']),
            expect_codes=['TIER_BLANKET_NOT_PERMITTED',
                          'TIER_BLANKET_UNDECLARED'])

        # ------------------------------------------------------------ N18
        m = copy.deepcopy(matrix)
        m['rows'][13]['gate_id'] = m['rows'][14]['gate_id']
        arm('N18',
            'two rows sharing one gate id is refused; one of them would '
            'never be independently proven',
            m, V.compute_lock(m['rows']),
            expect_codes=['GATE_ID_DUPLICATE'])

        # ------------------------------------------------------------ N19
        # All four axes waved away must derive UNMODELED, never PROVEN.
        m = copy.deepcopy(proven)
        m['rows'][15]['axes'] = {a: 'NOT_APPLICABLE' for a in C.AXES}
        m['rows'][15]['axis_notes'] = {a: 'waved away' for a in C.AXES}
        derived = C.derive_row_state(m['rows'][15])
        arms.append({
            'id': 'N19',
            'description': (
                'a row with every axis NOT_APPLICABLE derives UNMODELED, not '
                'PROVEN -- four justifications are not a proof'),
            'expected_row_state': 'UNMODELED',
            'observed_row_state': derived,
            'expected_aggregate': 'NOT_PROVEN',
            'observed_aggregate': C.derive_aggregate(
                m, V.validate(m, universes, repo_root,
                              lock=V.compute_lock(m['rows']))['findings']
            )['universal_dart_patchability'],
            'result': 'pass' if derived == 'UNMODELED' else 'FAIL',
            'problems': ([] if derived == 'UNMODELED'
                         else [f'derived {derived}']),
        })

        # ------------------------------------------------------------ N20
        # A universe frozen from a dirty tree is not a nameable revision.
        arms.append(_universe_provenance_arm(repo_root))

    return arms


def _universe_provenance_arm(repo_root):
    """Freeze provenance must refuse a dirty or short-SHA extraction."""
    with tempfile.TemporaryDirectory() as td:
        doc = {
            'schema': 'maot0.universe/1',
            'universe': 'kernel',
            'provenance': {
                'dart_tree_head': 'abc123',
                'dart_tree_head_is_full_sha': False,
                'extracted_paths_dirty': True,
                'extracted_paths_dirty_detail': ' M pkg/kernel/lib/ast.dart',
            },
            'duplicate_ids': [],
            'total': 0,
            'entries': [],
        }
        for name in ('kernel_declarations.json', 'vm_runtime_state.json'):
            with open(os.path.join(td, name), 'w', encoding='utf-8') as fh:
                json.dump(doc, fh)
        _, findings = V.load_universes(td)
        got = _codes(findings)
        ok = 'UNIVERSE_PROVENANCE_INVALID' in got
        return {
            'id': 'N20',
            'description': (
                'a universe frozen from a dirty tree, or recording anything '
                'short of a full 40-hex SHA, is refused -- a branch or a '
                'dirty checkout is not provenance'),
            'expected_codes': ['UNIVERSE_PROVENANCE_INVALID'],
            'observed_codes': sorted(got),
            'result': 'pass' if ok else 'FAIL',
            'problems': [] if ok else ['provenance defect not raised'],
        }


def main(argv):
    if len(argv) != 5:
        print(__doc__)
        return 2
    matrix_path, universe_dir, repo_root, out_path = argv[1:5]
    with open(matrix_path, encoding='utf-8') as fh:
        matrix = json.load(fh)
    universes, _ = V.load_universes(universe_dir)

    lock_path = os.path.join(os.path.dirname(os.path.abspath(matrix_path)),
                             'matrix.lock.json')
    real_lock = None
    if os.path.isfile(lock_path):
        with open(lock_path, encoding='utf-8') as fh:
            real_lock = json.load(fh)

    arms = run(matrix, universes, repo_root, real_lock)
    failed = [a for a in arms if a['result'] != 'pass']
    doc = {
        'schema': 'maot0.falsification/1',
        'arms_total': len(arms),
        'arms_passed': len(arms) - len(failed),
        'arms_failed': len(failed),
        'directions': (
            'Both. P0 and P1 are positive controls -- P0 proves the validator '
            'is quiet on a correct matrix, P1 proves the aggregate can reach '
            'PROVEN. Without them the N arms would be satisfied by a gate '
            'that always refuses, which measures nothing.'),
        'arms': arms,
    }
    with open(out_path, 'w', encoding='utf-8') as fh:
        json.dump(doc, fh, indent=2)
        fh.write('\n')

    for a in arms:
        mark = 'pass' if a['result'] == 'pass' else 'FAIL'
        print(f'  {mark}  {a["id"]}  {a["description"]}')
        for p in a.get('problems', []):
            print(f'          -> {p}')
    print(f'\n  {len(arms) - len(failed)}/{len(arms)} falsification arms pass')
    return 0 if not failed else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
