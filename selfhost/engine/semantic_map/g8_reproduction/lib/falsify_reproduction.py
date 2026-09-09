#!/usr/bin/env python3
"""G8's negatives, DRIVEN BY THE SINGLE INVENTORY.

Every mutation, its expected structured failure and its restoration
requirement come from inventory.json. This file carries no target list of its
own: previously it hard-coded which artifacts to mutate, so the inventory was
not the single source of truth it claimed to be, and the reported arm count
described neither.

It emits outcomes as STABLE IDS -- tested_ids and caught_ids -- which
check_inventory.py then asserts equal to the declared set. That is what makes
"inventory == tested == caught" a literal equality rather than an intersection
of whatever the transcripts happened to contain.

COUNTS ARE REPORTED HONESTLY: mutations, restorations and classifier controls
are separate totals, because 11 mutations plus 11 restorations plus 3 controls
is not "26 arms".

usage: falsify_reproduction.py <semantic-map-dir> <inventory.json> <workdir> [outcomes.json]
"""
import hashlib
import json
import pathlib
import subprocess
import sys

SM, INV, W = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
OUTCOMES = sys.argv[4] if len(sys.argv) > 4 else None
HERE = pathlib.Path(__file__).resolve().parent
CHECK = HERE / 'check_inventory.py'
sys.path.insert(0, str(SM / 'g7_cost' / 'lib'))
from classify_order import classify           # noqa: E402

inv = json.load(open(INV))
W.mkdir(parents=True, exist_ok=True)
mutations, restorations, controls = [], [], []


def run_check():
    p = subprocess.run([sys.executable, str(CHECK), str(SM), INV,
                        str(W / 'chk.json'), '--no-outcomes'],
                       capture_output=True, text=True)
    try:
        return p.returncode, json.load(open(W / 'chk.json'))
    except Exception:                                     # noqa: BLE001
        return p.returncode, None


def apply_mutation(entry, target, original):
    kind = entry['mutation']
    if kind == 'delete':
        target.unlink()
    elif kind == 'empty':
        target.write_bytes(b'')
    elif kind == 'sub':
        n = entry.get('count', -1)
        target.write_bytes(original.replace(
            entry['from'].encode(), entry['to'].encode(),
            *( [n] if n and n > 0 else [] )))
    elif kind == 'drop_lines_containing':
        tok = entry['token'].encode()
        target.write_bytes(b'\n'.join(
            l for l in original.split(b'\n') if tok not in l))
    else:
        raise SystemExit(f"unknown mutation {kind!r} for {entry['id']}")


for entry in inv['falsifiable']['entries']:
    eid = entry['id']
    target = SM / entry['target']
    if not target.exists():
        mutations.append((eid, 'FAIL', f"target absent: {entry['target']}"))
        continue
    original = target.read_bytes()
    before = hashlib.sha256(original).hexdigest()
    caught = False
    try:
        apply_mutation(entry, target, original)
        rc, out = run_check()
        if out is None:
            mutations.append((eid, 'FAIL', 'the checker produced no output'))
        else:
            codes = [f['code'] for f in out['findings']]
            bad = []
            if rc == 0:
                bad.append('the checker accepted the mutated bank')
            if entry['expect_code'] not in codes:
                bad.append(f"missing {entry['expect_code']}, "
                           f"got {sorted(set(codes))[:3]}")
            caught = not bad
            mutations.append((eid, 'FAIL' if bad else 'pass',
                              '; '.join(bad) if bad else entry['expect_code']))
    finally:
        target.write_bytes(original)
        after = hashlib.sha256(target.read_bytes()).hexdigest()
        restorations.append((eid, 'pass' if after == before else 'FAIL',
                             'byte-for-byte' if after == before
                             else f'DIGEST CHANGED {before[:12]}->{after[:12]}'))
    entry['_caught'] = caught

for c in inv['classifier_controls']['entries']:
    v = classify(c['a'], c['z'])
    got = v.get('order_dependent')
    want = c['expect_order_dependent']
    ok = got is want
    controls.append((c['id'], 'pass' if ok else 'FAIL',
                     f"{c['means']}: order_dependent={got}" if ok
                     else f"got {got}, expected {want}"))
    c['_caught'] = ok

rc_final, out_final = run_check()
intact = ('pass' if rc_final == 0 else 'FAIL',
          out_final['verdict'] if out_final else 'no output')

tested_ids = sorted([m[0] for m in mutations] + [c[0] for c in controls])
caught_ids = sorted(
    [e['id'] for e in inv['falsifiable']['entries'] if e.get('_caught')]
    + [c['id'] for c in inv['classifier_controls']['entries'] if c.get('_caught')])

if OUTCOMES:
    json.dump({'schema': 'semantic-map-1/g8-outcomes/1',
               'tested_ids': tested_ids, 'caught_ids': caught_ids,
               'mutations': len(mutations), 'restorations': len(restorations),
               'classifier_controls': len(controls),
               'bank_intact_after': rc_final == 0},
              open(OUTCOMES, 'w'), indent=2)

def show(title, rows):
    print(f'  {title}')
    for i, v, d in rows:
        print(f'    {i:38} {v:6} {d[:56]}')

show(f'MUTATIONS ({len(mutations)}) -- each from the inventory', mutations)
show(f'RESTORATIONS ({len(restorations)}) -- byte-for-byte, verified', restorations)
show(f'CLASSIFIER CONTROLS ({len(controls)})', controls)
print(f'  BANK INTACT AFTER ALL MUTATIONS: {intact[0]} ({intact[1]})')
failed = [r for r in mutations + restorations + controls if r[1] == 'FAIL']
print(f'  mutations={len(mutations)} restorations={len(restorations)} '
      f'classifier_controls={len(controls)} failed={len(failed)}')
print('SM1_G8_NEGATIVES: '
      + ('ALL_DETECTED_AND_RESTORED'
         if not failed and intact[0] == 'pass' else 'DEFECTS_PRESENT'))
sys.exit(1 if failed or intact[0] != 'pass' else 0)
