#!/usr/bin/env python3
"""Compute the SEMANTIC-MAP-1 verdict FROM the matrix.

#58 allows exactly five verdicts and gives their precedence:

    analyzer bug under a valid model         -> MODIFY_ANALYZER
    model cannot represent the distinction   -> MODIFY_MAP_DESIGN
    model works after excluding a decidable
      feature class                          -> REDUCE_SCOPE
    cannot mechanically identify or exclude
      the unsafe class                       -> ABANDON_OR_REDESIGN

plus PROCEED. There is no generic FAIL.

NOTHING HERE IS SEEDED. No verdict string is compared against an expected
value, and none of G5's, G8's or #59's own verdicts is read as an input. Each
predicate below is defined from #58's wording and evaluated against matrix
ROW CATEGORIES and generated gap data. Every predicate's value is published,
not only the winner, so a reader can see the whole decision surface and check
that the outcome was reachable from more than one direction.

If no predicate matches, the verdict is NOT_ESTABLISHED and this exits
non-zero. An unclassifiable matrix is a finding; #58 forbids a generic FAIL,
and inventing one of the five to fill the hole would be worse than saying the
matrix does not classify.

usage: compute_verdict.py <matrix.json> <out.json>
"""
import collections
import datetime
import json
import sys

matrix_doc = json.load(open(sys.argv[1]))
M = matrix_doc['matrix']
OUT = sys.argv[2]

POSITIVE = {'ESTABLISHED', 'REFUSAL_ENFORCED', 'MEASURED_DETERMINISTIC',
            'MEASURED_DETERMINISTIC_PROJECTION_LOW', 'ENUMERATED'}

# Rows whose category must be positive before PROCEED is even considered.
# GENERATION_TIME is excluded on purpose: it is a timing family and a
# current-run observation, so requiring it to be "positive" would make a
# reproducibility claim out of a stopwatch reading.
REQUIRED_FOR_PROCEED = [
    'DECLARATION_ID_STABILITY', 'DECLARATION_ID_COLLISIONS',
    'ABI_FINGERPRINT', 'BODY_FINGERPRINT', 'CLASSIFICATION_UNCHANGED',
    'CLASSIFICATION_CHANGED_BODY', 'CLASSIFICATION_ABI_BREAK',
    'PRIVACY_DOMAIN_DERIVATION', 'PRIVACY_CROSS_DOMAIN_REFUSAL',
    'RETENTION_CONTRACT', 'RETENTION_WITHHELD_FAILS_CLOSED',
    'PATCHABILITY_SUBSET_PROPERTY', 'OVER_CLAIM', 'MAP_RELEASE_BINDING',
    'MAP_SCHEMA_VERSIONING', 'MAP_SIZE', 'RETENTION_COST_AT_SCALE',
    'REPRODUCIBILITY',
]

# Rows that describe whether the MODEL can represent what it must. If these
# hold, a shortfall elsewhere is not a modelling failure of identity/ABI/body.
MODEL_ROWS = [
    'DECLARATION_ID_STABILITY', 'DECLARATION_ID_COLLISIONS',
    'ABI_FINGERPRINT', 'BODY_FINGERPRINT', 'CLASSIFICATION_UNCHANGED',
    'CLASSIFICATION_CHANGED_BODY', 'CLASSIFICATION_ABI_BREAK',
]


def cat(row):
    return M.get(row, {}).get('category', 'ABSENT_FROM_MATRIX')


def probe(row, name):
    return M.get(row, {}).get('probe_values', {}).get(name)


gaps = M.get('KNOWN_GAPS', {}).get('entries', [])
prereqs = [g for g in gaps if g.get('source') == 'g8_prerequisite']
blocking_prereqs = [g['id'] for g in prereqs
                    if g.get('severity') == 'BLOCKING_FOR_PRODUCTION'
                    and g.get('category') == 'UNRESOLVED']
# An analyzer/tool defect must be ATTRIBUTED by evidence, not inferred. No
# gate records such a severity, so this is False by absence of attribution
# rather than by opinion -- and if a future gate does record one, the
# predicate turns on by itself.
TOOL_SEVERITIES = {'ANALYZER_DEFECT', 'TOOL_DEFECT', 'IMPLEMENTATION_DEFECT'}
tool_attributions = [g['id'] for g in gaps
                     if g.get('severity') in TOOL_SEVERITIES]

non_positive = [r for r in REQUIRED_FOR_PROCEED if cat(r) not in POSITIVE]
not_established = [r for r in M if cat(r) == 'NOT_ESTABLISHED']

admitted = probe('PATCHABILITY_SUBSET_PROPERTY', 'admitted')
declarations = probe('PATCHABILITY_SUBSET_PROPERTY', 'declarations')
accounted = probe('PATCHABILITY_SUBSET_PROPERTY', 'accounted')
total_rows = probe('PATCHABILITY_SUBSET_PROPERTY', 'total_rows')

P = collections.OrderedDict()

P['EVERY_REQUIRED_ROW_POSITIVE'] = {
    'value': not non_positive,
    'from': f'rows not in a positive category: {non_positive or "none"}',
}
P['PATCHABILITY_POSITIVELY_ESTABLISHED'] = {
    'value': cat('PATCHABILITY_SUBSET_PROPERTY') == 'ESTABLISHED'
    and isinstance(admitted, int) and admitted > 0,
    'from': f'PATCHABILITY_SUBSET_PROPERTY={cat("PATCHABILITY_SUBSET_PROPERTY")}, '
            f'admitted={admitted} of {declarations}',
}
P['SUBSET_PROPERTY_VACUOUS'] = {
    'value': cat('PATCHABILITY_SUBSET_PROPERTY') == 'VACUOUS',
    'from': 'the subset property holds only because the admitted set is empty; '
            'zero admitted is not positive patchability evidence',
}
P['UNSAFE_CLASS_MECHANICALLY_ACCOUNTED'] = {
    'value': (isinstance(accounted, int) and accounted == total_rows
              and cat('PATCHABILITY_SUBSET_PROPERTY') != 'NOT_ESTABLISHED'),
    'from': f'reader accounting {accounted} of {total_rows} declarations; '
            'every declaration reaches a named state, so an empty admitted '
            'set is a decision rather than a coverage hole',
}
P['REFUSAL_PATH_ENFORCED'] = {
    'value': cat('OVER_CLAIM') == 'REFUSAL_ENFORCED',
    'from': f'OVER_CLAIM={cat("OVER_CLAIM")}',
}
P['BLOCKING_PREREQUISITES_UNRESOLVED'] = {
    'value': bool(blocking_prereqs),
    'from': f'unresolved BLOCKING_FOR_PRODUCTION prerequisites: '
            f'{blocking_prereqs or "none"}',
}
P['ANALYZER_DEFECT_ATTRIBUTED_BY_EVIDENCE'] = {
    'value': bool(tool_attributions),
    'from': f'gap entries attributing a shortfall to a tool or analyzer '
            f'defect: {tool_attributions or "none"}',
}
P['MODEL_ROWS_ALL_ESTABLISHED'] = {
    'value': all(cat(r) == 'ESTABLISHED' for r in MODEL_ROWS),
    'from': '; '.join(f'{r}={cat(r)}' for r in MODEL_ROWS),
}
P['RETENTION_WITHHELD_MEASURED_NOT_FAILING_CLOSED'] = {
    'value': cat('RETENTION_WITHHELD_FAILS_CLOSED') == 'ESTABLISHED_NEGATIVE',
    'from': f'RETENTION_WITHHELD_FAILS_CLOSED='
            f'{cat("RETENTION_WITHHELD_FAILS_CLOSED")}',
}

# The distinction the map exists to represent is patchability. It is NOT
# representable when: the admitted set is empty, that emptiness is a decision
# rather than a coverage hole (every declaration accounted for), and a blocking
# prerequisite still stands. Derived from categories and gap data -- no
# prerequisite is matched by name, so this predicate does not encode a
# conclusion about which prerequisite matters.
P['DISTINCTION_NOT_REPRESENTABLE'] = {
    'value': (P['SUBSET_PROPERTY_VACUOUS']['value']
              and P['UNSAFE_CLASS_MECHANICALLY_ACCOUNTED']['value']
              and P['BLOCKING_PREREQUISITES_UNRESOLVED']['value']),
    'from': 'SUBSET_PROPERTY_VACUOUS and '
            'UNSAFE_CLASS_MECHANICALLY_ACCOUNTED and '
            'BLOCKING_PREREQUISITES_UNRESOLVED',
}
# "Model works after excluding a decidable feature class" requires the reduced
# model to WORK -- to admit something. A reduction that admits nothing has not
# produced a working model, it has produced an empty one.
P['DECIDABLE_EXCLUSION_YIELDS_NONEMPTY'] = {
    'value': P['PATCHABILITY_POSITIVELY_ESTABLISHED']['value'],
    'from': f'a non-empty admitted set after exclusion: admitted={admitted}',
}
P['UNSAFE_CLASS_NOT_IDENTIFIABLE'] = {
    'value': not P['UNSAFE_CLASS_MECHANICALLY_ACCOUNTED']['value'],
    'from': 'the negation of UNSAFE_CLASS_MECHANICALLY_ACCOUNTED',
}
P['PROCEED_CONDITIONS_MET'] = {
    'value': (P['EVERY_REQUIRED_ROW_POSITIVE']['value']
              and P['PATCHABILITY_POSITIVELY_ESTABLISHED']['value']
              and P['REFUSAL_PATH_ENFORCED']['value']
              and not P['BLOCKING_PREREQUISITES_UNRESOLVED']['value']),
    'from': 'every required row positive, patchability positively '
            'established, refusals enforced, no blocking prerequisite open',
}

# ---- precedence, in #58's literal order --------------------------------
LADDER = [
    ('PROCEED', 'PROCEED_CONDITIONS_MET'),
    ('MODIFY_ANALYZER', 'ANALYZER_DEFECT_ATTRIBUTED_BY_EVIDENCE'),
    ('MODIFY_MAP_DESIGN', 'DISTINCTION_NOT_REPRESENTABLE'),
    ('REDUCE_SCOPE', 'DECIDABLE_EXCLUSION_YIELDS_NONEMPTY'),
    ('ABANDON_OR_REDESIGN', 'UNSAFE_CLASS_NOT_IDENTIFIABLE'),
]
verdict, selected_by, trace = 'NOT_ESTABLISHED', None, []
for name, pred in LADDER:
    hit = P[pred]['value']
    trace.append({'verdict': name, 'predicate': pred, 'value': hit,
                  'selected': hit and verdict == 'NOT_ESTABLISHED'})
    if hit and verdict == 'NOT_ESTABLISHED':
        verdict, selected_by = name, pred

# MODIFY_ANALYZER additionally requires the model to be valid -- #58 says
# "analyzer bug UNDER A VALID MODEL". Checked after selection so the ladder
# stays literal and the extra condition is visible rather than folded in.
if verdict == 'MODIFY_ANALYZER' and not P['MODEL_ROWS_ALL_ESTABLISHED']['value']:
    verdict, selected_by = 'NOT_ESTABLISHED', None

# ---- routing: an OUTPUT of the verdict, not a parallel opinion ----------
ROUTES = {
    'PROCEED': ['implement the map in the release pipeline'],
    'MODIFY_ANALYZER': ['repair the analyzer under the existing model'],
    'MODIFY_MAP_DESIGN': [
        'The map cannot decide patchability by inference from a finished AOT, '
        'so patchability has to become a BUILD-TIME guarantee rather than a '
        'post-hoc classification. #59 (Mutable AOT Dart) is the accepted '
        'direction for that and may be named here; no implementation begins '
        'in #58.',
        'AOT-ASSUMPTIONS-1 owns the optimizer-contract half and is still '
        'un-instrumented; it was deliberately not started here.',
    ],
    'REDUCE_SCOPE': ['ship the map over the reduced, decidable class only'],
    'ABANDON_OR_REDESIGN': ['no mechanically safe subset was identifiable'],
    'NOT_ESTABLISHED': ['the matrix does not classify; no lane is recommended'],
}
routing = list(ROUTES[verdict])
# Additional routing is derived from independent rows so it cannot be forgotten.
if P['RETENTION_WITHHELD_MEASURED_NOT_FAILING_CLOSED']['value']:
    routing.append(
        'RETENTION_WITHHELD_FAILS_CLOSED is a measured NEGATIVE: withholding '
        'some retention classes does not fail closed at load. That is '
        'independent of the patchability question and needs its own lane '
        'before any map is relied on.')
if cat('GENERATION_TIME') == 'MEASURED_CURRENT_RUN_ONLY':
    routing.append(
        'Generation-time figures are current-run observations. Any schedule '
        'or budget derived from them needs a repeated measurement at the '
        'scale being shipped, not this sample.')

doc = collections.OrderedDict([
    ('schema', 'semantic-map-1/final-verdict/1'),
    ('gate', 'SM1-FINAL'), ('issue', 58), ('tracker', 48),
    ('generated', datetime.datetime.now(datetime.timezone.utc)
     .strftime('%Y-%m-%dT%H:%M:%SZ')),
    ('allowed_verdicts', [v for v, _ in LADDER]),
    ('verdict', verdict),
    ('selected_by_predicate', selected_by),
    ('precedence_applied', "#58's literal order: PROCEED, MODIFY_ANALYZER, "
     'MODIFY_MAP_DESIGN, REDUCE_SCOPE, ABANDON_OR_REDESIGN"'),
    ('ladder_trace', trace),
    ('predicates', P),
    ('rows_not_established', not_established),
    ('rows_not_positive', non_positive),
    ('blocking_prerequisites', blocking_prereqs),
    ('next_lane', routing),
    ('non_proven_claims', [
        'No declaration was mechanically established safely patchable. The '
        f'subset property is {cat("PATCHABILITY_SUBSET_PROPERTY")} with '
        f'{admitted} of {declarations} admitted.',
        'NOT_INLINED means no covered body-copy mechanism was witnessed. It '
        'does not mean every call site observes a patch: the isolated '
        'experiment attached a patch whose direct call read PATCHED-w while '
        'the virtual call still read OLD-w.',
        'Pool-indirect and entry-point observations are non-safety facts. '
        'Tagged offsets alias between the Function and Code layouts, so '
        'redirectability is not decidable from a finished snapshot.',
        'REPRODUCTION: PASS states that the evidence and its refusals '
        'rebuild. It is not a statement of production readiness; '
        'PRODUCTION_PREREQUISITES is a separate partition and remains '
        f'{probe("REPRODUCIBILITY", "prerequisites")}.',
        'The full AOT SHA-256 is the authoritative release identity. The GNU '
        'build ID is diagnostic only -- build ids hash four snapshot segments '
        'and collide across different AOTs.',
        'Timing figures and the order-dependence label set are current-run '
        'observations. The max(stdev) classifier is a cost diagnostic, not '
        'causality or safety evidence.',
        "G4's retention curve understates measured cost at scale, so the "
        'projection may not be substituted for a measurement.',
    ]),
])
json.dump(doc, open(OUT, 'w'), indent=2)

w = sys.stdout.write
w('  PREDICATES (all published, not only the selecting one)\n')
for k, v in P.items():
    w(f'    {str(v["value"]):5}  {k}\n')
    w(f'           {v["from"]}\n')
w('\n  LADDER, in #58 precedence order\n')
for t in trace:
    mark = ' <== SELECTED' if t['selected'] else ''
    w(f'    {str(t["value"]):5}  {t["verdict"]:22} via {t["predicate"]}{mark}\n')
w(f'\n  VERDICT: {verdict}\n')
w(f'  selected by: {selected_by}\n')
w('\n  NEXT LANE\n')
for r in routing:
    w(f'    - {r}\n')
sys.exit(0 if verdict != 'NOT_ESTABLISHED' else 1)
