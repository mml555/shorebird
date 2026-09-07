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
obf_dir = sys.argv[5] if len(sys.argv) > 5 else None


def load(path):
    with open(path) as f:
        return json.load(f)


def ids(label):
    p = os.path.join(work, f'{label}.json')
    if not os.path.isfile(p):
        return None
    return load(p)


def find_all(doc, subject_key):
    """Every declaration matching library + owner + name.

    Separate from find() because a destination must be proven to exist EXACTLY
    ONCE. find() picks one when several match, which is right for locating a
    subject and wrong for counting.
    """
    lib, _, rest = subject_key.partition('::')
    if '.' in rest:
        owner, name = rest.split('.', 1)
    else:
        owner, name = None, rest
    return [r for r in doc['declarations']
            if r['library'] == lib and r['owner'] == owner and r['name'] == name]


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


def check(mutant_id, subject, want_stable, source, note='', baseline='base',
          expected_new_subject=None):
    global fails
    base_doc = ids(baseline)
    if base_doc is None:
        lines.append(f'  FAILED  {mutant_id:24} baseline {baseline!r} unavailable')
        fails += 1
        rows.append({'id': mutant_id, 'outcome': 'NO_BASELINE'})
        return
    doc = ids(mutant_id)
    if doc is None:
        lines.append(f'  FAILED  {mutant_id:24} could not build/collect ids')
        fails += 1
        rows.append({'id': mutant_id, 'outcome': 'NO_EVIDENCE'})
        return
    key = norm(subject)
    b = find(base_doc, key)
    m = find(doc, key)
    if b is None:
        lines.append(f'  FAILED  {mutant_id:24} subject {key} not found in BASE')
        fails += 1
        rows.append({'id': mutant_id, 'outcome': 'SUBJECT_MISSING_IN_BASE'})
        return
    if m is None:
        # ABSENCE IS NOT EVIDENCE THAT THE IDENTITY MOVED. A walker that simply
        # dropped the declaration would satisfy "gone from the old key", so a
        # must-move case has to name where it went and the destination has to be
        # there exactly once, under a different id.
        if not want_stable:
            if not expected_new_subject:
                lines.append(f'  FAILED  {mutant_id:24} gone from its old key, but the '
                             f'case declares no expected_new_subject — absence alone '
                             f'does not show the identity moved')
                fails += 1
                rows.append({'id': mutant_id, 'outcome': 'ABSENT_NO_DESTINATION'})
                return
            hits = find_all(doc, expected_new_subject)
            if len(hits) != 1:
                lines.append(f'  FAILED  {mutant_id:24} destination '
                             f'{expected_new_subject} found {len(hits)} time(s), want exactly 1')
                fails += 1
                rows.append({'id': mutant_id, 'outcome': 'DESTINATION_NOT_UNIQUE',
                             'destination_hits': len(hits)})
                return
            new_id = hits[0]['declaration_id']
            if new_id == b['declaration_id']:
                lines.append(f'  FAILED  {mutant_id:24} destination exists but carries the '
                             f'SAME declaration_id — the identity did not move')
                fails += 1
                rows.append({'id': mutant_id, 'outcome': 'DESTINATION_SAME_ID'})
                return
            lines.append(f'  ok      {mutant_id:24} moved: gone from the old key, present '
                         f'exactly once at {expected_new_subject.split("::")[-1]}, new id')
            rows.append({'id': mutant_id, 'outcome': 'MOVED_TO_DESTINATION',
                         'old_declaration_id': b['declaration_id'],
                         'new_declaration_id': new_id,
                         'destination': expected_new_subject})
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
    if m.get('scored_by'):
        lines.append(f"  --      {m['id']:24} scored by the "
                     f"{m['scored_by']} arm, not by comparison to base")
        continue
    check(m['id'], m['subject'], m['declaration_id_stable'],
          'g1_identity/EXPECTATIONS_EXT.json', m.get('note', ''),
          baseline=m.get('baseline', 'base'),
          expected_new_subject=m.get('expected_new_subject'))

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



# ---------------------------------------------------------------- extra arms
extra = {}

def arm(title):
    lines.append('')
    lines.append(f'--- {title} ---')

# 1. RECOMPILATION. #50 wants its own G1 arm: rebuild identical source
#    independently and compare the COMPLETE id set. G0's deterministic-dill
#    result is supporting evidence, not a substitute for the identity check.
arm('recompilation: an independent rebuild of identical source')
rebuild = ids('base_rebuild')
if rebuild is None:
    lines.append('  FAILED  no independent rebuild was produced')
    fails += 1
else:
    a = {r['declaration_id'] for r in base['declarations']}
    b = {r['declaration_id'] for r in rebuild['declarations']}
    extra['recompilation'] = {
        'base_count': len(a), 'rebuild_count': len(b),
        'identical_sets': a == b,
        'only_in_base': sorted(a - b)[:5], 'only_in_rebuild': sorted(b - a)[:5]}
    if a == b and len(a) == base['count']:
        lines.append(f'  ok      complete id set identical across an independent '
                     f'rebuild ({len(a)} declarations)')
    else:
        lines.append(f'  FAILED  id set differs across rebuild: '
                     f'{len(a - b)} only in base, {len(b - a)} only in rebuild')
        fails += 1

# 2. OBFUSCATION, measured rather than reasoned about.
arm('obfuscation: identity vs the runtime-resolvable name')
if not obf_dir or not os.path.isfile(os.path.join(obf_dir, 'obfmap.json')):
    lines.append('  FAILED  the obfuscation arm did not run; #50 requires it measured')
    fails += 1
else:
    om = load(os.path.join(obf_dir, 'obfmap.json'))
    pairs = ([(om[i], om[i + 1]) for i in range(0, len(om), 2)]
             if isinstance(om, list) else list(om.items()))
    renamed = {a: b for a, b in pairs}
    subjects = ['topLevel', 'Shape', 'area', 'usesPrivate', 'Box', 'helperAdd']
    hit = {k: renamed[k] for k in subjects if k in renamed and renamed[k] != k}
    obf_ids = ids('base_obfuscated')
    same_ids = (obf_ids is not None and
                {r['declaration_id'] for r in obf_ids['declarations']} ==
                {r['declaration_id'] for r in base['declarations']})
    extra['obfuscation'] = {
        'obfuscation_map_entries': len(pairs),
        'declared_names_renamed': hit,
        'declaration_ids_unchanged': same_ids}
    if same_ids:
        lines.append('  ok      declaration_id is UNCHANGED under obfuscation '
                     '(the map is kernel-derived; obfuscation is a snapshot-time transform)')
    else:
        lines.append('  FAILED  declaration_id moved under obfuscation')
        fails += 1
    if hit:
        lines.append(f'  ok      but the RUNTIME name does change, measured: '
                     + ', '.join(f'{k}->{v}' for k, v in list(hit.items())[:4]))
        lines.append('          => identity is obfuscation-invariant; the BINDING name is not, '
                     'and needs the release obfuscation map')
    else:
        lines.append('  FAILED  the obfuscation map renamed none of our declarations, so this '
                     'arm measured nothing')
        fails += 1

# 3. EXTENSION-MEMBER DISTINCTNESS, not just non-disturbance.
arm('extension members: two same-named members in different extensions')
two = ids('ext_two_extensions')
if two is None:
    lines.append('  FAILED  ext_two_extensions unavailable')
    fails += 1
else:
    sx = find(two, 'package:corpus/app.dart::ShapeX.doubled')
    bx = find(two, 'package:corpus/app.dart::BoxX.doubled')
    if sx is None or bx is None:
        lines.append(f'  FAILED  could not locate both extension members '
                     f'(ShapeX.doubled={sx is not None}, BoxX.doubled={bx is not None})')
        fails += 1
    else:
        distinct = sx['declaration_id'] != bx['declaration_id']
        by_owner = sx['owner'] != bx['owner'] and sx['name'] == bx['name']
        extra['extension_distinctness'] = {
            'distinct_ids': distinct, 'differ_by_owner': by_owner,
            'shapex_lowered': sx.get('loweredName'), 'boxx_lowered': bx.get('loweredName'),
            'owner_kind': sx.get('ownerKind')}
        if distinct and by_owner:
            lines.append('  ok      distinct identities, differing by OWNER with the same '
                         f"declared name ({sx['owner']} vs {bx['owner']}, both `{sx['name']}`)")
            lines.append(f"          kernel lowered them to {sx.get('loweredName')} / "
                         f"{bx.get('loweredName')}; the identity does not depend on that mangling")
        else:
            lines.append(f'  FAILED  distinct={distinct} differ_by_owner={by_owner}')
            fails += 1

# 4. NESTED / LOCAL FUNCTIONS: a scope claim, stated explicitly.
arm('nested scope: is a local function named at all?')
loc = ids('ext_local_function')
if loc is None:
    lines.append('  FAILED  ext_local_function unavailable')
    fails += 1
else:
    named = [r for r in loc['declarations'] if r['name'] == 'nestedHelper']
    extra['nested_functions'] = {'named': len(named), 'names': [r['selector'] for r in named]}
    allowed = load(ext_exp)['scope_expectations']['nested_functions_named']
    if len(named) != allowed:
        seen = [r['selector'] for r in named] or ['<none>']
        lines.append(f'  FAILED  local functions named={len(named)} ({", ".join(seen)}) but the '
                     f'accepted scope allows {allowed}. Locals are not independently '
                     f'addressable; changing that is a deliberate scope change, not a finding.')
        fails += 1
    else:
        lines.append(f'  ok      the local function is NOT named ({len(named)} named, scope '
                     f'allows {allowed}) — SCOPE STATEMENT: the map does not address '
                     'local/nested functions, so a patch targeting one must be REFUSED '
                     'rather than silently missed. Carried to SM1-G5.')

# 5. SYNTHETIC / GENERATED MEMBERS: what is named, and how flagged.
arm('synthetic / generated members')
syn = ids('ext_synthetic_members')
if syn is None:
    lines.append('  FAILED  ext_synthetic_members unavailable')
    fails += 1
else:
    gen = [r for r in syn['declarations'] if r['owner'] in ('Mixed', 'Doubler')]
    flagged = [r for r in gen if r['synthetic']]
    extra['synthetic_members'] = {
        'named': [{'selector': r['selector'], 'kind': r['kind'], 'synthetic': r['synthetic']}
                  for r in gen],
        'flagged_synthetic': len(flagged)}
    for r in gen:
        lines.append(f"            {r['selector']:28} {r['kind']:12} synthetic={r['synthetic']}")
    if not gen:
        lines.append('  FAILED  no generated members were named at all')
        fails += 1
    # THE FLAG ITSELF IS REQUIRED. An arm that fails only when nothing is found
    # can green with flagged_synthetic == 0, and the flag would rot unnoticed.
    req = load(ext_exp)['scope_expectations']['required_synthetic_row']
    match = [r for r in gen
             if r['selector'] == req['selector'] and r['kind'] == req['kind']
             and r['synthetic'] == req['synthetic']]
    extra['synthetic_members']['required_row'] = req
    extra['synthetic_members']['required_row_present'] = bool(match)
    if match:
        lines.append(f'  ok      required generated row present and flagged: '
                     f"{req['selector']} ({req['kind']}) synthetic={req['synthetic']}")
    else:
        present = [f"{r['selector']}({r['kind']},synthetic={r['synthetic']})" for r in gen]
        lines.append(f'  FAILED  required generated row missing or not flagged: '
                     f"want {req['selector']} ({req['kind']}) synthetic={req['synthetic']}; "
                     f"saw {present}")
        fails += 1
    if len(flagged) == 0:
        lines.append('  FAILED  no generated member was flagged synthetic at all')
        fails += 1

# 6. WHICH KERNEL THE MAP IS DERIVED FROM. Measured here because it changes what
#    "the set of declarations" even means, which is G1's subject.
arm('kernel domain: --aot tree-shakes declarations away')
aot_doc, pre_doc = ids('shake_aot'), ids('shake_noaot')
if aot_doc is None or pre_doc is None:
    lines.append('  FAILED  could not build both an AOT and a pre-AOT kernel to compare')
    fails += 1
else:
    a = {(r['library'], r['owner'], r['name'], r['kind']) for r in aot_doc['declarations']}
    b = {(r['library'], r['owner'], r['name'], r['kind']) for r in pre_doc['declarations']}
    lost = sorted(b - a, key=lambda t: tuple('' if x is None else x for x in t))
    extra['kernel_domain'] = {
        'aot_declarations': aot_doc['count'],
        'pre_aot_declarations': pre_doc['count'],
        'shaken_out': [f"{o or ''}.{n} ({k})" for (_l, o, n, k) in lost],
        'consequence': ('A map derived from the AOT kernel describes a TREE-SHAKEN program, '
                        'not the program that was written. Deriving from the AOT kernel is the '
                        'CONSERVATIVE choice -- it cannot claim a shaken-out declaration is '
                        'patchable -- but it cannot explain "you wrote it and it is not here" '
                        'either. Deriving from the pre-AOT kernel would name declarations the '
                        'release does not contain, which is an over-claim and a FAIL_OPEN under '
                        "SM1-G5's subset rule."),
        'recommendation': ('derive the map from the AOT kernel; carry the pre-AOT set alongside '
                           'only as explanatory data, never as the patchable set'),
    }
    if lost:
        lines.append(f'  FINDING --aot removed {len(lost)} declaration(s): '
                     f'{aot_doc["count"]} named vs {pre_doc["count"]} pre-AOT')
        for (_l, o, n, k) in lost[:6]:
            lines.append(f"            shaken out: {(o or '<top>')}.{n} ({k})")
        lines.append('          => which kernel the map is derived from is a DESIGN DECISION,')
        lines.append('             not an implementation detail. AOT kernel is the conservative')
        lines.append('             choice; the pre-AOT set is explanatory data only.')
    else:
        lines.append('  ok      no declarations were shaken out on this corpus')

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
    'extra_arms': extra,
    'results': rows,
}, open(out_json, 'w'), indent=2)
sys.exit(1 if fails else 0)
