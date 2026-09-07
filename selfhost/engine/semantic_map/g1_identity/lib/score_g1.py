"""Score SM1-G1 against the frozen expectations.

The expectations come from files frozen in G0 and declared in G1; this script
does not decide what the answer should be. A subject that cannot be located in a
variant is a FAILURE, never a skip -- "the declaration is gone" and "the harness
could not find it" are different states and the second must not pass quietly.
"""
import json
import os
import sys

work, g0_exp, ext_exp, out_json = sys.argv[1:5]


def load(path):
    with open(path) as f:
        return json.load(f)


def ids(label):
    p = os.path.join(work, f'{label}.json')
    if not os.path.isfile(p):
        return None
    return load(p)


def find(doc, subject_key):
    """Locate a declaration STRUCTURALLY, by library + owner + name.

    Not by matching a joined selector string. The selector carries the VM's
    get:/set: mangling, so `Shape.perimeter` would never match `Shape.get:
    perimeter`, and a bare `Box` would never match a member at all. This is the
    same defect gen_target_manifest.dart records about its own harness: it used
    "Class.name", split on the first dot, and forced callers to know a VM
    internal.
    """
    lib, _, rest = subject_key.partition('::')
    if '.' in rest:
        owner, name = rest.split('.', 1)
    else:
        owner, name = None, rest
    hits = [r for r in doc['declarations']
            if r['library'] == lib and r['owner'] == owner and r['name'] == name]
    if len(hits) > 1:
        # Several kinds can share a name (a field and its implicit accessors).
        # Prefer a non-field so the subject is the declaration the mutant edits.
        non_field = [r for r in hits if r['kind'] != 'field']
        return (non_field or hits)[0]
    return hits[0] if hits else None


def norm(subject):
    """G0 expectations use 'corpus.app::name'; the map keys on the import URI."""
    if subject.startswith('corpus.app::'):
        return 'package:corpus/app.dart::' + subject.split('::', 1)[1]
    if subject.startswith('corpus.helper::'):
        return 'package:corpus/helper.dart::' + subject.split('::', 1)[1]
    return subject


base = ids('base')
if base is None:
    print('FAILED: no base declaration ids')
    sys.exit(1)

rows = []
fails = 0
lines = []


def check(mutant_id, subject, want_stable, source, note=''):
    global fails
    doc = ids(mutant_id)
    if doc is None:
        lines.append(f'  FAILED  {mutant_id:24} could not build/collect ids')
        fails += 1
        rows.append({'id': mutant_id, 'outcome': 'NO_EVIDENCE'})
        return
    key = norm(subject)
    b = find(base, key)
    m = find(doc, key)
    if b is None:
        lines.append(f'  FAILED  {mutant_id:24} subject {key} not found in BASE')
        fails += 1
        rows.append({'id': mutant_id, 'outcome': 'SUBJECT_MISSING_IN_BASE'})
        return
    if m is None:
        # For a MUST-MOVE case the subject legitimately no longer exists under
        # that key (renamed, re-owned, moved). That satisfies "the id moved",
        # and is reported as its own state rather than as an absence.
        if not want_stable:
            lines.append(f'  ok      {mutant_id:24} subject no longer exists under '
                         f'its old identity (moved, as required)')
            rows.append({'id': mutant_id, 'outcome': 'MOVED_ABSENT',
                         'base_declaration_id': b['declaration_id']})
            return
        lines.append(f'  FAILED  {mutant_id:24} subject {key} vanished but was '
                     f'expected stable')
        fails += 1
        rows.append({'id': mutant_id, 'outcome': 'SUBJECT_VANISHED'})
        return

    same = b['declaration_id'] == m['declaration_id']
    same_index = b['index_id'] == m['index_id']
    ok = (same == want_stable)
    if not ok:
        fails += 1
    lines.append(
        f'  {"ok     " if ok else "FAILED "} {mutant_id:24} '
        f'declaration_id {"stable" if same else "moved"} '
        f'(want {"stable" if want_stable else "moved"})'
        f'   index_id {"stable" if same_index else "moved"}')
    rows.append({
        'id': mutant_id, 'subject': key, 'source': source,
        'want_declaration_id_stable': want_stable,
        'declaration_id_stable': same,
        'index_id_stable': same_index,
        'outcome': 'OK' if ok else 'MISMATCH',
        'note': note,
    })


lines.append('--- G0 frozen corpus: the untouched subject must keep its identity ---')
for m in load(g0_exp)['mutants']:
    check(m['id'], m['subject'], m['declaration_id_stable'], 'g0_freeze/corpus/EXPECTATIONS.json',
          m.get('note', ''))

lines.append('')
lines.append("--- G1 corpus extension: sufficiency, and the MUST-MOVE cases ---")
for m in load(ext_exp)['mutants']:
    check(m['id'], m['subject'], m['declaration_id_stable'],
          'g1_identity/EXPECTATIONS_EXT.json', m.get('note', ''))

# THE POSITIVE CONTROL ON THE HARNESS. An order-derived identity must be caught
# by the reorder case; if it is not, nothing above is evidence.
reorder = ids('reorder')
control = {'available': reorder is not None}
lines.append('')
lines.append('--- positive control: the order-derived identity MUST fail reorder ---')
if reorder is None:
    lines.append('  FAILED  reorder variant unavailable; the control cannot run')
    fails += 1
else:
    key = 'package:corpus/app.dart::topLevel'
    b, m = find(base, key), find(reorder, key)
    if b is None or m is None:
        lines.append('  FAILED  control subject missing')
        fails += 1
    else:
        canon_stable = b['declaration_id'] == m['declaration_id']
        index_stable = b['index_id'] == m['index_id']
        control.update({'canonical_stable_under_reorder': canon_stable,
                        'index_derived_stable_under_reorder': index_stable})
        if index_stable:
            lines.append('  FAILED  the order-derived control SURVIVED reorder — the '
                         'harness cannot detect an order-dependent identity, so it '
                         'has proved nothing about the canonical one')
            fails += 1
        else:
            lines.append('  ok      the order-derived control MOVED under reorder '
                         '(harness can detect the defect)')
        if not canon_stable:
            lines.append('  FAILED  the canonical identity moved under reorder')
            fails += 1
        else:
            lines.append('  ok      the canonical identity survived reorder')

# Collisions across every variant. A FAIL_OPEN.
lines.append('')
lines.append('--- collision search across every variant ---')
coll_total = 0
for f in sorted(os.listdir(work)):
    if not f.endswith('.json'):
        continue
    doc = load(os.path.join(work, f))
    n = len(doc.get('collisions', {}))
    coll_total += n
    if n:
        lines.append(f'  FAIL_OPEN  {f}: {n} collision(s) {list(doc["collisions"])[:2]}')
if coll_total == 0:
    n_decl = base['count']
    lines.append(f'  ok      no declaration_id collisions in any variant '
                 f'({n_decl} declarations in base)')
else:
    fails += coll_total

# Coverage: what member kinds the identity actually names.
kinds = {}
for r in base['declarations']:
    kinds[r['kind']] = kinds.get(r['kind'], 0) + 1
lines.append('')
lines.append('--- member kinds named in base ---')
lines.append('  ' + ', '.join(f'{v} {k}' for k, v in sorted(kinds.items())))

print('\n'.join(lines))
print()
print(f'SUMMARY checks_failed={fails} collisions={coll_total}')
print('G1 IDENTITY VERIFIED' if fails == 0 else 'G1 IDENTITY FAILED')

json.dump({
    'schema': 'semantic-map-1/g1-identity/1', 'gate': 'SM1-G1', 'issue': 50,
    'checks_failed': fails, 'collisions': coll_total,
    'base_declaration_count': base['count'],
    'member_kinds_named': kinds,
    'harness_control': control,
    'results': rows,
}, open(out_json, 'w'), indent=2)
sys.exit(1 if fails else 0)
