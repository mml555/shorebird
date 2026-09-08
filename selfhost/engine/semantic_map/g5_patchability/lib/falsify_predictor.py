#!/usr/bin/env python3
"""One adversarial arm per safety-bearing predictor refusal, plus a control.

Each arm drives the REAL predictor with real input schemas, asserts the exact
stable refusal code it set out to provoke, and asserts predicted_patchable is
false. Then the same arm runs against a predictor whose gate for THAT code has
been removed, and must fail -- so an arm proves the gate it names rather than
"something refused".

A refusal code in the predictor's vocabulary with no arm here FAILS the run. A
declared gate nobody exercises is indistinguishable from a gate that cannot
fire, which is how DEVIRTUALIZED_CALL_SITE sat unreachable in the vocabulary.

usage: falsify_predictor.py <dart> <workdir> [--no-controls]
"""
import copy
import json
import os
import re
import shutil
import subprocess
import sys

DART, W = sys.argv[1], sys.argv[2]
NO_CONTROLS = '--no-controls' in sys.argv
HERE = os.path.dirname(os.path.abspath(__file__))
PREDICTOR = os.environ.get('SM1_PREDICTOR', f'{HERE}/predict_patchable.dart')
WEAKEN = f'{HERE}/weaken_predictor.py'
LIB = 'package:dynamic_modules/probe.dart'
AOT = 'a' * 64
results = []


def g2row(name='f', kind='method', static=True, owner=None, **over):
    r = {'library': LIB, 'owner': owner, 'name': name, 'kind': kind,
         'ownerKind': 'class' if owner else None,
         'loweredName': None, 'vmName': name,
         'declaration_id': f'id_{owner or ""}_{name}_{kind}',
         'abi_fingerprint': 'f', 'abi_shape': 'supported',
         'abi_components': [], 'abi_source': 'pre_aot_kernel',
         'body_fingerprint': 'b', 'body_status': 'supported'}
    if static is not ...:
        r['static'] = static
    r.update(over)
    return r


def kref(r):
    return f"{r['library']}#{r['owner'] or ''}#{r['kind']}#{r['name']}"


def base(**over):
    """A complete, maximally-proven input set. Arms spoil exactly one thing."""
    row = over.pop('g2row', None) or g2row()
    k = kref(row)
    inp = {
        'g2': {'rows': [row]},
        'g3': {'rows': []},
        'g4': {'rows': [{**{f: row[f] for f in ('library', 'owner', 'kind', 'name')},
                         'retained_in_release': True, 'required_classes': []}]},
        'refs': {'rows': [{**{f: row[f] for f in ('library', 'owner', 'kind', 'name')},
                           'traversal_status': 'supported',
                           'references_private_type': False,
                           'private_refs': []}]},
        'release': {'release_patch_capability': 'PROVEN',
                    'release_patch_capability_evidence': 'test',
                    'release_aot_sha256': AOT, 'rows': []},
        'inlining': {'note_validated': True, 'note_complete_projection': True,
                     'diagnostics': {'aot_sha256': AOT},
                     'states': [{'declaration_id': row['declaration_id'],
                                 'state': 'NOT_INLINED'}]},
        'generated': None,
        'key': k,
    }
    inp.update(over)
    return inp


def run_arm(label, code, inp, predictor=None):
    d = os.path.join(W, 'pred_full')
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    for n in ('g2', 'g3', 'g4', 'refs', 'release', 'inlining'):
        json.dump(inp[n], open(f'{d}/{n}.json', 'w'))
    cmd = [DART, predictor or PREDICTOR,
           '--g2', f'{d}/g2.json', '--g3', f'{d}/g3.json',
           '--g4', f'{d}/g4.json', '--refs', f'{d}/refs.json',
           '--release-contract', f'{d}/release.json',
           '--out', f'{d}/pred.json']
    if inp.get('inlining') is not None:
        cmd += ['--inlining-state', f'{d}/inlining.json']
    if inp.get('generated'):
        open(f'{d}/gen.txt', 'w').write('\n'.join(inp['generated']))
        cmd += ['--generated', f'{d}/gen.txt']
    p = subprocess.run(cmd, capture_output=True, text=True)
    if not os.path.exists(f'{d}/pred.json'):
        tail = (p.stderr.strip().splitlines() or ['<no stderr>'])[-1][:100]
        return None, f'predictor produced nothing: {tail}'
    rows = json.load(open(f'{d}/pred.json'))['rows']
    target = [x for x in rows if x['name'] == inp['g2']['rows'][0]['name']]
    if not target:
        return None, 'the target declaration is absent from the predictions'
    got = set(target[0]['refusal_reasons'])
    bad = []
    if code not in got:
        bad.append(f'missing {code}')
    if target[0].get('predicted_patchable') is not False:
        bad.append('predicted_patchable is not false')
    return got, '; '.join(bad)


ARMS = []


def arm(label, code, inp):
    ARMS.append((label, code, inp))


# ---- declaration-level ABI / body ---------------------------------------
arm('abi shape unsupported', 'ABI_SHAPE_UNSUPPORTED',
    base(g2row=g2row(abi_shape='unknown')))
_owner = g2row(name='m', owner='C')
arm('owner class ABI unsupported', 'OWNER_ABI_SHAPE_UNSUPPORTED',
    base(g2row=_owner,
         g2={'rows': [_owner, g2row(name='C', kind='class',
                                    abi_shape='unsupported', static=...)]}))
arm('body encoding refused', 'BODY_ENCODING_REFUSED',
    base(g2row=g2row(body_status='unknown')))
arm('body references unproven (no refs row)', 'BODY_REFERENCES_UNPROVEN',
    base(refs={'rows': []}))

# ---- privacy ------------------------------------------------------------
_r = g2row()
_pf = {f: _r[f] for f in ('library', 'owner', 'kind', 'name')}
arm('body references a private type', 'PRIVATE_TYPE_REFERENCE',
    base(refs={'rows': [{**_pf, 'traversal_status': 'supported',
                         'references_private_type': True,
                         'private_refs': []}]}))
arm('private reference unresolved', 'PRIVATE_REFERENCE_UNRESOLVED',
    base(refs={'rows': [{**_pf, 'traversal_status': 'supported',
                         'references_private_type': False,
                         'private_refs': [{'mode': 'read', 'resolved': False,
                                           'target_key': 'x'}]}]}))
_priv = {'library': LIB, 'owner': None, 'kind': 'method', 'name': '_t'}
_tk = f"{LIB}##method#_t"
arm('private reference not granted', 'PRIVATE_REFERENCE_UNGRANTED',
    base(refs={'rows': [{**_pf, 'traversal_status': 'supported',
                         'references_private_type': False,
                         'private_refs': [{'mode': 'read', 'resolved': True,
                                           'target_key': _tk}]}]},
         g3={'rows': [{**_priv, 'retained_in_release': True,
                       'capability_key_read': None}]}))
arm('private write whose key does not identify the mode', 'PRIVATE_WRITE',
    base(refs={'rows': [{**_pf, 'traversal_status': 'supported',
                         'references_private_type': False,
                         'private_refs': [{'mode': 'write', 'resolved': True,
                                           'target_key': _tk}]}]},
         g3={'rows': [{**_priv, 'retained_in_release': True,
                       'capability_key_write': 'k',
                       'capability_key_identifies_mode': False}]}))
arm('private target not retained in the release', 'NOT_RETAINED',
    base(refs={'rows': [{**_pf, 'traversal_status': 'supported',
                         'references_private_type': False,
                         'private_refs': [{'mode': 'read', 'resolved': True,
                                           'target_key': _tk}]}]},
         g3={'rows': [{**_priv, 'retained_in_release': False,
                       'capability_key_read': 'k'}]}))

# ---- retention ----------------------------------------------------------
arm('retention unproven (no g4 row)', 'RETENTION_UNPROVEN',
    base(g4={'rows': []}))
arm('required can-be-overridden absent from the release',
    'MISSING_CAN_BE_OVERRIDDEN',
    base(g4={'rows': [{**_pf, 'retained_in_release': True,
                       'required_classes': ['can-be-overridden']}]}))
arm('release identity ambiguous', 'RELEASE_IDENTITY_AMBIGUOUS',
    base(g4={'rows': [{**_pf, 'retained_in_release': True,
                       'required_classes': ['callable']}]},
         release={'release_patch_capability': 'PROVEN',
                  'release_aot_sha256': AOT,
                  'rows': [{'key': f"{LIB}##method#f", 'ambiguous': True,
                            'contract_entries': []}]}))

# ---- policy / release ---------------------------------------------------
arm('generated code', 'GENERATED_CODE', base(generated=[f"{LIB}##method#f"]))
arm('release patch capability unproven', 'RELEASE_PATCHABILITY_UNPROVEN',
    base(release={'release_patch_capability': 'UNPROVEN',
                  'release_aot_sha256': AOT, 'rows': []}))
arm('release built without patchable static calls',
    'RELEASE_NOT_PATCHABLE_BUILD',
    base(release={'release_patch_capability': 'NOT_PATCHABLE',
                  'release_aot_sha256': AOT, 'rows': []}))

# ---- scope predicates ---------------------------------------------------
arm('non-static instance dispatch', 'NON_STATIC_DISPATCH_UNPROVEN',
    base(g2row=g2row(static=False, owner='C')))
arm('static metadata unusable', 'STATIC_METADATA_UNUSABLE',
    base(g2row=g2row(static=...)))
arm('front-end materialization unproven', 'FRONTEND_MATERIALIZATION_UNPROVEN',
    base())
arm('call-site shape unproven', 'CALL_SITE_SHAPE_UNPROVEN', base())

# ---- Route 2 ------------------------------------------------------------
_id = g2row()['declaration_id']
arm('route 2 says the body was inlined', 'INLINED_BODY',
    base(inlining={'note_validated': True, 'note_complete_projection': True,
                   'diagnostics': {'aot_sha256': AOT},
                   'states': [{'declaration_id': _id, 'state': 'INLINED'}]}))
arm('route 2 could not decide', 'INLINING_STATE_UNKNOWN',
    base(inlining={'note_validated': True, 'note_complete_projection': True,
                   'diagnostics': {'aot_sha256': AOT},
                   'states': [{'declaration_id': _id, 'state': 'UNKNOWN'}]}))
arm('route 2 evidence absent entirely', 'INLINING_EVIDENCE_MISSING',
    base(inlining=None))
arm('route 2 has no row for this declaration', 'INLINING_EVIDENCE_MISSING',
    base(inlining={'note_validated': True, 'note_complete_projection': True,
                   'diagnostics': {'aot_sha256': AOT}, 'states': []}))
arm('route 2 note did not validate', 'INLINING_EVIDENCE_UNVALIDATED',
    base(inlining={'note_validated': False, 'note_complete_projection': False,
                   'diagnostics': {'aot_sha256': AOT},
                   'states': [{'declaration_id': _id, 'state': 'NOT_INLINED'}]}))
arm('route 2 evidence describes a different release',
    'INLINING_EVIDENCE_RELEASE_MISMATCH',
    base(inlining={'note_validated': True, 'note_complete_projection': True,
                   'diagnostics': {'aot_sha256': 'b' * 64},
                   'states': [{'declaration_id': _id, 'state': 'NOT_INLINED'}]}))


# ---- run ----------------------------------------------------------------
for label, code, inp in ARMS:
    got, bad = run_arm(label, code, inp)
    if bad:
        results.append((label, code, 'FAIL', bad))
        continue
    if NO_CONTROLS:
        results.append((label, code, 'pass', 'no control requested'))
        continue
    # The control removes the gate for THIS code and requires the arm to fail.
    weak = os.path.join(W, f'weak_{code}.dart')
    if os.path.exists(weak):
        os.remove(weak)
    wp = subprocess.run([sys.executable, WEAKEN, PREDICTOR, weak,
                         f'reason:{code}'], capture_output=True, text=True)
    if not os.path.exists(weak):
        results.append((label, code, 'FAIL',
                        f'could not build the control: '
                        f'{(wp.stdout + wp.stderr).strip()[:80]}'))
        continue
    _, cbad = run_arm(label, code, inp, predictor=weak)
    if not cbad:
        results.append((label, code, 'FAIL',
                        'the control still passed: the arm does not depend on '
                        'the gate it names'))
    else:
        results.append((label, code, 'pass', f'control flipped ({cbad[:44]})'))

# Every vocabulary reason must be armed.
src = open(PREDICTOR).read()
vb = src[src.index('const refusalReasons'):src.index('];', src.index('const refusalReasons'))]
vocab = set(re.findall(r"'([A-Z_]+)'", vb))
armed = {c for _, c, _ in ARMS}
unarmed = sorted(vocab - armed)

print(f'{"arm":52} {"code":36} {"result":6} detail')
print('-' * 132)
for label, code, verdict, detail in results:
    print(f'{label:52} {code:36} {verdict:6} {detail}')
failed = [r for r in results if r[2] == 'FAIL']
print('-' * 132)
for c in unarmed:
    print(f'{"<no arm>":52} {c:36} FAIL   in the vocabulary, never exercised')
print(f'arms={len(results)} passed={len(results) - len(failed)} '
      f'failed={len(failed)} unarmed={len(unarmed)}')
print('SM1_G5_PREDICTOR_FALSIFICATION: '
      + ('EVERY_REASON_ARMED_AND_SENSITIVE'
         if not failed and not unarmed else 'DEFECTS_PRESENT'))
sys.exit(1 if (failed or unarmed) else 0)
