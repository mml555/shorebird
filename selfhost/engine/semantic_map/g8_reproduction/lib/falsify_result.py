#!/usr/bin/env python3
"""Falsify the REPORTING PATH, without re-running a single gate.

The four partitions are the gate's public answer, so they need their own
negatives: a reporting layer that renders REPRODUCTION: PASS regardless of its
inputs would be the most expensive vacuous check in the programme -- it would
certify the whole lane.

REPORT-ONLY, following the SEMANTIC-LINKER-1 g6c_harness precedent. Each arm
copies the structured inputs into a scratch tree, mutates ONE of them, re-runs
emit_result.py against the copy, and asserts the named partition moved to the
named value. Nothing under the gate's own evidence directory is touched, so an
arm cannot corrupt the bank it is reporting on.

EVERY ARM NAMES THE PARTITION AND THE VALUE. An arm that only asserted
"something failed" would pass when the wrong partition moved, which is how a
reason-specific defect hides behind a generic failure.

CONTROL: a weakened emitter that hard-codes the four partitions to their happy
values must FAIL every arm. Without that, an arm suite proves the emitter
reacts to input, not that it reacts correctly.

usage: falsify_result.py <semantic-map-dir> <g8-dir> <workdir>
"""
import json
import pathlib
import re
import shutil
import subprocess
import sys

SM = pathlib.Path(sys.argv[1]).resolve()
G8 = pathlib.Path(sys.argv[2]).resolve()
W = pathlib.Path(sys.argv[3]).resolve()
EMIT = G8 / 'lib' / 'emit_result.py'
GATES = ['run_route2.sh', 'run_dispatch_experiment.sh', 'run_predictor_bank.sh',
         'run_subset.sh', 'run_corpora.sh', 'run_g6.sh', 'run_g7.sh']


def fresh():
    """A scratch copy of every input the emitter reads."""
    if W.exists():
        shutil.rmtree(W)
    W.mkdir(parents=True)
    shutil.copytree(SM, W / 'sm', symlinks=True)
    shutil.copy(G8 / 'inventory.json', W / 'inventory.json')
    for f in ('inventory_check.json', 'negative_outcomes.json',
              'artifact_digests.json', 'g8_reproduction.txt'):
        shutil.copy(G8 / 'evidence' / f, W / f)
    (W / 'gates.txt').write_text(''.join(f'{g} 0\n' for g in GATES))


def run(emitter=EMIT):
    out = W / 'result.json'
    # Delete first: a crashed emitter must not be scored on the previous arm's
    # file. That exact stale read cost a full debugging cycle in this gate.
    if out.exists():
        out.unlink()
    r = subprocess.run(
        [sys.executable, str(emitter), str(W / 'sm'), str(W / 'inventory.json'),
         str(out), str(W / 'inventory_check.json'),
         str(W / 'negative_outcomes.json'), str(W / 'artifact_digests.json'),
         str(W / 'gates.txt'), str(W / 'g8_reproduction.txt')],
        capture_output=True, text=True)
    if not out.exists():
        return None, (r.stderr.strip().splitlines() or ['<no stderr>'])[-1][:90]
    try:
        return json.load(open(out))['result'], ''
    except Exception as ex:                                  # noqa: BLE001
        return None, f'{type(ex).__name__} reading the emitted result'


# ---- the arms ------------------------------------------------------------
def m_json(name, fn):
    d = json.load(open(W / name))
    fn(d)
    json.dump(d, open(W / name, 'w'), indent=2)


def drop_pattern(rel, pattern):
    p = W / 'sm' / rel
    p.write_text(re.sub(pattern, 'XX_REMOVED_XX', p.read_text()))


ARMS = [
 ('gate-exit-nonzero', 'REPRODUCTION', 'FAIL',
  'a gate that exited non-zero cannot be reported as reproduced',
  lambda: (W / 'gates.txt').write_text(
      ''.join(f'{g} {1 if g == "run_route2.sh" else 0}\n' for g in GATES))),

 ('gate-status-dropped', 'REPRODUCTION', 'FAIL',
  'a gate that reported NO status must not pass by absence',
  lambda: (W / 'gates.txt').write_text(
      ''.join(f'{g} 0\n' for g in GATES[:-1]))),

 ('gate-exit-nonzero-feasibility', 'FEASIBILITY_EVIDENCE', 'NOT_REPRODUCED',
  'the substantive partition must move too, not only REPRODUCTION',
  lambda: (W / 'gates.txt').write_text(
      ''.join(f'{g} {1 if g == "run_g7.sh" else 0}\n' for g in GATES))),

 ('equality-not-literal', 'REPRODUCTION', 'FAIL',
  'inventory == tested == caught broken by one dropped id',
  lambda: m_json('inventory_check.json',
                 lambda d: d['equality']['tested_ids'].pop())),

 ('equality-same-length-different-ids', 'REPRODUCTION', 'FAIL',
  'equal COUNTS with different ids must still fail -- the equality is literal',
  lambda: m_json('inventory_check.json',
                 lambda d: d['equality']['tested_ids'].__setitem__(
                     0, 'not-a-real-arm'))),

 ('inventory-findings-present', 'REPRODUCTION', 'FAIL',
  'the checker reported a finding; the report may not smooth it over',
  lambda: m_json('inventory_check.json',
                 lambda d: d['findings'].append(
                     {'code': 'ARTIFACT_CORRUPTED', 'detail': 'injected'}))),

 ('digest-coverage-short', 'REPRODUCTION', 'FAIL',
  'fewer artifacts digest-checked than the inventory declares',
  lambda: m_json('inventory_check.json',
                 lambda d: d.__setitem__('artifacts_digest_checked', 20))),

 ('digest-snapshot-short', 'REPRODUCTION', 'FAIL',
  'an artifact absent from the digest snapshot',
  lambda: m_json('artifact_digests.json',
                 lambda d: d['artifacts'].pop(next(iter(d['artifacts']))))),

 ('negative-unrestored', 'REPRODUCTION', 'FAIL',
  'a mutation that was never restored',
  lambda: m_json('negative_outcomes.json',
                 lambda d: d.__setitem__('restorations', 52))),

 ('negative-uncaught', 'REPRODUCTION', 'FAIL',
  'a tested arm that was not caught',
  lambda: m_json('negative_outcomes.json',
                 lambda d: d['caught_ids'].pop())),

 ('negative-arm-dropped-but-totals-consistent', 'REPRODUCTION', 'FAIL',
  'mutations+controls no longer equals the tested set, so an arm vanished',
  lambda: m_json('negative_outcomes.json',
                 lambda d: d.__setitem__('mutations', 52))),

 ('bank-not-intact', 'REPRODUCTION', 'FAIL',
  'the bank did not survive the mutations',
  lambda: m_json('negative_outcomes.json',
                 lambda d: d.__setitem__('bank_intact_after', False))),

 ('canonical-aot-not-reproduced', 'FEASIBILITY_EVIDENCE', 'NOT_REPRODUCED',
  'the rebuilt AOT no longer matches the banked one',
  lambda: (W / 'g8_reproduction.txt').write_text(
      (W / 'g8_reproduction.txt').read_text()
      .replace('\n    IDENTICAL\n', '\n    DIFFERS\n'))),

 ('g1-projection-not-reproduced', 'FEASIBILITY_EVIDENCE', 'NOT_REPRODUCED',
  'the G1 projection no longer matches the banked copy',
  lambda: (W / 'g8_reproduction.txt').write_text(
      (W / 'g8_reproduction.txt').read_text()
      .replace('G1 projection IDENTICAL to the banked copy',
               'G1 projection DIFFERS from the banked copy'))),

 ('product-surface-changed', 'REPRODUCTION', 'FAIL',
  'the product surface moved during the run',
  lambda: (W / 'g8_reproduction.txt').write_text(
      (W / 'g8_reproduction.txt').read_text()
      + '\n  CHANGED    deadbeef  packages\n')),

 ('reader-accounting-unbalanced', 'FEASIBILITY_EVIDENCE', 'NOT_REPRODUCED',
  'the reader accounted for fewer rows than it read',
  lambda: m_json_sm('g5_patchability/evidence/inlining_state.json',
                    lambda d: d['accounting'].__setitem__('accounted', 35))),

 ('fail-open-finding-erased', 'KNOWN_FAIL_OPEN_FINDINGS', 'ABSENT',
  'a declared FAIL_OPEN finding stopped reproducing -- the worst reason to pass',
  lambda: drop_pattern('g5_patchability/evidence/corpora.txt',
                       r'SM1_G5_SUBSET: FAIL_OPEN')),

 ('fail-open-finding-below-min', 'KNOWN_FAIL_OPEN_FINDINGS', 'ABSENT',
  'the finding is present but on fewer corpora than declared',
  lambda: replace_once('g5_patchability/evidence/corpora.txt',
                       'SM1_G5_SUBSET: FAIL_OPEN', 'SM1_G5_SUBSET: OK')),

 ('fail-open-erased-forces-reproduction-fail', 'REPRODUCTION', 'FAIL',
  'ABSENT findings must ALSO fail REPRODUCTION, not sit in a side field',
  lambda: drop_pattern('g5_patchability/evidence/reader_falsification.txt',
                       r'SM1_G5_READER_FALSIFICATION: DEFECTS_PRESENT')),

 ('fail-open-evidence-unreadable', 'KNOWN_FAIL_OPEN_FINDINGS', 'ABSENT',
  'the evidence file is gone; absence is not reproduction',
  lambda: (W / 'sm' / 'g5_patchability/evidence/subset_check.txt').unlink()),

 # The emitter must be TOTAL over its own inputs: an unreadable input is a
 # recorded refusal, never a traceback, and never a green field. Verified by
 # hand once, so kept as arms rather than left to hold by accident.
 ('gate-status-file-absent', 'REPRODUCTION', 'FAIL',
  'no gate statuses at all -- absence is not reproduction',
  lambda: (W / 'gates.txt').unlink()),

 ('inventory-check-unparseable', 'REPRODUCTION', 'FAIL',
  'a truncated inventory_check.json must refuse, not crash and not pass',
  lambda: (W / 'inventory_check.json').write_text(
      (W / 'inventory_check.json').read_text()[:200])),

 ('digest-snapshot-unparseable', 'REPRODUCTION', 'FAIL',
  'a truncated digest snapshot must refuse',
  lambda: (W / 'artifact_digests.json').write_text('{"artifacts":')),

 ('outcomes-unparseable', 'REPRODUCTION', 'FAIL',
  'a truncated negative_outcomes.json must refuse',
  lambda: (W / 'negative_outcomes.json').write_text('{"tested_ids": [')),

 ('transcript-absent', 'FEASIBILITY_EVIDENCE', 'NOT_REPRODUCED',
  'without the transcript the reproduced identities cannot be witnessed',
  lambda: (W / 'g8_reproduction.txt').unlink()),

 ('prerequisite-evidence-deleted', 'PRODUCTION_PREREQUISITES', 'UNDERIVABLE',
  'a prerequisite whose binding cannot resolve is not a prerequisite met',
  lambda: (W / 'sm' / 'g5_patchability/evidence/dispatch_experiment.txt')
  .unlink()),

 ('prerequisite-promoted-to-resolved', 'PRODUCTION_PREREQUISITES',
  'UNDERIVABLE',
  'editing the inventory to claim RESOLVED must contradict the evidence',
  lambda: m_json('inventory.json', lambda d: d['production_prerequisites']
                 ['entries'][0].__setitem__('status', 'RESOLVED'))),

 ('prerequisite-binding-expectation-removed', 'PRODUCTION_PREREQUISITES',
  'UNDERIVABLE',
  'a binding that declares no implied status cannot derive one',
  lambda: m_json('inventory.json', lambda d: d['production_prerequisites']
                 ['entries'][0]['binding'].pop('implies_status'))),

 ('prerequisite-cost-evidence-flipped', 'PRODUCTION_PREREQUISITES',
  'UNDERIVABLE',
  'the numeric binding stops holding when the projection is no longer low',
  lambda: m_json_sm('g7_cost/evidence/families.json',
                    lambda d: d['families']['retention_cost_at_scale']
                    .__setitem__('measured_over_projected', 0.9))),

 ('prerequisite-marker-forged-elsewhere', 'PRODUCTION_PREREQUISITES',
  'UNDERIVABLE',
  'the release-mismatch arm must be PASSING; a FAIL line is the control '
  'correctly failing, not evidence the refusal is enforced',
  lambda: replace_all('g5_patchability/evidence/predictor_falsification.txt',
                      'INLINING_EVIDENCE_RELEASE_MISMATCH   pass',
                      'INLINING_EVIDENCE_RELEASE_MISMATCH   FAIL')),
]


def m_json_sm(rel, fn):
    p = W / 'sm' / rel
    d = json.load(open(p))
    fn(d)
    json.dump(d, open(p, 'w'), indent=2)


def replace_once(rel, old, new):
    p = W / 'sm' / rel
    p.write_text(p.read_text().replace(old, new, 1))


def replace_all(rel, old, new):
    p = W / 'sm' / rel
    p.write_text(p.read_text().replace(old, new))


# ---- run -----------------------------------------------------------------
print('SM1-G8 -- the REPORTING PATH, falsified in report-only mode')
print(f'  {len(ARMS)} arms. Each mutates one structured input and asserts the')
print('  named partition moves to the named value. No gate is re-run.')
print()
fresh()
base, err = run()
if base is None:
    raise SystemExit(f'  baseline emitter produced nothing: {err}')
print(f'  baseline  {base}')
BASE_OK = {'REPRODUCTION': 'PASS', 'FEASIBILITY_EVIDENCE': 'REPRODUCED',
           'KNOWN_FAIL_OPEN_FINDINGS': 'REPRODUCED',
           'PRODUCTION_PREREQUISITES': 'UNRESOLVED'}
if base != BASE_OK:
    raise SystemExit(f'  baseline is not the accepted shape: expected {BASE_OK}')
print()

failed = []
for arm_id, partition, want, why, mutate in ARMS:
    fresh()
    try:
        mutate()
    except Exception as ex:                                  # noqa: BLE001
        failed.append(arm_id)
        print(f'  {arm_id:46} SETUP-FAILED {type(ex).__name__}: {ex}')
        continue
    got, err = run()
    if got is None:
        failed.append(arm_id)
        print(f'  {arm_id:46} NO OUTPUT -- the emitter did not resolve this '
              f'to a partition: {err}')
        continue
    ok = got.get(partition) == want
    if not ok:
        failed.append(arm_id)
    print(f'  {arm_id:46} {"pass" if ok else "FAIL"}   '
          f'{partition}={got.get(partition)} (want {want})')
    if not ok:
        print(f'  {"":46}        full result {got}')
    print(f'  {"":46}        {why}')

# ---- the control ---------------------------------------------------------
print()
print('  CONTROL -- an emitter that hard-codes the happy partitions must FAIL')
print('  every arm above. Otherwise the arms prove only that the emitter reads')
print('  its input, not that it reads it correctly.')
weak = W / 'weak_emit.py'
weak.write_text(
    'import json,sys\n'
    "json.dump({'result':{'REPRODUCTION':'PASS',"
    "'FEASIBILITY_EVIDENCE':'REPRODUCED',"
    "'KNOWN_FAIL_OPEN_FINDINGS':'REPRODUCED',"
    "'PRODUCTION_PREREQUISITES':'UNRESOLVED'}}, open(sys.argv[3],'w'))\n")
weak_survivors = []
for arm_id, partition, want, why, mutate in ARMS:
    fresh()
    try:
        mutate()
    except Exception:                                        # noqa: BLE001
        continue
    got, _ = run(weak)
    if got is not None and got.get(partition) == want:
        weak_survivors.append(arm_id)
print(f'    arms the weakened emitter still satisfies: {len(weak_survivors)}')
if weak_survivors:
    print(f'    SURVIVORS: {weak_survivors}')

print()
print(f'  arms={len(ARMS)} failed={len(failed)} '
      f'control_survivors={len(weak_survivors)}')
if failed:
    print(f'  FAILED ARMS: {failed}')
bad = bool(failed) or bool(weak_survivors)
print(f'SM1_G8_REPORT_FALSIFICATION: '
      f'{"DEFECTS_PRESENT" if bad else "EVERY_PARTITION_DISCRIMINATES"}')
sys.exit(1 if bad else 0)
