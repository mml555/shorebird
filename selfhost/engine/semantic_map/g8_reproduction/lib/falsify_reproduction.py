#!/usr/bin/env python3
"""G8's negatives: missing evidence, corrupted evidence, stale summaries, and
the three sensitivity controls #57 requires on the timing classifier.

EVERY MUTATION IS RESTORED BYTE-FOR-BYTE and the restoration is VERIFIED by
digest. A negative suite that leaves the bank altered has damaged the thing it
was checking; the restore is asserted, not assumed.

usage: falsify_reproduction.py <semantic-map-dir> <inventory.json> <workdir>
"""
import hashlib
import json
import pathlib
import subprocess
import sys

SM, INV, W = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
HERE = pathlib.Path(__file__).resolve().parent
CHECK = HERE / 'check_inventory.py'
sys.path.insert(0, str(SM / 'g7_cost' / 'lib'))
from classify_order import classify           # noqa: E402

inv = json.load(open(INV))
results = []
W.mkdir(parents=True, exist_ok=True)


def sha(p):
    return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()


def run_check():
    p = subprocess.run([sys.executable, str(CHECK), str(SM), INV,
                        str(W / 'chk.json')], capture_output=True, text=True)
    try:
        return p.returncode, json.load(open(W / 'chk.json'))
    except Exception:                                     # noqa: BLE001
        return p.returncode, None


def mutate_arm(label, relpath, mutate, want_code):
    """Mutate one banked artifact, require the checker to report want_code,
    then restore it and PROVE the restoration byte-for-byte."""
    target = SM / relpath
    if not target.exists():
        results.append((label, 'FAIL', f'{relpath} does not exist'))
        return
    original = target.read_bytes()
    before = hashlib.sha256(original).hexdigest()
    try:
        mutate(target, original)
        rc, out = run_check()
        if out is None:
            results.append((label, 'FAIL', 'the checker produced no output'))
            return
        codes = [f['code'] for f in out['findings']]
        bad = []
        if rc == 0:
            bad.append('the checker accepted the mutated bank')
        if want_code not in codes:
            bad.append(f'missing {want_code}, got {sorted(set(codes))[:3]}')
        results.append((label, 'FAIL' if bad else 'pass',
                        '; '.join(bad) if bad else f'{want_code}'))
    finally:
        target.write_bytes(original)
        after = sha(target)
        results.append((f'  restored {relpath}',
                        'pass' if after == before else 'FAIL',
                        'byte-for-byte' if after == before
                        else f'DIGEST CHANGED {before[:12]} -> {after[:12]}'))


# ---- missing evidence ----------------------------------------------------
def delete(target, original):
    target.unlink()


mutate_arm('an inventoried artifact is missing',
           'g5_patchability/evidence/inlining_state.json',
           delete, 'ARTIFACT_MISSING_OR_EMPTY')
mutate_arm('an inventoried transcript is missing',
           'g6_binding/evidence/g6_binding.txt',
           delete, 'ARTIFACT_MISSING_OR_EMPTY')

# ---- emptied evidence ----------------------------------------------------
mutate_arm('an inventoried artifact is emptied',
           'g7_cost/evidence/samples.jsonl',
           lambda t, o: t.write_bytes(b''), 'ARTIFACT_MISSING_OR_EMPTY')

# ---- corrupted evidence --------------------------------------------------
mutate_arm('a transcript loses a declared positive verdict',
           'g6_binding/evidence/g6_binding.txt',
           lambda t, o: t.write_bytes(
               o.replace(b'SM1_G6: BINDING_ENFORCED', b'SM1_G6: SOMETHING')),
           'DECLARED_POSITIVE_NOT_TESTED')
mutate_arm('a control stops recording its failure verdict',
           'g6_binding/evidence/g6_binding.txt',
           lambda t, o: t.write_bytes(
               o.replace(b'SM1_G6_BINDING_FALSIFICATION: DEFECTS_PRESENT',
                         b'SM1_G6_BINDING_FALSIFICATION: EVERY_SWAP_REFUSED')),
           'DECLARED_CONTROL_NEVER_FAILED')
mutate_arm('a known FAIL_OPEN finding stops being produced',
           'g5_patchability/evidence/corpora.txt',
           lambda t, o: t.replace(t) if False else t.write_bytes(
               o.replace(b'SM1_G5_SUBSET: FAIL_OPEN', b'SM1_G5_SUBSET: OK')),
           'FAIL_OPEN_FINDING_NOT_REPRODUCED')
mutate_arm('a deterministic binding drifts',
           'g7_cost/evidence/families.json',
           lambda t, o: t.write_bytes(o.replace(b'4330120', b'4330121')),
           'DETERMINISTIC_BINDING_CHANGED')
mutate_arm('a required timing stage disappears',
           'g7_cost/evidence/samples.jsonl',
           lambda t, o: t.write_bytes(
               b'\n'.join(l for l in o.split(b'\n')
                          if b'"map_reader"' not in l)),
           'TIMING_STAGE_MISSING')
mutate_arm('one schedule side disappears',
           'g7_cost/evidence/samples.jsonl',
           lambda t, o: t.write_bytes(
               b'\n'.join(l for l in o.split(b'\n')
                          if b'"map_first"' not in l)),
           'TIMING_ORDER_MISSING')
mutate_arm('a timing producer is recorded as failed',
           'g7_cost/evidence/samples.jsonl',
           lambda t, o: t.write_bytes(o.replace(b'"exit": 0', b'"exit": 1', 1)),
           'TIMING_PRODUCER_FAILED')

# ---- THE STALE-SUMMARY NEGATIVE #57 requires -----------------------------
# A summary that no longer describes the samples beside it. This is the class
# that has recurred through G5-G7: a derived file surviving a failed run and
# being read as current.
mutate_arm('the summary no longer matches the retained samples',
           'g7_cost/evidence/families.json',
           lambda t, o: t.write_bytes(
               o.replace(b'"samples": 60', b'"samples": 999')
                .replace(b'"samples": 54', b'"samples": 999')),
           'SUMMARY_NOT_FROM_SAMPLES')

# ---- the three classifier controls #57 requires --------------------------
def cls(label, a, z, want, why):
    v = classify(a, z)
    got = v.get('order_dependent')
    ok = got is want
    results.append((label, 'pass' if ok else 'FAIL',
                    f'{why}: order_dependent={got}' if ok
                    else f'{why}: got {got}, expected {want}'))


cls('classifier: >10% AND beyond noise flags ORDER_DEPENDENT',
    {'n': 3, 'median_ms': 100.0, 'stdev_ms': 1.0},
    {'n': 3, 'median_ms': 130.0, 'stdev_ms': 1.0},
    True, 'ratio 1.30, gap 30 > noise 1')
cls('classifier: >10% but INSIDE noise does not flag',
    {'n': 3, 'median_ms': 100.0, 'stdev_ms': 50.0},
    {'n': 3, 'median_ms': 130.0, 'stdev_ms': 50.0},
    False, 'ratio 1.30, gap 30 < noise 50')
v = classify({'n': 3, 'median_ms': 100.0, 'stdev_ms': 1.0}, {'n': 0})
results.append((
    'classifier: a missing schedule side is UNDECIDABLE, not unaffected',
    'pass' if v['decidable'] is False and v['order_dependent'] is None
    else 'FAIL',
    f"decidable={v['decidable']} order_dependent={v['order_dependent']}"))

# ---- the bank must be intact at the end ----------------------------------
rc, out = run_check()
results.append(('the bank is consistent again after every mutation',
                'pass' if rc == 0 else 'FAIL',
                out['verdict'] if out else 'checker produced no output'))

print(f'{"arm":58} {"result":6} detail')
print('-' * 112)
for label, verdict, detail in results:
    print(f'{label:58} {verdict:6} {detail}')
failed = [r for r in results if r[1] == 'FAIL']
print('-' * 112)
print(f'arms={len(results)} passed={len(results) - len(failed)} failed={len(failed)}')
print('SM1_G8_NEGATIVES: '
      + ('ALL_DETECTED_AND_RESTORED' if not failed else 'DEFECTS_PRESENT'))
sys.exit(1 if failed else 0)
