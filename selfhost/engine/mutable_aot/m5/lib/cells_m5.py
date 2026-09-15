#!/usr/bin/env python3
"""MAOT-5 (#69) -- the exact #64 cells this issue may claim.

Derived from the AUTHORITATIVE T0 fixtures (`t0/corpus/<row>/fixture.json`),
never transcribed and never inferred from what a row happened to observe.

Two errors in the first version of this module, both found in review:

1. It treated `direct` as prior #67/#68 coverage for EVERY selected row.
   Accepted #68 linkage covers only EB-01 and EB-02. Within #69's own rows
   the accepted-prior count is ZERO, and #69 owns the direct AOT cells of an
   instance-member subject itself -- they are the control half of
   direct-vs-virtual divergence and of optimizer-devirtualized calls.

2. Worse: it discovered rows from DISPATCH VOCABULARY. Any row using
   `dynamic` or a tear-off was pulled in regardless of what its subject was,
   so a factory (EB-07), async and generator bodies (EB-11/12/13), a closure
   (EB-14) and a top-level generic function (EB-15, subject `pick<T>()`) were
   all counted as #69 surface. That is the self-derived trap: the selector
   was computed from the thing being measured instead of from an independent
   fact about it.

The subject is what decides membership, and it is recoverable two ways that
must AGREE:

  * the fixture's own `subject_note`, pinned per row below, so a fixture
    whose subject changes fails the map instead of being silently
    reclassified;
  * whether the fixture declares `virtual`, which only an instance member
    can be dispatched by.

Neither is trusted alone. They are computed separately and required to
produce the same set.
"""
import glob
import json
import os

# The instance-member surface, pinned with the subject each row declares.
# Pinned EXACTLY rather than by membership test: a guard set can be narrowed
# silently, and this one decides what #69 is allowed to claim.
INSTANCE_MEMBER_SUBJECTS = {
    'EB-03': 'instance method body',
    'EB-04': 'getter body',
    'EB-05': 'setter body',
    'EB-06': 'operator body',
    'EB-19': 'callable class `call` body',
}

# `dynamic` is a DISTINCT dispatch mode, not an alias for `interface`.
# #69 owns every dispatch mode an instance-member fixture declares,
# `direct` included.
OWNED_DISPATCH = frozenset({
    'direct', 'virtual', 'interface', 'super', 'dynamic',
    'tearoff_pre', 'tearoff_post',
})

# `jit` is #64's harness/control axis, not product support, and no JIT
# Mutable-AOT mechanism is to be built. These cells are therefore
# CONTROL-ONLY: permanently outside product scope rather than pending.
# A raw #64 row can stay UNMODELED forever even with every AOT cell proven;
# #70 defines aggregate closure from demonstrated AOT cells, not from
# whole-row PROVEN.
CONTROL_ONLY_OPTIMIZER_MODES = frozenset({'jit'})

# Declared SEPARATELY from the control set, not as its complement. The
# partition check below is only able to fail because these two are
# independent: if a mode were ever put in both, its cells would land in two
# buckets and the check would say so. Defining one as `not the other` is what
# made the first version of this check vacuous -- buckets built by
# subtraction cannot overlap, so `partition_exact` was True no matter what
# was injected.
PRODUCT_OPTIMIZER_MODES = frozenset({'aot'})

# Accepted #67/#68 coverage. GLOBAL historical reference only -- both rows
# are outside #69's surface, so they contribute 0 prior cells to it.
ACCEPTED_PRIOR_CELLS = {
    ('EB-01', 'direct', 'aot', 'cold'), ('EB-01', 'direct', 'aot', 'hot'),
    ('EB-02', 'direct', 'aot', 'cold'), ('EB-02', 'direct', 'aot', 'hot'),
}

TARGET_ARCH = 'arm64'


def fixture_cells(path):
    """The authoritative declared cells: the fixture's own cross product."""
    d = json.load(open(path))
    cells = {(dm, om, hm)
             for dm in d['dispatch_modes']
             for om in d['optimizer_modes']
             for hm in d['heat_modes']}
    return d, cells


def derive_surface(corpus_dir):
    """The instance-member surface, derived twice and required to agree."""
    by_note, by_virtual, subjects = set(), set(), {}
    for path in sorted(glob.glob(os.path.join(corpus_dir, '*', 'fixture.json'))):
        d = json.load(open(path))
        rid = d['row_id']
        subjects[rid] = d.get('subject_note') or d.get('title')
        if rid in INSTANCE_MEMBER_SUBJECTS:
            by_note.add(rid)
        if 'virtual' in d['dispatch_modes']:
            by_virtual.add(rid)
    return by_note, by_virtual, subjects


def inventory(corpus_dir):
    by_note, by_virtual, subjects = derive_surface(corpus_dir)
    agree = (by_note == by_virtual)
    drifted = sorted(r for r, want in INSTANCE_MEMBER_SUBJECTS.items()
                     if subjects.get(r) != want)

    rows, partition_errors = {}, []
    for rid in sorted(by_note):
        path = os.path.join(corpus_dir, rid, 'fixture.json')
        d, cells = fixture_cells(path)

        # Each bucket from its OWN positive predicate over the cell. No
        # bucket is defined by subtracting another, so two rules claiming
        # the same cell is detectable -- and so is a cell no rule claims.
        #
        # This is what would have caught the first version's other error:
        # calling `direct` prior coverage inside #69's own rows put those
        # cells in target AND accepted_prior at once.
        target = {c for c in cells
                  if c[0] in OWNED_DISPATCH
                  and c[1] in PRODUCT_OPTIMIZER_MODES}
        prior = {c for c in cells
                 if (rid, c[0], c[1], c[2]) in ACCEPTED_PRIOR_CELLS}
        control = {c for c in cells if c[1] in CONTROL_ONLY_OPTIMIZER_MODES}
        deferred = {c for c in cells
                    if c[0] not in OWNED_DISPATCH
                    and c[1] in PRODUCT_OPTIMIZER_MODES}

        # The partition must be exact and pairwise disjoint. Asserted, not
        # arranged: a cell counted twice inflates coverage, and a cell in no
        # bucket is a claim nobody made about a cell that exists.
        buckets = {'target_by_69': target, 'accepted_prior': prior,
                   'control_only_unreachable': control,
                   'deferred_other_issue': deferred}
        names = sorted(buckets)
        for i, a in enumerate(names):
            for b in names[i + 1:]:
                dup = buckets[a] & buckets[b]
                if dup:
                    partition_errors.append(
                        {'row': rid, 'problem': 'cell in two buckets',
                         'buckets': [a, b], 'cells': sorted(dup)})
        union = set().union(*buckets.values())
        if union != cells:
            partition_errors.append(
                {'row': rid, 'problem': 'partition does not equal declared',
                 'missing': sorted(cells - union),
                 'extra': sorted(union - cells)})

        rows[rid] = {
            'subject': subjects[rid],
            'declared_cells': sorted(cells),
            'target_by_69': sorted(target),
            'accepted_prior': sorted(prior),
            'control_only_unreachable': sorted(control),
            'deferred_other_issue': sorted(deferred),
            'row_result_now': json.load(open(os.path.join(
                os.path.dirname(corpus_dir), 'evidence', 'rows',
                f'{rid}.json')))['result'],
            'whole_row_promotable': len(control) == 0 and len(deferred) == 0,
        }
    return rows, {
        'surface_derived_by_subject_note': sorted(by_note),
        'surface_derived_by_declares_virtual': sorted(by_virtual),
        'derivations_agree': agree,
        'rows_with_drifted_subject': drifted,
        'partition_errors': partition_errors,
    }


def summary(rows, checks):
    n = lambda k: sum(len(v[k]) for v in rows.values())  # noqa: E731
    return {
        'rows': len(rows),
        'declared_cells': n('declared_cells'),
        'target_by_69': n('target_by_69'),
        'accepted_prior_within_69_rows': n('accepted_prior'),
        'control_only_unreachable': n('control_only_unreachable'),
        'deferred_other_issue': n('deferred_other_issue'),
        'rows_whole_row_promotable': sorted(
            r for r, v in rows.items() if v['whole_row_promotable']),
        'accepted_prior_global_reference': sorted(
            '/'.join(c) for c in ACCEPTED_PRIOR_CELLS),
        'partition_exact': checks['partition_errors'] == [],
        'surface_derivations_agree': checks['derivations_agree'],
        'target_arch': TARGET_ARCH,
    }


if __name__ == '__main__':
    import sys
    here = os.path.dirname(os.path.abspath(__file__))
    corpus = os.path.normpath(os.path.join(here, '..', '..', 't0', 'corpus'))
    rows, checks = inventory(corpus)
    rec = {'schema': 'maot.m5.cellmap/2', 'issue': 69,
           'summary': summary(rows, checks), 'checks': checks, 'rows': rows}
    out = (sys.argv[1] if len(sys.argv) > 1
           else os.path.join(here, '..', 'evidence', 'm5_cell_map.json'))
    with open(out, 'w') as fh:
        json.dump(rec, fh, indent=2, sort_keys=True)
    print(json.dumps(rec['summary'], indent=2, sort_keys=True))
    ok = (rec['summary']['partition_exact']
          and rec['summary']['surface_derivations_agree']
          and not checks['rows_with_drifted_subject'])
    if not ok:
        print('CHECKS FAILED:', json.dumps(checks, indent=2), file=sys.stderr)
    sys.exit(0 if ok else 1)
