#!/usr/bin/env python3
"""Prove the instance-dispatch predicate is fail-closed.

The predicate under test, in predict_patchable.dart:

    replaceable callable AND static is not exactly true  =>  refuse

with "cannot tell" kept as its OWN refusal rather than folded into "not
static", because a missing input must never read as a measurement.

Each arm drives the REAL predictor with real input schemas and asserts the
exact reason set it must or must not produce. A positive control then runs the
same arms against a copy of the predictor with the predicate deleted; every
arm that depends on it must flip.

usage: falsify_dispatch_predicate.py <dart> <workdir>
"""
import json
import os
import shutil
import subprocess
import sys

DART, W = sys.argv[1], sys.argv[2]
HERE = os.path.dirname(os.path.abspath(__file__))
PREDICTOR = os.environ.get('SM1_PREDICTOR', f'{HERE}/predict_patchable.dart')
LIB = 'package:dynamic_modules/callsite_target.dart'
results = []


def row(name, kind, static, owner=None):
    """A G1 row shaped like the real ones, varying only what an arm varies."""
    r = {
        'library': LIB, 'owner': owner, 'name': name, 'kind': kind,
        'ownerKind': 'class' if owner else None,
        'loweredName': None, 'vmName': name,
        'declaration_id': f'id_{name}_{kind}',
        'abi_fingerprint': 'f', 'abi_shape': 'supported',
        'abi_components': [], 'abi_source': 'pre_aot_kernel',
        'body_fingerprint': 'b', 'body_status': 'supported',
    }
    if static is not ...:                    # ... means "omit the key entirely"
        r['static'] = static
    return r


ARMS = [
    # (label, row, must contain, must NOT contain)
    ('instance method (the Base.work shape)',
     row('work', 'method', False, owner='Base'),
     {'NON_STATIC_DISPATCH_UNPROVEN'}, {'STATIC_METADATA_UNUSABLE'}),
    ('instance getter',
     row('get:tag', 'getter', False, owner='Base'),
     {'NON_STATIC_DISPATCH_UNPROVEN'}, {'STATIC_METADATA_UNUSABLE'}),
    ('instance setter',
     row('set:tag', 'setter', False, owner='Base'),
     {'NON_STATIC_DISPATCH_UNPROVEN'}, {'STATIC_METADATA_UNUSABLE'}),
    ('instance operator',
     row('+', 'operator', False, owner='Base'),
     {'NON_STATIC_DISPATCH_UNPROVEN'}, {'STATIC_METADATA_UNUSABLE'}),
    ('static metadata absent',
     row('gone', 'method', ...),
     {'STATIC_METADATA_UNUSABLE'}, {'NON_STATIC_DISPATCH_UNPROVEN'}),
    ('static metadata null',
     row('nulled', 'method', None),
     {'STATIC_METADATA_UNUSABLE'}, {'NON_STATIC_DISPATCH_UNPROVEN'}),
    ('static metadata is the STRING "true", not a bool',
     row('stringy', 'method', 'true'),
     {'STATIC_METADATA_UNUSABLE'}, {'NON_STATIC_DISPATCH_UNPROVEN'}),
    ('static metadata is the integer 1',
     row('inty', 'method', 1),
     {'STATIC_METADATA_UNUSABLE'}, {'NON_STATIC_DISPATCH_UNPROVEN'}),
    # static == true avoids THIS refusal and nothing more. The arm asserts both
    # halves: the dispatch reasons are gone, and the call-site fact is still
    # refused -- so nothing here can be read as "static is safe".
    ('top-level static function',
     row('alpha', 'method', True),
     {'CALL_SITE_SHAPE_UNPROVEN'},
     {'NON_STATIC_DISPATCH_UNPROVEN', 'STATIC_METADATA_UNUSABLE'}),
    # A kind the predictor does not consider replaceable must not acquire a
    # dispatch reason: the predicate is scoped to replaceable callables.
    ('a field, which is not a replaceable callable',
     row('tag', 'field', False, owner='Base'),
     {'ABI_SHAPE_UNSUPPORTED'},
     {'NON_STATIC_DISPATCH_UNPROVEN', 'STATIC_METADATA_UNUSABLE'}),
]


def run_arm(label, g1row, must, must_not):
    d = os.path.join(W, 'pred_arm')
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    json.dump({'rows': [g1row]}, open(f'{d}/g2.json', 'w'))
    for n in ('g3', 'g4', 'refs'):
        json.dump({'rows': []}, open(f'{d}/{n}.json', 'w'))
    # The predictor REFUSES to run without a release contract -- G4's
    # carried-forward rule that retention must be proven in the exact release.
    # These arms are about the dispatch predicate, so the contract is present
    # but empty and its capability unproven; that adds release-level refusals
    # to every arm, which is why arms assert specific reasons rather than an
    # exact set.
    json.dump({'rows': [], 'release_patch_capability': 'UNPROVEN'},
              open(f'{d}/release.json', 'w'))
    out = f'{d}/pred.json'
    p = subprocess.run(
        [DART, PREDICTOR, '--g2', f'{d}/g2.json', '--g3', f'{d}/g3.json',
         '--g4', f'{d}/g4.json', '--refs', f'{d}/refs.json',
         '--release-contract', f'{d}/release.json', '--out', out],
        capture_output=True, text=True)
    if not os.path.exists(out):
        tail = (p.stderr.strip().splitlines() or ['<no stderr>'])[-1][:110]
        results.append((label, 'FAIL', f'predictor produced nothing: {tail}'))
        return
    rows = json.load(open(out))['rows']
    if len(rows) != 1:
        results.append((label, 'FAIL', f'{len(rows)} prediction rows, wanted 1'))
        return
    got = set(rows[0]['refusal_reasons'])
    bad = []
    missing = must - got
    present = must_not & got
    if missing:
        bad.append(f'missing {sorted(missing)}')
    if present:
        bad.append(f'must not contain {sorted(present)}')
    # No arm may end up predicted patchable.
    if rows[0].get('predicted_patchable') is True:
        bad.append('predicted patchable')
    results.append((label, 'FAIL' if bad else 'pass',
                    '; '.join(bad) if bad else ', '.join(sorted(got))[:96]))


for a in ARMS:
    run_arm(*a)

print(f'{"arm":48} {"result":6} reasons / defect')
print('-' * 108)
for label, verdict, detail in results:
    print(f'{label:48} {verdict:6} {detail}')
failed = [r for r in results if r[1] == 'FAIL']
print('-' * 108)
print(f'arms={len(results)} passed={len(results) - len(failed)} '
      f'failed={len(failed)}')
# Machine-readable survivor list, so a caller can require EXACTLY which arms
# survive a control rather than only how many.
print('SURVIVORS: ' + ' | '.join(l for l, v, _ in results if v == 'pass'))
print('SM1_G5_DISPATCH_PREDICATE: '
      + ('FAIL_CLOSED' if not failed else 'DEFECTS_PRESENT'))
sys.exit(1 if failed else 0)
