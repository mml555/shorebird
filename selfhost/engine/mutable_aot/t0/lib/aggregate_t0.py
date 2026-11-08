#!/usr/bin/env python3
"""MAOT-T0 (#64) -- derive the harness verdict from the row results.

The aggregate is a function of the rows and nothing else. #64's acceptance:
"Aggregate verdict is mechanically derived from row results", and "the final
gate cannot claim 100% while any in-scope row is not PROVEN".

Counts are published for diagnosis. No comparison is made against them
anywhere in this file, which is what control A07 demonstrates.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import schema as S            # noqa: E402

# Fields a row record must carry before it is allowed to say anything. A
# record missing one of these is INCOMPLETE, never a pass -- an absent field
# must not read as a satisfied one.
REQUIRED_ROW_FIELDS = (
    'schema', 'row_id', 'gate_id', 'result', 'reasons', 'mechanism',
    'generated_at', 'generator',
)

# An executable fixture must additionally declare what it expects before and
# after. A placeholder has no expectations yet -- that is what makes it a
# placeholder -- but an EXECUTABLE row missing them could never distinguish a
# patched program from an unpatched one, so the strict set is narrowed to the
# rows it applies to rather than dropped for all of them.
REQUIRED_EXECUTABLE_ROW_FIELDS = ('expected_pre', 'expected_post')


def check_rows(matrix_rows, row_results):
    """Every in-scope row must have a complete, current result."""
    findings = []
    in_scope = {r['id'] for r in matrix_rows if r.get('in_scope', True)}
    by_id = {r.get('row_id'): r for r in row_results}

    for rid in sorted(in_scope):
        rec = by_id.get(rid)
        if rec is None:
            findings.append({
                'code': 'ROW_RESULT_ABSENT', 'severity': 'blocking',
                'message': f'{rid}: in-scope matrix row has no result in this '
                           'run; a row cannot be retired by not running it',
                'row': rid})
            continue
        required = list(REQUIRED_ROW_FIELDS)
        if rec.get('executable'):
            required += list(REQUIRED_EXECUTABLE_ROW_FIELDS)
        elif rec.get('executable') is None:
            findings.append({
                'code': 'ROW_RESULT_INCOMPLETE', 'severity': 'blocking',
                'message': f'{rid}: record does not say whether the fixture '
                           'is executable, so its completeness rule is '
                           'undecidable',
                'row': rid})
        for field in required:
            if rec.get(field) in (None, ''):
                findings.append({
                    'code': 'ROW_RESULT_INCOMPLETE', 'severity': 'blocking',
                    'message': f'{rid}: result is missing {field!r}',
                    'row': rid})
        if rec.get('result') not in S.RESULTS:
            findings.append({
                'code': 'ROW_RESULT_UNKNOWN', 'severity': 'blocking',
                'message': f'{rid}: unknown result {rec.get("result")!r}',
                'row': rid})
        for reason in rec.get('reasons') or []:
            if reason not in S.REASONS:
                findings.append({
                    'code': 'ROW_REASON_UNKNOWN', 'severity': 'blocking',
                    'message': f'{rid}: undeclared reason {reason!r}',
                    'row': rid})
        # A result produced by anything but the real backend may never be
        # counted, and saying so here means a future backend name cannot
        # quietly join the passing set.
        if rec.get('result') in S.RESULTS_COUNTING_AS_PROOF and \
                rec.get('mechanism') != 'none':
            findings.append({
                'code': 'PROOF_FROM_NON_REAL_BACKEND', 'severity': 'blocking',
                'message': f'{rid}: result {rec["result"]} came from backend '
                           f'{rec.get("mechanism")!r}, not the real mechanism',
                'row': rid})

    for rid in sorted(set(by_id) - in_scope):
        findings.append({
            'code': 'ROW_RESULT_ORPHAN', 'severity': 'blocking',
            'message': f'{rid}: a result with no in-scope matrix row',
            'row': rid})

    return findings


def derive(matrix_rows, row_results, findings):
    in_scope = [r['id'] for r in matrix_rows if r.get('in_scope', True)]
    by_id = {r.get('row_id'): r for r in row_results}

    proven, not_proven, infra = [], [], []
    counts = {}
    for rid in in_scope:
        rec = by_id.get(rid)
        result = (rec or {}).get('result')
        counts[result] = counts.get(result, 0) + 1
        if result in S.RESULTS_COUNTING_AS_PROOF and \
                (rec or {}).get('mechanism') == 'none':
            proven.append(rid)
        else:
            not_proven.append(rid)
        if result in S.RESULTS_INFRA:
            infra.append(rid)

    blocking = [f for f in findings if f.get('severity') == 'blocking']
    claim = 'PROVEN' if (in_scope and not not_proven and not blocking) \
        else 'NOT_PROVEN'

    return {
        'universal_dart_patchability': claim,
        'in_scope_rows': len(in_scope),
        'rows_proven': proven,
        'rows_not_proven': not_proven,
        'rows_infra_failed': infra,
        'result_counts': dict(sorted(
            (k or 'MISSING', v) for k, v in counts.items())),
        'blocking_findings': sorted({f['code'] for f in blocking}),
        'diagnostic_only': (
            'result_counts, and any percentage a reader computes from it, are '
            'DIAGNOSTIC. The verdict is a conjunction over every in-scope row '
            'and no threshold is compared anywhere in this module.'),
        'verdict_rule': (
            'universal_dart_patchability == PROVEN iff there is at least one '
            'in-scope row AND every in-scope row has a complete result whose '
            'value counts as proof AND was produced by the real mechanism '
            'backend AND no blocking finding was raised.'),
    }
