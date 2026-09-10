#!/usr/bin/env python3
"""MAOT-T0 (#64) -- the adversarial controls. All ten, plus the pair that
makes them mean something.

#64 lists ten false-positive paths the harness must catch. Catching them is
only interesting if the harness is otherwise capable of saying yes, so three
controls come first:

  P0  the mock double, told to behave correctly, really does produce
      per-mode post observations equal to expected_post. If the double were
      simply broken, every A control below would "pass" for the wrong reason.
  P1  the SHARED classifier, handed clean observations attributed to the real
      backend, returns PROVEN. The verdict is reachable.
  P2  the same clean observations attributed to the mock return MOCK_ONLY. A
      test double can never prove the product -- the most expensive false
      positive available, and it is closed by construction rather than by
      remembering not to do it.

Every A control drives the SAME `mechanism.classify` the real run uses. A
control that exercised a parallel code path would measure that path instead.

usage: adversarial.py <t0-dir> <matrix.json> <out.json>
"""

import copy
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aggregate_t0 as AGG    # noqa: E402
import mechanism as MECH      # noqa: E402
import runner as R            # noqa: E402
import schema as S            # noqa: E402

# One rich fixture drives the classifier controls: it is the only one carrying
# every dispatch form at once, so virtual/interface/super/tear-off staleness
# are all expressible against it.
CONTROL_ROW = 'EB-03'


def _synthetic_pre(fixture):
    """Clean pre observations for every declared mode combination."""
    obs = []
    for om in fixture['optimizer_modes']:
        for hm in fixture['heat_modes']:
            nonce = f'nonce-{om}-{hm}'
            for d in fixture['dispatch_modes']:
                obs.append({'phase': 'pre', 'dispatch': d,
                            'optimizer_mode': om, 'heat_mode': hm,
                            'value': fixture['expected_pre'], 'nonce': nonce})
    return obs


def run(t0_dir, matrix, row_results):
    fixture = json.load(
        open(os.path.join(t0_dir, 'corpus', CONTROL_ROW, 'fixture.json'),
             encoding='utf-8'))
    pre = _synthetic_pre(fixture)
    controls = []

    def record(cid, requirement, description, ok, observed, expected):
        controls.append({
            'id': cid, 'maps_to': requirement, 'description': description,
            'expected': expected, 'observed': observed,
            'result': 'pass' if ok else 'FAIL'})

    def classify_with(defect, mechanism_name='mock'):
        backend = MECH.backend(mechanism_name, defect) \
            if mechanism_name == 'mock' else MECH.backend(mechanism_name)
        install, post = backend.install(fixture, pre)
        return MECH.classify(fixture, pre, install, post, mechanism_name), post

    # ------------------------------------------------------------------ P0
    _, clean_post = classify_with(None)
    values = sorted({o['value'] for o in (clean_post or [])})
    record('P0', 'control validity',
           'the mock, told to behave, really does move every mode to '
           'expected_post -- otherwise every A control below passes for the '
           'wrong reason',
           values == [fixture['expected_post']],
           {'post_values': values}, [fixture['expected_post']])

    # ------------------------------------------------------------------ P1
    install = {'attempted': True, 'installed': True, 'reported_success': True,
               'reason': 'OK', 'identity_ok': True}
    good_post = [dict(o, phase='post', value=fixture['expected_post'])
                 for o in pre]
    verdict, reasons = MECH.classify(fixture, pre, install, good_post, 'none')
    record('P1', 'verdict reachability',
           'the shared classifier returns PROVEN for clean observations from '
           'the real backend -- so its refusals are informative rather than '
           'constant',
           verdict == 'PROVEN', {'verdict': verdict, 'reasons': reasons},
           {'verdict': 'PROVEN'})

    # ------------------------------------------------------------------ P2
    verdict, reasons = MECH.classify(fixture, pre, install, good_post, 'mock')
    record('P2', 'a double can never prove',
           'the SAME clean observations attributed to the mock backend yield '
           'MOCK_ONLY, which is absent from RESULTS_COUNTING_AS_PROOF',
           verdict == 'MOCK_ONLY' and
           verdict not in S.RESULTS_COUNTING_AS_PROOF,
           {'verdict': verdict, 'reasons': reasons},
           {'verdict': 'MOCK_ONLY'})

    # ------------------------------------------------------- #64 control 1
    (verdict, reasons), _ = classify_with('slot_unchanged')
    record('A01', '1. installer reports success but the slot is unchanged',
           'installation reports success while every mode still observes the '
           'old implementation',
           verdict == 'FAIL_OPEN' and 'SLOT_UNCHANGED' in reasons,
           {'verdict': verdict, 'reasons': reasons},
           {'verdict': 'FAIL_OPEN', 'reason': 'SLOT_UNCHANGED'})

    # ------------------------------------------------------- #64 control 2
    (verdict, reasons), _ = classify_with('virtual_stale')
    record('A02', '2. direct call changes but virtual dispatch stays old',
           'the defining bypass of #62 I2: one dispatch form follows the '
           'patch and another does not',
           verdict == 'WRONG_SEMANTICS' and 'DISPATCH_MODE_STALE' in reasons,
           {'verdict': verdict, 'reasons': reasons},
           {'verdict': 'WRONG_SEMANTICS', 'reason': 'DISPATCH_MODE_STALE'})

    (verdict, reasons), _ = classify_with('interface_stale')
    record('A02b', '2. interface dispatch stays old',
           'the same bypass through an interface-typed receiver',
           verdict == 'WRONG_SEMANTICS' and 'DISPATCH_MODE_STALE' in reasons,
           {'verdict': verdict, 'reasons': reasons},
           {'verdict': 'WRONG_SEMANTICS', 'reason': 'DISPATCH_MODE_STALE'})

    # ------------------------------------------------------- #64 control 3
    (verdict, reasons), _ = classify_with('tearoff_stale')
    record('A03', '3. only new tear-offs change; a pre-patch tear-off is old',
           'a tear-off captured before installation keeps reaching the old '
           'implementation while everything else moves',
           verdict == 'WRONG_SEMANTICS' and 'TEAROFF_STALE' in reasons,
           {'verdict': verdict, 'reasons': reasons},
           {'verdict': 'WRONG_SEMANTICS', 'reason': 'TEAROFF_STALE'})

    # ------------------------------------------------------- #64 control 4
    (verdict, reasons), _ = classify_with('hot_caller_stale')
    record('A04', '4. a hot/optimized caller remains old',
           'the cold path follows the patch and the hot, specialised one does '
           'not -- invisible to any cold-only harness',
           verdict == 'WRONG_SEMANTICS' and 'HOT_CALLER_STALE' in reasons,
           {'verdict': verdict, 'reasons': reasons},
           {'verdict': 'WRONG_SEMANTICS', 'reason': 'HOT_CALLER_STALE'})

    # ------------------------------------------------------- #64 control 5
    # Stale prior evidence surviving a failed current run. The row record
    # carries a generation stamp; a record from an earlier run must not be
    # accepted as this run's answer.
    stale_rows = copy.deepcopy(row_results)
    for rec in stale_rows:
        rec['generated_at'] = None      # this run did not produce it
    findings = AGG.check_rows(matrix['rows'], stale_rows)
    agg = AGG.derive(matrix['rows'], stale_rows, findings)
    record('A05', '5. stale prior evidence after a failed current run',
           'a row record that this run did not stamp is INCOMPLETE, not an '
           'answer carried over from last time',
           any(f['code'] == 'ROW_RESULT_INCOMPLETE' for f in findings) and
           agg['universal_dart_patchability'] == 'NOT_PROVEN',
           {'codes': sorted({f['code'] for f in findings}),
            'aggregate': agg['universal_dart_patchability']},
           {'code': 'ROW_RESULT_INCOMPLETE', 'aggregate': 'NOT_PROVEN'})

    # ------------------------------------------------------- #64 control 6
    dropped = [r for r in row_results if r.get('row_id') != CONTROL_ROW]
    findings = AGG.check_rows(matrix['rows'], dropped)
    agg = AGG.derive(matrix['rows'], dropped, findings)
    record('A06', '6. one matrix row deleted from the run',
           'not running a row is not a way to finish it',
           any(f['code'] == 'ROW_RESULT_ABSENT' for f in findings) and
           agg['universal_dart_patchability'] == 'NOT_PROVEN',
           {'codes': sorted({f['code'] for f in findings}),
            'aggregate': agg['universal_dart_patchability']},
           {'code': 'ROW_RESULT_ABSENT', 'aggregate': 'NOT_PROVEN'})

    # ------------------------------------------------------- #64 control 7
    all_proven = []
    for row in matrix['rows']:
        if not row.get('in_scope', True):
            continue
        # `executable` is required: check_rows refuses a record that does not
        # say which completeness rule applies to it. The first draft of this
        # control omitted it and the reachability half correctly failed --
        # which is the completeness check catching the control's own data.
        all_proven.append({
            'schema': S.ROW_SCHEMA, 'row_id': row['id'],
            'gate_id': row['gate_id'], 'result': 'PROVEN', 'reasons': ['OK'],
            'mechanism': 'none', 'executable': True,
            'expected_pre': '1', 'expected_post': '2',
            'generated_at': 'now', 'generator': 'A07'})
    one_short = copy.deepcopy(all_proven)
    one_short[-1]['result'] = 'UNMODELED'
    one_short[-1]['reasons'] = ['NO_MECHANISM']
    findings = AGG.check_rows(matrix['rows'], one_short)
    agg = AGG.derive(matrix['rows'], one_short, findings)
    pct = 100.0 * len(agg['rows_proven']) / max(agg['in_scope_rows'], 1)
    # And the paired reachability check: with the SAME shape and nothing
    # short, the aggregate does reach PROVEN.
    full_findings = AGG.check_rows(matrix['rows'], all_proven)
    full_agg = AGG.derive(matrix['rows'], all_proven, full_findings)
    record('A07', '7. a high percentage with one in-scope row unproven',
           f'{pct:.2f}% of rows proven is still NOT_PROVEN, while the same '
           'shape with nothing short does reach PROVEN -- so the refusal is '
           'the conjunction, not an inability to pass',
           agg['universal_dart_patchability'] == 'NOT_PROVEN' and
           full_agg['universal_dart_patchability'] == 'PROVEN',
           {'one_short': agg['universal_dart_patchability'],
            'percentage_diagnostic': round(pct, 2),
            'nothing_short': full_agg['universal_dart_patchability']},
           {'one_short': 'NOT_PROVEN', 'nothing_short': 'PROVEN'})

    # ------------------------------------------------------- #64 control 8
    (verdict, reasons), _ = classify_with('identity_swapped')
    record('A08', '8. release and patch identities swapped',
           'a patch not bound to the release it targets is refused even when '
           'every observed value looks right',
           verdict == 'WRONG_SEMANTICS' and 'IDENTITY_MISMATCH' in reasons,
           {'verdict': verdict, 'reasons': reasons},
           {'verdict': 'WRONG_SEMANTICS', 'reason': 'IDENTITY_MISMATCH'})

    # ------------------------------------------------------- #64 control 9
    (verdict, reasons), _ = classify_with('restart')
    record('A09', '9. a process restart would make the test appear to pass',
           'every observed value is exactly expected_post, and the run is '
           'still refused because the process identity changed',
           verdict == 'RESTART_DETECTED' and 'PROCESS_RESTARTED' in reasons,
           {'verdict': verdict, 'reasons': reasons},
           {'verdict': 'RESTART_DETECTED', 'reason': 'PROCESS_RESTARTED'})

    # A09b -- the same false positive in its other clothing: substituting the
    # standalone patch.dart run (a rebuilt program in a new process) for the
    # post observation.
    rebuilt_post = [dict(o, phase='post', value=fixture['expected_post'],
                         nonce='rebuilt-' + o['nonce']) for o in pre]
    verdict, reasons = MECH.classify(fixture, pre, install, rebuilt_post,
                                     'none')
    record('A09b', '9. the rebuilt-program baseline substituted for post',
           'patch_source_baseline is a NEW process; using it as the post '
           'observation is caught by the same nonce check',
           verdict == 'RESTART_DETECTED',
           {'verdict': verdict, 'reasons': reasons},
           {'verdict': 'RESTART_DETECTED'})

    # ------------------------------------------------------------- A11
    # COMPOSITION. A01-A04, A08 and A09 each change a ROW's classification.
    # That they thereby change the AGGREGATE is true by construction -- the
    # aggregate is a conjunction -- but "true by construction" is an argument,
    # not a demonstration. So compose them directly: take a matrix that does
    # reach PROVEN, replace exactly one row's result with what a defective
    # mock run actually produced, and show the verdict flips.
    for defect, label in (('slot_unchanged', 'A01'),
                          ('virtual_stale', 'A02'),
                          ('tearoff_stale', 'A03'),
                          ('hot_caller_stale', 'A04'),
                          ('identity_swapped', 'A08'),
                          ('restart', 'A09')):
        (verdict, reasons), _ = classify_with(defect)
        composed = copy.deepcopy(all_proven)
        target = next(r for r in composed if r['row_id'] == CONTROL_ROW)
        target['result'] = verdict
        target['reasons'] = reasons
        f = AGG.check_rows(matrix['rows'], composed)
        a = AGG.derive(matrix['rows'], composed, f)
        record(f'A11/{label}', 'composition: a row defect reaches the verdict',
               f'the {label} defect, injected as one row of an otherwise '
               'fully proven matrix, flips universal_dart_patchability',
               a['universal_dart_patchability'] == 'NOT_PROVEN',
               {'row_result': verdict,
                'aggregate': a['universal_dart_patchability']},
               {'aggregate': 'NOT_PROVEN'})

    # ------------------------------------------------------ #64 control 10
    # An analysis value computed but not consumed by the final verdict.
    produced = set(_aggregate_keys())
    consumed = set(CONSUMERS)
    unconsumed = sorted(produced - consumed)
    undeclared = sorted(consumed - produced)
    record('A10', '10. a value is computed but consumed by no decision',
           'every field the aggregate produces names the decision that reads '
           'it, checked in both directions',
           not unconsumed and not undeclared,
           {'unconsumed': unconsumed, 'declared_but_absent': undeclared},
           {'unconsumed': [], 'declared_but_absent': []})

    return controls


def _aggregate_keys():
    """The aggregate's own output keys, read from a real derivation."""
    agg = AGG.derive([{'id': 'X', 'in_scope': True, 'gate_id': 'g'}], [], [])
    return agg.keys()


CONSUMERS = {
    'universal_dart_patchability': 'the gate exit code and the T0 verdict line',
    'in_scope_rows': 'the denominator of the diagnostic counts, and the '
                     'emptiness guard in the verdict rule',
    'rows_proven': 'control A07\'s reachability half, and any later claim that '
                   'a specific row is closed',
    'rows_not_proven': 'the verdict conjunction, and MAOT-1..13\'s work queue',
    'rows_infra_failed': 'whether a NOT_PROVEN means "no mechanism" or "the '
                         'harness is broken" -- different next actions',
    'result_counts': 'diagnosis only; read by a human, never by the verdict',
    'blocking_findings': 'the verdict conjunction and the gate exit code',
    'diagnostic_only': 'the reader, who must not turn result_counts into a '
                       'threshold',
    'verdict_rule': 'the reader and the completion report; it states the '
                    'conjunction the code implements',
}


def main(argv):
    if len(argv) != 4:
        print(__doc__)
        return 2
    t0_dir, matrix_path, out_path = argv[1:4]
    with open(matrix_path, encoding='utf-8') as fh:
        matrix = json.load(fh)
    rows_dir = os.path.join(t0_dir, 'evidence', 'rows')
    row_results = []
    if os.path.isdir(rows_dir):
        for name in sorted(os.listdir(rows_dir)):
            if name.endswith('.json'):
                with open(os.path.join(rows_dir, name), encoding='utf-8') as fh:
                    row_results.append(json.load(fh))

    controls = run(t0_dir, matrix, row_results)
    failed = [c for c in controls if c['result'] != 'pass']
    doc = {
        'schema': 'maot.t0.adversarial/1',
        'controls_total': len(controls),
        'controls_passed': len(controls) - len(failed),
        'controls_failed': len(failed),
        'note': ('P0/P1/P2 are positive controls. Without them the A controls '
                 'would be satisfied by a harness that refuses everything, '
                 'which catches nothing because it decides nothing.'),
        'controls': controls,
    }
    with open(out_path, 'w', encoding='utf-8') as fh:
        json.dump(doc, fh, indent=2)
        fh.write('\n')

    for c in controls:
        mark = 'pass' if c['result'] == 'pass' else 'FAIL'
        print(f'  {mark}  {c["id"]:5s} {c["maps_to"]}')
        if c['result'] != 'pass':
            print(f'          expected {c["expected"]}, observed {c["observed"]}')
    print(f'\n  {len(controls) - len(failed)}/{len(controls)} '
          'adversarial controls pass')
    return 0 if not failed else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
