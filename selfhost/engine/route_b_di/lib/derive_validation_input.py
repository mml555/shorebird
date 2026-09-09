#!/usr/bin/env python3
"""B0: does the fork AS IT STANDS make a COMPLETE, release-bound
module-validation source mechanically available?

SCOPE, stated here and not only in the record this writes: the answer is about
the sources present in this tree at this revision, reached over the derived
consumer universe. It is not a claim that no such source can exist -- a future
derivation algorithm or a designed permission policy could supply one, and the
falsification arms show the verdict would then move.

THE DEFECT THIS REPLACES. The first version computed candidate sources and a
`usable_sources` list, and then the verdict ignored both. It was effectively:

    the CURRENT generator's spec is complete and validates -> DERIVABLE
    anything else                                          -> UNDERIVED

So an independent complete release-bound policy could have existed and B0 would
still have said VALIDATION_INPUT_UNDERIVED, as long as the retention generator
stayed callable-only. The candidate analysis was decoration -- an analysis that
changes no verdict -- which is the same class as a finding that changes no
verdict.

The verdict is now derived from the SOURCES, and every source is assigned a
role from its own recorded properties:

  ineligible          never counts, whatever else is true
  complete            release-bound, consumed by a release build, supplies all
                      four sections, AND demonstrated to validate the positive
                      module
  partial             release-bound but supplies only some sections
  unusable            everything else, with the reason recorded

PARTIAL IS NOT COMPLETE. The retention generator was previously labelled
"usable" while supplying one section of four. Supplying some of what is needed
is a different fact from supplying it, and the role names now keep them apart.

A NONZERO COUNT IS NOT A CONVERSION. A candidate that merely has content --
the semantic map's admitted set, say -- does not become a source until
something converts it into a specification and that specification is
demonstrated to validate. No converter, no source.

PATCH-DERIVED PERMISSIONS ARE PERMANENTLY INELIGIBLE. Reading the required
permissions off the module being validated would permit whatever that module
does, so validation would refuse nothing. That is the vacuous case, and no
combination of other evidence promotes it.

usage: derive_validation_input.py <sources.json> <repo-root> <freeze> <out>
"""
import datetime
import hashlib
import json
import pathlib
import sys

SOURCES = pathlib.Path(sys.argv[1])
REPO = pathlib.Path(sys.argv[2])
FREEZE = pathlib.Path(sys.argv[3])
OUT = sys.argv[4]

SECTIONS = ['callable', 'extendable', 'can-be-overridden',
            'can-be-used-as-type']
# Ineligible by construction, not by measurement. Listed here so the rule is
# visible and so no recorded property can promote it.
PERMANENTLY_INELIGIBLE = {'the_module_itself'}

notes = []
try:
    src_doc = json.loads(SOURCES.read_text())
    sources = src_doc['sources']
except Exception as ex:                                      # noqa: BLE001
    print(f'sources record unreadable: {type(ex).__name__}')
    sources = None
    notes.append(f'sources record unreadable ({type(ex).__name__})')


def role_of(name, s):
    """Assign a role from the source's OWN recorded properties."""
    if name in PERMANENTLY_INELIGIBLE or s.get('permanently_ineligible'):
        return 'ineligible', ('reading permissions off the module being '
                              'validated would permit whatever it does, so '
                              'validation would refuse nothing')
    if not s.get('release_bound'):
        return 'unusable', 'not release-bound'
    supplied = sorted(k for k, v in (s.get('sections') or {}).items() if v)
    missing = [k for k in SECTIONS if k not in supplied]
    if not supplied:
        return 'unusable', (s.get('why_unusable')
                            or 'supplies no specification section')
    if missing:
        return 'partial', f'supplies {supplied}, missing {missing}'
    if not s.get('release_consumed'):
        return 'unusable', ('supplies all four sections but no release or '
                            'build script consumes it, so it is not a '
                            'production input')
    if not s.get('validated_positive'):
        return 'unusable', ('supplies all four sections and is release-'
                            'consumed, but did not validate the positive '
                            'module -- sections present is not the same as a '
                            'usable validation input')
    return 'complete', ('release-bound, release-consumed, all four sections, '
                        'and demonstrated to validate the positive module')


roles = {}
if sources is not None:
    for name, s in sources.items():
        r, why = role_of(name, s)
        roles[name] = {'role': r, 'why': why,
                       'sections_supplied': sorted(
                           k for k, v in (s.get('sections') or {}).items()
                           if v),
                       'release_bound': s.get('release_bound'),
                       'release_consumed': s.get('release_consumed'),
                       'validated_positive': s.get('validated_positive'),
                       'spec_sha256': s.get('spec_sha256')}

complete_sources = sorted(k for k, v in roles.items()
                          if v['role'] == 'complete')
partial_sources = sorted(k for k, v in roles.items() if v['role'] == 'partial')
ineligible = sorted(k for k, v in roles.items() if v['role'] == 'ineligible')
unusable = sorted(k for k, v in roles.items() if v['role'] == 'unusable')

# Sections nothing release-bound supplies at all.
supplied_anywhere = set()
for name, v in roles.items():
    if v['role'] in ('complete', 'partial'):
        supplied_anywhere |= set(v['sections_supplied'])
sections_with_no_source = [s for s in SECTIONS if s not in supplied_anywhere]

# ---- provenance ------------------------------------------------------
prov = {}
try:
    fz = json.loads(FREEZE.read_text())['producing_source']['dart']
    prov['dart_revision'] = fz['revision']
    prov['dart_effective_tree'] = fz['effective_tree']
except Exception as ex:                                      # noqa: BLE001
    notes.append(f'freeze manifest unreadable ({type(ex).__name__})')
gen = REPO / 'selfhost/engine/route_b/gen_dynamic_interface.dart'
if gen.exists():
    prov['derivation_identity'] = {
        'generator': 'selfhost/engine/route_b/gen_dynamic_interface.dart',
        'sha256': hashlib.sha256(gen.read_bytes()).hexdigest()}
prov['specification_digests'] = {
    k: v['spec_sha256'] for k, v in roles.items() if v.get('spec_sha256')}
prov['release_aot_identity'] = (
    'obtainable -- G6 binds a map to the full AOT SHA-256 and the same binding '
    'applies. Recorded as available rather than collected: there is no '
    'complete specification to bind while complete_sources is empty.')
prov['relationship_to_host_policy'] = (
    'the retention specification IS the host policy -- the same file feeds '
    'gen_kernel --dynamic-interface. A validation specification would have to '
    'be that file plus the three permission sections, and the annotator '
    'annotates all four, so widening the host half is not free: whole-library '
    'dart:core retention measured +310%. Member-scoped dart:core entries do '
    'validate, so the obstacle is the absence of the sections, not their cost.')

# ---- the verdict, DERIVED FROM THE ROLES -----------------------------
if sources is None:
    b0 = 'B0_EVIDENCE_MISSING'
elif complete_sources:
    b0 = 'COMPLETE_SPECIFICATION_DERIVABLE'
else:
    b0 = 'VALIDATION_INPUT_UNDERIVED'

doc = {
    'schema': 'route-b-di-1/stage-b0/2',
    'issue': 61, 'stage': 'B0',
    'generated': datetime.datetime.now(datetime.timezone.utc)
                 .strftime('%Y-%m-%dT%H:%M:%SZ'),
    'question': 'Does the fork AS IT STANDS make a COMPLETE, release-bound '
                'module-validation source mechanically available?',
    'scope_of_the_answer':
        'A statement about the sources present in this tree at this revision, '
        'reached over the derived consumer universe. It is NOT a statement '
        'that no such source can exist: a future derivation algorithm, or a '
        'deliberately designed permission policy, could supply one. The '
        'falsification arms demonstrate exactly that -- a complete source '
        'introduced anywhere in the universe moves the verdict -- so this '
        'result is contingent on the evidence, not a claim about what is '
        'possible.',
    'verdict_rule':
        'COMPLETE_SPECIFICATION_DERIVABLE if and only if at least one source '
        'holds the role `complete`: release-bound, consumed by a release '
        'build, supplying all four sections, and demonstrated to validate the '
        'positive module. The verdict is a function of the ROLES, so a '
        'complete source discovered anywhere moves it -- the current '
        'retention generator staying callable-only does not pin the answer. '
        'Patch-derived permissions are permanently ineligible and no other '
        'evidence promotes them.',
    'b0_result': b0,
    'sections_required': SECTIONS,
    'source_roles': roles,
    'complete_sources': complete_sources,
    'partial_sources': partial_sources,
    'ineligible_sources': ineligible,
    'unusable_sources': unusable,
    'sections_with_no_release_bound_source': sections_with_no_source,
    'permanently_ineligible': sorted(PERMANENTLY_INELIGIBLE),
    'provenance_available': prov,
    'notes': notes,
    'does_not_claim': [
        'That the validator is insufficient. Stage A showed it refuses real '
        'violations and accepts a complete specification, including with '
        'member-scoped dart:core entries. The gap measured here is the INPUT, '
        'not the mechanism.',
        'That no complete validation source CAN exist. Only that none is '
        'mechanically available in this tree at this revision. A future '
        'derivation algorithm or a designed permission policy could supply '
        'one, and the classifier would then say so.',
    ],
}
json.dump(doc, open(OUT, 'w'), indent=2)

w = sys.stdout.write
w('  SOURCE ROLES (the verdict is a function of these)\n')
for name, v in sorted(roles.items()):
    w(f'    {v["role"]:10} {name}\n')
    w(f'               sections={v["sections_supplied"] or "none"} '
      f'release_consumed={v["release_consumed"]} '
      f'validated={v["validated_positive"]}\n')
    w(f'               {v["why"]}\n')
w(f'\n  complete={complete_sources or "none"}\n')
w(f'  partial={partial_sources or "none"}\n')
w(f'  ineligible={ineligible or "none"}\n')
w(f'  sections no release-bound source supplies: '
  f'{sections_with_no_source or "none"}\n')
if notes:
    w(f'  notes: {notes}\n')
w(f'\nB0: {b0}\n')
sys.exit(0 if b0 == 'COMPLETE_SPECIFICATION_DERIVABLE' else 1)
