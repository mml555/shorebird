#!/usr/bin/env python3
"""Prove the subset scorer can fail, and fails for the right reason.

The subset property is trivially satisfied while nothing is predicted
patchable, so the result carries no information on its own. What carries
information is that the scorer FAILS on an injected over-claim, refuses a
demonstration that cannot witness anything, and stays PASS under merely reduced
coverage. Each arm mutates a copy; the banked inputs are never edited.

usage: falsify_subset.py <predictions.json> <demonstrated.json> <workdir>
"""
import copy
import json
import os
import subprocess
import sys

PRED, DEMO, W = sys.argv[1], sys.argv[2], sys.argv[3]
HERE = os.path.dirname(os.path.abspath(__file__))
SCORE = f'{HERE}/score_subset.py'
BP = json.load(open(PRED))
BD = json.load(open(DEMO))
results = []


def did_of(demo, target):
    for r in demo['rows']:
        if r['target'] == target:
            return r['declaration_id']
    raise SystemExit(f'falsify_subset: no demonstration row for {target}')


def run(label, pred, demo, want, expect_fragment=None):
    pp, dp = f'{W}/subset_pred.json', f'{W}/subset_demo.json'
    json.dump(pred, open(pp, 'w'))
    json.dump(demo, open(dp, 'w'))
    p = subprocess.run([sys.executable, SCORE, pp, dp, f'{W}/subset_out.json'],
                       capture_output=True, text=True)
    out = (p.stdout + p.stderr).strip()
    got = 'FAIL_OPEN' if 'SM1_G5_SUBSET: FAIL_OPEN' in out else (
        'SUBSET_HOLDS' if 'SM1_G5_SUBSET: SUBSET_HOLDS' in out else 'ERROR')
    bad = []
    if got != want:
        bad.append(f'verdict {got}, expected {want}')
    if expect_fragment and expect_fragment not in out:
        bad.append(f'refused, but not for the stated reason: '
                   f'{out.splitlines()[-2][:70] if len(out.splitlines()) > 1 else out[:70]}')
    if want == 'FAIL_OPEN' and p.returncode == 0:
        bad.append('FAIL_OPEN but exit status 0')
    results.append((label, 'FAIL' if bad else 'pass',
                    '; '.join(bad) if bad else got))


def predict(pred, did, value=True):
    q = copy.deepcopy(pred)
    for r in q['rows']:
        if r['declaration_id'] == did:
            r['predicted_patchable'] = value
    return q


BASE_W = did_of(BD, 'Base.work')
ALPHA = did_of(BD, 'alpha')
SMALL = did_of(BD, 'smallTarget')

run('BASELINE the banked pair', BP, BD, 'SUBSET_HOLDS')

# The over-claims that must fail.
run('over-claim: a declaration with a stale ordinary call site',
    predict(BP, BASE_W), BD, 'FAIL_OPEN', 'OVER-CLAIM')
run('over-claim: a declaration whose every call site is stale',
    predict(BP, SMALL), BD, 'FAIL_OPEN', 'OVER-CLAIM')


def drop_row(demo, did):
    q = copy.deepcopy(demo)
    q['rows'] = [r for r in q['rows'] if r['declaration_id'] != did]
    return q


run('over-claim: a declaration with no demonstration row at all',
    predict(BP, ALPHA), drop_row(BD, ALPHA), 'FAIL_OPEN', 'OVER-CLAIM')

# The legitimate case must still pass, or the scorer is just refusing.
run('a demonstrated declaration may be predicted',
    predict(BP, ALPHA), BD, 'SUBSET_HOLDS')
run('reduced coverage is safe (nothing predicted)', BP, BD, 'SUBSET_HOLDS')


def strip_sites(demo, did):
    q = copy.deepcopy(demo)
    for r in q['rows']:
        if r['declaration_id'] == did:
            r['call_sites'] = []
    return q


run('attach and direct invoke alone do not demonstrate',
    predict(BP, ALPHA), strip_sites(BD, ALPHA), 'FAIL_OPEN', 'under-observed')


def hide_stale(demo, did, also_lower=False):
    q = copy.deepcopy(demo)
    for r in q['rows']:
        if r['declaration_id'] == did:
            r['call_sites'] = [s for s in r['call_sites'] if s['moved']]
            if also_lower:
                r['sites_expected'] = len(r['call_sites'])
    return q


run('under-observation: stale sites deleted from the demonstration',
    predict(BP, BASE_W), hide_stale(BD, BASE_W), 'FAIL_OPEN', 'under-observed')
run('under-observation: stale sites deleted AND the count lowered',
    predict(BP, BASE_W), hide_stale(BD, BASE_W, also_lower=True), 'FAIL_OPEN',
    'disagrees with the call-site map')


def break_map(demo):
    q = copy.deepcopy(demo)
    q['call_site_map'] = {k: v for k, v in q['call_site_map'].items()
                          if k != 'Base.work'}
    return q


run('the call-site map no longer accounts for every printed field',
    BP, break_map(BD), 'FAIL_OPEN', 'does not account for every printed field')
run('the demonstration declares itself predictor-derived',
    BP, {**copy.deepcopy(BD), 'derived_from_predictor': True}, 'FAIL_OPEN',
    'predictor-derived')
run('the demonstration carries no completeness metadata',
    BP, {k: v for k, v in BD.items()
         if k not in ('call_site_map', 'printed_fields')},
    'FAIL_OPEN', 'completeness cannot be checked')

print(f'{"arm":58} {"result":6} detail')
print('-' * 104)
for label, verdict, detail in results:
    print(f'{label:58} {verdict:6} {detail}')
failed = [r for r in results if r[1] == 'FAIL']
print('-' * 104)
print(f'arms={len(results)} passed={len(results) - len(failed)} failed={len(failed)}')
print('SM1_G5_SUBSET_FALSIFICATION: '
      + ('SCORER_IS_SENSITIVE' if not failed else 'DEFECTS_PRESENT'))
sys.exit(1 if failed else 0)
