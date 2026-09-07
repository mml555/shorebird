#!/usr/bin/env python3
"""score_g4.py -- SEMANTIC-MAP-1 G4 (#53). Score the retention contract.

FAIL_OPEN IS A RESULT, NOT A FAILURE OF THIS HARNESS.

#53 requires each withheld retention class to fail closed at load. Two of the
four do not. That is a property of the system under test, and this lane's rule
is that a fail-open negative stays a FINDING and is never collapsed into a pass
or into a harness error. So `checks_failed` counts only things that would make
the measurement untrustworthy -- an uncontrolled confound, a dead control, an
unattributable category, a contract that cannot be stated per declaration, a
cost curve that was not measured. The enforcement result itself is reported
separately, as `retention_enforcement`.

Collapsing the two would be the over-claim the gate exists to prevent: a green
tick next to "every withheld class fails closed" when two of them silently
return the release's own answer instead.
"""
import json
import pathlib
import re
import sys

# Categories run_arms.sh can assign. Derived from that script's own source
# rather than restated here, for the reason SM1-G3 round 3 established: a
# hand-kept inventory drifts from the thing it claims to describe.
FAILS_CLOSED = 'FAILS_CLOSED'
FAILS_OPEN = 'FAILS_OPEN'
NO_EFFECT = 'NO_OBSERVABLE_EFFECT'
CONTROL_OK = 'CONTROL_DISPATCH_OK'
UNCLASSIFIED = 'UNCLASSIFIED'


def arm_category_surface(runner_path):
    """Every category run_arms.sh can emit, read from its own source.

    The categories are assigned by shell `CAT=...` statements, so the surface is
    the set of literals assigned to CAT. An unreadable assignment aborts rather
    than being dropped.
    """
    # Every `CAT=` assignment ANYWHERE on a line, not just at line start: the
    # control arm assigns it mid-line (`CONTROL_OK=1; CAT=...`), and a reader
    # anchored to the start silently missed that category -- which the coverage
    # check then reported as a stray observation. The reader has to see the
    # whole surface or it is just a differently-shaped hand-kept list.
    surface = set()
    for raw in pathlib.Path(runner_path).read_text().splitlines():
        for m in re.finditer(r'\bCAT=([^\s;]+)', raw):
            v = m.group(1).strip('"').strip("'")
            if not v or v.startswith('$'):
                print(f'score_g4: unreadable category assignment: {raw.strip()}',
                      file=sys.stderr)
                raise SystemExit(2)
            surface.add(v)
    return surface


def main():
    if len(sys.argv) < 5:
        print('usage: score_g4.py <gate-dir> <expectations.json> <out.json> '
              '<confound.txt>', file=sys.stderr)
        return 2
    gate, exp_path, out_json, confound_txt = sys.argv[1:5]
    gate = pathlib.Path(gate)
    exp = json.load(open(exp_path))

    lines, fails = [], 0
    extra = {}

    def arm(t):
        lines.append('')
        lines.append(f'--- {t} ---')

    # ---- 1. the confound must be CONTROLLED before anything is trusted -----
    arm('confound: retention must be attributable to the contract, not a pragma')
    conf = pathlib.Path(confound_txt).read_text()
    if 'PRAGMA_CONFOUND=CONTROLLED' in conf:
        lines.append('  ok      the subject carries no retaining pragma, the contract '
                     'is what retains it, and a pragma is shown to MASK a withheld '
                     'contract')
    else:
        lines.append('  FAILED  the pragma confound is not controlled, so every '
                     'retention result below may be measuring the pragma')
        fails += 1

    # ---- 2. the control must dispatch, or no refusal is attributable ------
    arms_doc = json.load(open(gate / 'evidence/arms.json'))
    arm('control: the full contract must reach the patch')
    if arms_doc['control_dispatch_ok']:
        lines.append('  ok      with the complete contract the patch subtype answered, '
                     'so a refusal below is attributable to the withheld entry')
    else:
        lines.append('  FAILED  the full-contract control did not dispatch to the '
                     'patch; every refusal below is unattributable')
        fails += 1

    # ---- 3. every arm must carry an attributable category ----------------
    arm('each withheld class is categorised, from a surface read off the runner')
    surface = arm_category_surface(gate / 'lib/run_arms.sh')
    observed = {r['category'] for r in arms_doc['rows']}
    extra['arm_category_surface'] = sorted(surface)
    extra['arm_categories_observed'] = sorted(observed)
    lines.append(f'  runner category surface: {len(surface)} '
                 f'({", ".join(sorted(surface))})')
    stray = observed - surface
    if stray:
        lines.append(f'  FAILED  categories outside the runner surface: {sorted(stray)}')
        fails += 1
    if UNCLASSIFIED in observed:
        lines.append('  FAILED  an arm was UNCLASSIFIED, so its outcome is not '
                     'attributable to the withheld entry')
        fails += 1
    if not stray and UNCLASSIFIED not in observed:
        lines.append('  ok      every arm carries a category the runner can justify')
    for r in arms_doc['rows']:
        lines.append(f'    {r["variant"]:24} {r["category"]}')
        lines.append(f'      {r["detail"][:110]}')

    # ---- 4. THE REQUIREMENT, AND WHERE THE SYSTEM DOES NOT MEET IT -------
    arm('#53: each withheld class must FAIL CLOSED at load')
    enforced = arms_doc['enforced_at_load']
    required = exp['must_fail_closed']
    closed = [k for k in required if enforced.get(k) == FAILS_CLOSED]
    open_ = [k for k in required if enforced.get(k) == FAILS_OPEN]
    noeff = [k for k in required if enforced.get(k) == NO_EFFECT]
    extra['enforced_at_load'] = enforced
    for k in required:
        lines.append(f'    {k:22} {enforced.get(k, "UNMEASURED")}')
    if open_:
        # A FINDING. Not a pass, and not a failure of this harness.
        lines.append(f'  FINDING {len(open_)} of {len(required)} retention classes do '
                     f'NOT fail closed: {", ".join(open_)}')
        lines.append('          The module loaded and the call site still reached the '
                     'AOT body, so the release answered its own question and the patch '
                     'was silently ignored. #53 designates this FAIL_OPEN and requires '
                     'it be reported as a finding, never as a pass.')
    if noeff:
        lines.append(f'  FINDING {", ".join(noeff)} had no observable effect on this '
                     f'shape, so this corpus does not establish that it is required')
    if closed:
        lines.append(f'  ok      {", ".join(closed)} fails closed with an attributable '
                     f'cause')
    if not closed:
        lines.append('  FAILED  no retention class fails closed at all, so the arms '
                     'cannot distinguish enforcement from its absence')
        fails += 1

    # ---- 5. the contract must be stateable PER DECLARATION ---------------
    arm("#53's stop condition: retention stated per declaration, not per library")
    rows = json.load(open(gate / 'evidence/retention_rows.json'))
    per_decl = all(r.get('required_entries') for r in rows['rows'])
    extra['retention_row_count'] = rows['count']
    extra['required_class_histogram'] = rows['required_class_histogram']
    if rows['count'] > 0 and per_decl:
        lines.append(f'  ok      all {rows["count"]} declarations name their own '
                     f'contract entries, so the stop condition is not triggered')
        lines.append(f'          histogram: {rows["required_class_histogram"]}')
    else:
        lines.append('  FAILED  retention could not be stated per declaration; per #53 '
                     'the gate stops and classifies rather than proceeding')
        fails += 1

    # Every row must carry the MEASURED enforcement, not the contract's intent.
    unmeasured = [r for r in rows['rows']
                  if any(v == 'UNMEASURED' for v in r['enforced_at_load'].values())]
    if unmeasured:
        lines.append(f'  FAILED  {len(unmeasured)} row(s) claim a contract class whose '
                     f'enforcement was never measured')
        fails += 1
    else:
        lines.append('  ok      every row carries measured enforcement, so "required" '
                     'is never mistaken for "enforced"')

    # ---- 6. the cost curve must be MEASURED, not extrapolated ------------
    arm('#53: release-scale retention cost measured, not extrapolated')
    scale = json.load(open(gate / 'evidence/scale.json'))
    pts = {r['n']: r['delta'] for r in scale['rows']}
    extra['scale'] = scale['rows']
    need = exp['scale_points']
    missing = [n for n in need if n not in pts]
    if missing:
        lines.append(f'  FAILED  the curve is missing N={missing}, so it was not '
                     f'measured at release scale')
        fails += 1
    else:
        floor = pts[0]
        big = max(pts)
        marginal = (pts[big] - floor) / big
        naive = exp['sl1_per_member_bytes'] * big
        lines.append(f'  ok      measured at N={sorted(pts)}')
        lines.append(f'          fixed floor (N=0)      {floor:,} bytes')
        lines.append(f'          marginal per member    ~{marginal:.0f} bytes')
        lines.append(f'          actual at N={big}         {pts[big]:,} bytes')
        lines.append(f'          naive {exp["sl1_per_member_bytes"]:,}xN would be '
                     f'{naive:,} bytes  ({naive/pts[big]:.0f}x the measurement)')
        extra['fixed_floor_bytes'] = floor
        extra['marginal_bytes_per_member'] = round(marginal, 1)
        extra['naive_overestimate_factor'] = round(naive / pts[big], 1)
        if marginal >= exp['sl1_per_member_bytes']:
            lines.append('  FINDING the marginal cost is NOT below the single-member '
                         'figure, so naive multiplication was not an overestimate here')

    state = ('PARTIAL' if open_ or noeff else 'FULL') if closed else 'NONE'
    print('\n'.join(lines))
    print()
    print(f'RETENTION_ENFORCEMENT={state}')
    print(f'SUMMARY checks_failed={fails}')
    print('G4 RETENTION VERIFIED' if fails == 0 else 'G4 RETENTION FAILED')

    json.dump({
        'schema': 'semantic-map-1/g4-score/1', 'gate': 'SM1-G4', 'issue': 53,
        'checks_failed': fails,
        'retention_enforcement': state,
        'fail_open_classes': open_,
        'no_effect_classes': noeff,
        'fails_closed_classes': closed,
        'arms': extra,
    }, open(out_json, 'w'), indent=2)
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
