#!/usr/bin/env python3
"""Falsifications for the MAOT-5 cell map. Every check must be shown firing.

The first version of `partition_exact` could not fail: the buckets were built
by subtraction (`target = cells - control - prior`), so they were disjoint and
exhaustive by construction and the check reported True against every
injection. It is rebuilt from independent per-bucket predicates, and this
module is what proves the rebuild actually discriminates.

Arm C injects the exact error review found in the first cell map -- counting
`direct` as prior coverage inside #69's own rows -- so the map now refuses
the mistake it was corrected for.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cells_m5 as C  # noqa: E402

CORPUS = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), '..', '..', 't0', 'corpus'))


def _run():
    rows, checks = C.inventory(CORPUS)
    return C.summary(rows, checks), checks


def main():
    arms, live = [], None
    base, _ = _run()
    live = base

    def arm(aid, why, mutate, restore, expect):
        before = _run()[0]
        mutate()
        try:
            s, c = _run()
        finally:
            restore()
        after = _run()[0]
        fired = expect(s, c)
        arms.append({
            'id': aid, 'why': why, 'result': 'pass' if fired else 'FAIL',
            'observed': {k: s[k] for k in
                         ('partition_exact', 'surface_derivations_agree',
                          'target_by_69', 'deferred_other_issue')},
            'errors': c['partition_errors'][:2],
            'restored_clean': after == before,
        })

    def set_control(v):
        C.CONTROL_ONLY_OPTIMIZER_MODES = frozenset(v)

    sv_control = set(C.CONTROL_ONLY_OPTIMIZER_MODES)
    arm('A', 'a mode declared both product and control puts its cells in two '
             'buckets at once',
        lambda: set_control({'jit', 'aot'}),
        lambda: set_control(sv_control),
        lambda s, c: s['partition_exact'] is False)

    sv_product = frozenset(C.PRODUCT_OPTIMIZER_MODES)

    def set_product(v):
        C.PRODUCT_OPTIMIZER_MODES = frozenset(v)

    arm('B', 'a declared mode claimed by no bucket leaves real cells outside '
             'the partition',
        lambda: set_product(set()),
        lambda: set_product(sv_product),
        lambda s, c: s['partition_exact'] is False
        and any(e['problem'] == 'partition does not equal declared'
                for e in c['partition_errors']))

    sv_prior = set(C.ACCEPTED_PRIOR_CELLS)

    def set_prior(v):
        C.ACCEPTED_PRIOR_CELLS = set(v)

    arm('C', "THE ORIGINAL ERROR: counting `direct` as accepted prior "
             "coverage inside #69's own rows, which double-counts it as both "
             'target and prior',
        lambda: set_prior(sv_prior | {('EB-03', 'direct', 'aot', 'cold'),
                                      ('EB-03', 'direct', 'aot', 'hot')}),
        lambda: set_prior(sv_prior),
        lambda s, c: s['partition_exact'] is False
        and any(e['buckets'] == ['accepted_prior', 'target_by_69']
                for e in c['partition_errors'] if 'buckets' in e))

    sv_subj = dict(C.INSTANCE_MEMBER_SUBJECTS)

    def set_subj(v):
        C.INSTANCE_MEMBER_SUBJECTS.clear()
        C.INSTANCE_MEMBER_SUBJECTS.update(v)

    arm('D', "THE OTHER ORIGINAL ERROR: a row whose subject is not an "
             "instance member (EB-07, a factory) smuggled into the surface. "
             "The two derivations must stop agreeing.",
        lambda: set_subj({**sv_subj, 'EB-07': 'factory constructor body'}),
        lambda: set_subj(sv_subj),
        lambda s, c: s['surface_derivations_agree'] is False)

    arm('E', 'a fixture whose declared subject changes must fail the map '
             'rather than be silently reclassified',
        lambda: set_subj({**sv_subj, 'EB-03': 'something else entirely'}),
        lambda: set_subj(sv_subj),
        lambda s, c: c['rows_with_drifted_subject'] == ['EB-03'])

    failed = [a['id'] for a in arms if a['result'] != 'pass']
    dirty = [a['id'] for a in arms if not a['restored_clean']]
    rec = {'schema': 'maot.m5.falsification/1', 'issue': 69,
           'live_summary': live, 'arms': arms,
           'arms_failed': failed, 'arms_that_did_not_restore': dirty,
           'all_checks_shown_firing': failed == [] and dirty == []}
    out = (sys.argv[1] if len(sys.argv) > 1 else
           os.path.join(os.path.dirname(os.path.abspath(__file__)), '..',
                        'evidence', 'm5_cell_map_falsification.json'))
    with open(out, 'w') as fh:
        json.dump(rec, fh, indent=2, sort_keys=True)
    for a in arms:
        print(f"  {a['id']}  {a['result']:4}  {a['why'][:62]}")
    print(f"all checks shown firing: {rec['all_checks_shown_firing']}")
    return 0 if rec['all_checks_shown_firing'] else 1


if __name__ == '__main__':
    sys.exit(main())
