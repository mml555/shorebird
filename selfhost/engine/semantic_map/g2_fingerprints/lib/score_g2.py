"""Score SM1-G2: ABI and body fingerprints, and the classification they imply.

Expectations come from G0's frozen corpus file and G2's own declared file. This
script does not decide what the answer should be.

A subject that cannot be located, or a comparison whose baseline is missing, is a
FAILURE and never a skip.
"""
import json
import os
import sys

work, g0_exp, g2_exp, out_json = sys.argv[1:5]


def load(path):
    with open(path) as f:
        return json.load(f)


def rows(label):
    p = os.path.join(work, f'{label}.json')
    return load(p) if os.path.isfile(p) else None


def find(doc, subject_key):
    """Locate a row structurally, by library + owner + name.

    Never by a joined selector string: the selector carries the VM's get:/set:
    mangling, which is a VM internal and not a wire contract.
    """
    lib, _, rest = subject_key.partition('::')
    owner, name = (rest.split('.', 1) if '.' in rest else (None, rest))
    hits = [r for r in doc['rows']
            if r['library'] == lib and r['owner'] == owner and r['name'] == name]
    if len(hits) > 1:
        non_field = [r for r in hits if r['kind'] != 'field']
        return (non_field or hits)[0]
    return hits[0] if hits else None


def norm(subject):
    if subject.startswith('corpus.app::'):
        return 'package:corpus/app.dart::' + subject.split('::', 1)[1]
    if subject.startswith('corpus.helper::'):
        return 'package:corpus/helper.dart::' + subject.split('::', 1)[1]
    return subject


def classify(abi_equal, body_equal, owner_abi_equal=True, body_status='supported',
             baseline_body_status='supported'):
    """The three answers G2 exists to give, fail-closed.

    An unsupported body can never become candidate_unchanged: the encoder hit a
    node kind outside its allowlist, so "equal" would mean "equal in the parts I
    looked at".

    A member whose OWNER's ABI moved is not reusable even when its own signature
    is unchanged -- Box.unwrap reads T -> T while Box<T extends Shape> becomes
    Box<T extends Object>.
    """
    # BOTH sides must be encodable. An unsupported BASELINE is just as
    # disqualifying as an unsupported variant: reuse compares two encodings, and
    # if either is incomplete "equal" means "equal in the parts I looked at".
    if body_status != 'supported' or baseline_body_status != 'supported':
        return 'refused:unsupported_body'
    if not abi_equal:
        return 'not_reusable_under_old_abi'
    if not owner_abi_equal:
        return 'not_reusable_under_old_abi'
    return 'candidate_unchanged' if body_equal else 'changed_existing_declaration'


lines, results, fails = [], [], 0


def arm(title):
    lines.append('')
    lines.append(f'--- {title} ---')


def case(cid, subject, want_abi_equal, want_body_equal, want_class,
         baseline='base', note='', want_owner_abi_equal=None, label=None):
    """Compare one declaration between a baseline and a variant."""
    global fails
    b_doc, m_doc = rows(baseline), rows(cid)
    if b_doc is None or m_doc is None:
        lines.append(f'  FAILED  {cid:26} missing rows '
                     f'(baseline={b_doc is not None}, variant={m_doc is not None})')
        fails += 1
        results.append({'id': cid, 'outcome': 'NO_EVIDENCE'})
        return
    key = norm(subject)
    b, m = find(b_doc, key), find(m_doc, key)
    if b is None or m is None:
        lines.append(f'  FAILED  {cid:26} subject {key} not found '
                     f'(baseline={b is not None}, variant={m is not None})')
        fails += 1
        results.append({'id': cid, 'outcome': 'SUBJECT_MISSING'})
        return

    abi_equal = b['abi_fingerprint'] == m['abi_fingerprint']
    body_equal = b['body_fingerprint'] == m['body_fingerprint']
    decl_equal = b['declaration_id'] == m['declaration_id']
    owner_abi_equal = b.get('owner_abi_fingerprint') == m.get('owner_abi_fingerprint')
    status = m.get('body_status', 'supported')
    base_status = b.get('body_status', 'supported')
    got_class = classify(abi_equal, body_equal, owner_abi_equal, status, base_status)

    problems = []
    if want_class == 'refused:unsupported_body':
        want_abi_equal = None
        want_body_equal = None
        want_owner_abi_equal = None
    if want_abi_equal is not None and abi_equal != want_abi_equal:
        problems.append(f'abi {"equal" if abi_equal else "differs"} '
                        f'(want {"equal" if want_abi_equal else "differs"})')
    if want_body_equal is not None and body_equal != want_body_equal:
        problems.append(f'body {"equal" if body_equal else "differs"} '
                        f'(want {"equal" if want_body_equal else "differs"})')
    if want_owner_abi_equal is not None and owner_abi_equal != want_owner_abi_equal:
        problems.append(f'owner_abi {"equal" if owner_abi_equal else "differs"} '
                        f'(want {"equal" if want_owner_abi_equal else "differs"})')
    expects_refusal = want_class == 'refused:unsupported_body'
    if not expects_refusal and (status != 'supported' or base_status != 'supported'):
        problems.append(f'body_status variant={status} baseline={base_status}')
    if expects_refusal and status == 'supported' and base_status == 'supported':
        problems.append('expected an unsupported body on one side, both are supported — '
                        'the refusal arm would prove nothing')
    if want_class and got_class != want_class:
        problems.append(f'class {got_class} (want {want_class})')
    # G1's separation must hold: identity is not a function of ABI or body.
    if not decl_equal:
        problems.append('declaration_id moved, which G2 never expects for a '
                        'same-declaration comparison')

    if problems:
        fails += 1
        lines.append(f'  FAILED  {(label or cid):26} ' + '; '.join(problems))
    else:
        lines.append(f'  ok      {(label or cid):26} abi={"=" if abi_equal else "≠"} '
                     f'body={"=" if body_equal else "≠"} '
                     f'owner={"=" if owner_abi_equal else "≠"}  -> {got_class}')
    results.append({
        'id': label or cid, 'variant': cid, 'subject': key, 'baseline': baseline,
        'abi_equal': abi_equal, 'body_equal': body_equal,
        'owner_abi_equal': owner_abi_equal, 'body_status': status,
        'baseline_body_status': base_status,
        'declaration_id_stable': decl_equal,
        'classification': got_class, 'expected_classification': want_class,
        'outcome': 'OK' if not problems else 'MISMATCH', 'note': note,
        'incumbent_printed_equal': b['incumbent_printed_sha256'] == m['incumbent_printed_sha256'],
    })


base = rows('base')
if base is None:
    print('FAILED: no base map rows')
    sys.exit(1)

arm('same ABI + different body  ->  changed_existing_declaration')
for m in load(g0_exp)['mutants']:
    if m['id'] != 'body_only':
        continue
    case(m['id'], m['subject'], True, False, 'changed_existing_declaration',
         note=m.get('note', ''))

arm('different ABI  ->  not_reusable_under_old_abi (one dimension each)')
for m in load(g0_exp)['mutants']:
    if not m['id'].startswith('abi_'):
        continue
    case(m['id'], m['subject'], False, m['body_equal'],
         'not_reusable_under_old_abi', note=m.get('note', ''))

arm('unrelated-program mutation  ->  both fingerprints identical')
for m in load(g0_exp)['mutants']:
    if m['id'] not in ('unrelated_added', 'unrelated_removed', 'unrelated_renamed',
                       'reorder', 'private_other_domain', 'field_added'):
        continue
    case(m['id'], m['subject'], True, True, 'candidate_unchanged',
         note=m.get('note', ''))

arm('canonicalization exclusions, each justified by its own arm')
for m in load(g2_exp)['cases']:
    case(m['id'], m['subject'], m['abi_equal'], m['body_equal'],
         m['expected_classification'], baseline=m.get('baseline', 'base'),
         note=m.get('note', ''), want_owner_abi_equal=m.get('owner_abi_equal'),
         label=m.get('case_id'))

# INDEPENDENCE. The two fingerprints must not be functions of each other. The
# ABI arms are the proof: four of them leave the body text identical while the
# signature moves, so a body-derived ABI would report abi_equal there.
arm('independence: neither fingerprint is derived from the other')
abi_only = [r for r in results
            if r.get('id', '').startswith('abi_') and r.get('body_equal') is True]
body_only = [r for r in results if r.get('id') == 'body_only']
extra = {}
ok_abi = all(r['abi_equal'] is False for r in abi_only) and len(abi_only) >= 2
ok_body = all(r['body_equal'] is False and r['abi_equal'] is True for r in body_only)
extra['independence'] = {
    'signature_moved_body_identical': [r['id'] for r in abi_only],
    'body_moved_signature_identical': [r['id'] for r in body_only],
    'abi_not_body_derived': ok_abi, 'body_not_abi_derived': ok_body}
if ok_abi:
    lines.append(f'  ok      {len(abi_only)} case(s) move the ABI with the body '
                 f'identical ({", ".join(r["id"] for r in abi_only)}) — a '
                 f'body-derived ABI would have reported equal')
else:
    lines.append('  FAILED  no case moves the ABI while the body stays identical, so '
                 'ABI independence is not demonstrated')
    fails += 1
if ok_body:
    lines.append('  ok      body_only moves the body with the ABI identical — an '
                 'ABI-derived body would have reported equal')
else:
    lines.append('  FAILED  body independence is not demonstrated')
    fails += 1

# NO ROW MAY CARRY AN UNSUPPORTED BODY SILENTLY.
arm('body encoding is complete for every row, or the row says it is not')
bad_status = [f"{r['owner'] or ''}.{r['name']} -> {r['body_status']}"
              for r in base['rows'] if r.get('body_status') != 'supported']
extra['unsupported_bodies'] = bad_status
if bad_status:
    lines.append(f'  FINDING {len(bad_status)} row(s) refuse their body encoding:')
    for b in bad_status[:8]:
        lines.append(f'            {b}')
    lines.append('          These are REFUSALS, not equalities: an unsupported body can '
                 'never classify as candidate_unchanged.')
else:
    lines.append(f'  ok      all {base["count"]} rows encoded within the allowlist')

# THE REFUSAL BOUNDARY MUST BE IN THE MAP, not inferred by a caller.
arm('the map STATES the P2 refusal boundary')
shapes = {}
for r in base['rows']:
    shapes[r['abi_shape']] = shapes.get(r['abi_shape'], 0) + 1
named_case = rows('abi_positional_to_named')
extra['abi_shape_counts'] = shapes
if named_case is None:
    lines.append('  FAILED  abi_positional_to_named rows unavailable')
    fails += 1
else:
    area = find(named_case, 'package:corpus/app.dart::Shape.area')
    got = area['abi_shape'] if area else '<missing>'
    extra['named_case_shape'] = got
    if got == 'refused:named':
        lines.append(f'  ok      a named parameter is stated as {got!r} in the row itself')
    else:
        lines.append(f'  FAILED  a named parameter should be stated refused; row says {got!r}')
        fails += 1
    generic = find(base, 'package:corpus/app.dart::Box')
    gshape = generic['abi_shape'] if generic else '<missing>'
    extra['generic_class_shape'] = gshape
    if gshape == 'refused:type_parameters':
        lines.append(f'  ok      a generic class is stated as {gshape!r}')
    else:
        lines.append(f'  FAILED  a generic class should be stated refused; row says {gshape!r}')
        fails += 1
lines.append(f'  base abi_shape census: ' +
             ', '.join(f'{v} {k}' for k, v in sorted(shapes.items())))

# THE INCUMBENT ORACLE, cross-checked rather than trusted or discarded.
arm('cross-check against the incumbent printed-Kernel oracle')
agree, disagree = [], []
for r in results:
    if r.get('outcome') != 'OK' or 'incumbent_printed_equal' not in r:
        continue
    changed_by_us = not (r['abi_equal'] and r['body_equal'])
    changed_by_incumbent = not r['incumbent_printed_equal']
    (agree if changed_by_us == changed_by_incumbent else disagree).append(r['id'])
extra['incumbent_crosscheck'] = {'agree': agree, 'disagree': disagree}
lines.append(f'  agree on {len(agree)} case(s); disagree on {len(disagree)}')
for cid in disagree:
    r = next(x for x in results if x['id'] == cid)
    lines.append(f'    FINDING {cid}: ours abi={r["abi_equal"]} body={r["body_equal"]}, '
                 f'incumbent printed_equal={r["incumbent_printed_equal"]}')
if disagree:
    lines.append('  A disagreement is not automatically a defect: the incumbent prints a '
                 'whole Procedure, so it also moves when a signature moves, where our two '
                 'fingerprints separate that. Each is recorded for review.')

print('\n'.join(lines))
print()
print(f'SUMMARY checks_failed={fails}')
print('G2 FINGERPRINTS VERIFIED' if fails == 0 else 'G2 FINGERPRINTS FAILED')

json.dump({
    'schema': 'semantic-map-1/g2-fingerprints/1', 'gate': 'SM1-G2', 'issue': 51,
    'checks_failed': fails,
    'base_row_count': base['count'],
    'contract': base['contract'],
    'results': results,
    'arms': extra,
}, open(out_json, 'w'), indent=2)
sys.exit(1 if fails else 0)
