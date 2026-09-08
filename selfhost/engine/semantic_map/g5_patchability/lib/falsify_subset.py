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
import re
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
    """Match either schema's target: a bare name, or a full G1 key."""
    for r in demo['rows']:
        t = r.get('target', '')
        if t == target or t.endswith('#' + target.split('.')[-1]):
            return r['declaration_id']
    raise SystemExit(f'falsify_subset: no demonstration row for {target}')


def run(label, pred, demo, want, expect_fragment=None):
    pp, dp = f'{W}/subset_pred.json', f'{W}/subset_demo.json'
    json.dump(pred, open(pp, 'w'))
    json.dump(demo, open(dp, 'w'))
    p = subprocess.run([sys.executable, SCORE, pp, dp, f'{W}/subset_out.json'],
                       capture_output=True, text=True)
    out = (p.stdout + p.stderr).strip()
    # Exact match on the marker line. 'SUBSET_HOLDS' is a PREFIX of
    # 'SUBSET_HOLDS_VACUOUSLY', so a substring test would silently conflate a
    # real holding with a vacuous one.
    m = re.search(r'^SM1_G5_SUBSET: (\S+)$', out, re.M)
    got = m.group(1) if m else 'ERROR'
    if got in ('SUBSET_HOLDS', 'SUBSET_HOLDS_VACUOUSLY') and want == 'SUBSET_HOLDS':
        want = got  # either holding form satisfies an arm that expects a pass
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


DERIVED = str(BD.get('schema', '')).endswith('/2')
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
# The two schemas refuse this for different reasons, and each arm asserts its
# own: schema 1 by cross-checking the declared count against the map, schema 2
# by RECOMPUTING the derivation from the recorded state, which is stronger --
# lowering the count cannot make the row self-consistent any more.
run('under-observation: stale sites deleted AND the count lowered',
    predict(BP, BASE_W), hide_stale(BD, BASE_W, also_lower=True), 'FAIL_OPEN',
    'disagree with the recorded state' if DERIVED
    else 'disagrees with the call-site map')


def break_map(demo):
    q = copy.deepcopy(demo)
    if str(q.get('schema', '')).endswith('/2'):
        # Derived form: drop a stale site from a row. Its completeness rule is
        # per-row, so the omission must be caught there instead.
        for r in q['rows']:
            keep = [s for s in r['call_sites'] if s['moved']]
            if len(keep) != len(r['call_sites']):
                r['call_sites'] = keep
                break
    else:
        q['call_site_map'] = {k: v for k, v in q['call_site_map'].items()
                              if not k.endswith('work')}
    return q


run('the recorded call sites no longer account for the observed state',
    predict(BP, BASE_W), break_map(BD), 'FAIL_OPEN')
run('the demonstration declares itself predictor-derived',
    BP, {**copy.deepcopy(BD), 'derived_from_predictor': True}, 'FAIL_OPEN',
    'predictor-derived')
def strip_meta(demo):
    """Remove whatever makes completeness checkable, per schema."""
    q = copy.deepcopy(demo)
    for k in ('call_site_map', 'printed_fields'):
        q.pop(k, None)
    for r in q.get('rows', []):
        r.pop('observed_fields', None)
        if DERIVED:
            # For the derived form the recorded state IS the completeness
            # metadata: without it the derivation cannot be recomputed.
            r.pop('state_before', None)
            r.pop('state_after', None)
    return q


run('the demonstration carries no completeness metadata',
    BP, strip_meta(BD), 'FAIL_OPEN')

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
