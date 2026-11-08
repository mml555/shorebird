#!/usr/bin/env python3
"""MAOT-1 (#65) -- derive the issue's verdict from the evidence.

The checks here are the ones the falsification arms break. Each is a real
detector over the manifests and case results, not a restatement of a case's
own answer: a case says "these two id sets matched", and a check says "no id
anywhere contains a build path". Both are needed, because a case can only see
what it compared.
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Every required test #65 names, and the case that discharges it. Declared
# here so a missing case is a finding rather than a silently shorter run.
REQUIRED_TESTS = {
    '1': 'T01', '2': 'T02', '3': 'T03', '4': 'T04', '5': 'T01',
    '6': 'T06', '7': 'T07', '8': 'T08', '9': 'T09',
}

# Test 10 is a fail-closed requirement, so it is discharged by a falsification
# ARM rather than by a case: a natural collision cannot be provoked from Dart
# source, and a "case" that never collides would prove nothing. It is checked
# against the arm population, not silently dropped.
REQUIRED_TESTS_BY_ARM = {'10': 'F04'}

# Extra surfaces #65 calls out by name.
REQUIRED_SURFACES = {
    'extensions': 'TX1',
    'extension_types': 'TX1',
    'enum_synthesized': 'TX2',
    'mixin_synthetic_application': 'TX4',
    'accessors_and_operators': 'TX3',
    'constructors_and_factories': 'TX3',
    'private_unlinked_platform': 'TX5',
    'file_uri_without_app_root': 'TX6',
    'file_uri_with_app_root': 'TX7',
}

# Path fragments that must never appear inside an identity. Not an exhaustive
# list of all paths -- it is the set this machine and CI can actually produce,
# and the two-directory case is what catches the rest.
PATH_MARKERS = ('/tmp/', '/private/', '/Users/', '/home/', '/var/folders/',
                'file://', '\\Users\\')

# A run of >= 12 hex digits inside an id is the shape of an address or a
# content hash. Neither belongs in a logical identity.
HEX_RUN = re.compile(r'[0-9a-f]{12,}')


def _f(findings, code, severity, message, **extra):
    rec = {'code': code, 'severity': severity, 'message': message}
    rec.update(extra)
    findings.append(rec)


def check_manifest(manifest, label, findings):
    """Detectors that read a manifest directly."""
    ident = manifest.get('identity', {})
    entries = ident.get('entries', [])

    if not entries:
        _f(findings, 'MANIFEST_EMPTY', 'blocking',
           f'{label}: manifest contains no entries; an empty namespace cannot '
           'testify to anything', manifest=label)

    for e in entries:
        eid = e.get('id', '')
        for marker in PATH_MARKERS:
            if marker in eid:
                _f(findings, 'IDENTITY_PATH_DEPENDENT', 'blocking',
                   f'{label}: id contains the build-path marker {marker!r}: '
                   f'{eid}', manifest=label, id=eid)
        hex_run = HEX_RUN.search(eid)
        if hex_run:
            _f(findings, 'IDENTITY_ADDRESS_LIKE', 'blocking',
               f'{label}: id contains a long hex run ({hex_run.group()}), the '
               f'shape of an address or content hash: {eid}',
               manifest=label, id=eid)
        if e.get('stability') == 'nominal' and e.get('role') != 'none':
            _f(findings, 'SYNTHETIC_CLAIMS_NOMINAL', 'blocking',
               f'{label}: {eid} carries role {e.get("role")!r} while claiming '
               'nominal stability; compiler-generated entities must not claim '
               'source-level identity', manifest=label, id=eid)
        # A lowered extension name must never BE an identity. The lowering is
        # recorded as an alias; seeing it in the id position means the logical
        # declaration was bypassed.
        last = eid.split('::')[-1]
        if '|' in last:
            _f(findings, 'LOWERED_FORM_AS_IDENTITY', 'blocking',
               f'{label}: {eid} uses a lowered/mangled procedure name as its '
               'identity; identity must come from the owning declaration',
               manifest=label, id=eid)

    if ident.get('duplicate_count', 0) != 0:
        _f(findings, 'IDENTITY_COLLISION', 'blocking',
           f'{label}: {ident["duplicate_count"]} colliding id(s); two '
           'declarations sharing one identity means a patch binding to either '
           'binds to the wrong one', manifest=label)

    if ident.get('refusal_count', 0) != 0:
        _f(findings, 'IDENTITY_REFUSED', 'blocking',
           f'{label}: {ident["refusal_count"]} library/libraries could not be '
           'named reproducibly', manifest=label)

    for field in ('dart_commit', 'dart_tree'):
        value = ident.get(field)
        if not value or len(value) != 40:
            _f(findings, 'MANIFEST_UNBOUND', 'blocking',
               f'{label}: {field} is not a full 40-hex sha; an unbound '
               'manifest names a namespace without saying which compiler '
               'produced it', manifest=label)


def check_namespace_binding(release, patch, findings):
    """A patch may only be compared against a release from the same compiler."""
    r, p = release.get('identity', {}), patch.get('identity', {})
    for field in ('dart_commit', 'dart_tree', 'identity_schema'):
        if r.get(field) != p.get(field):
            _f(findings, 'NAMESPACE_MISMATCH', 'blocking',
               f'release and patch disagree on {field}: {r.get(field)!r} vs '
               f'{p.get(field)!r}. Comparing ids across two namespaces would '
               'report agreement that means nothing')


def check_population(cases, findings, arms=None):
    """A gate that passes on no evidence is not a gate."""
    if not cases:
        _f(findings, 'EMPTY_TEST_POPULATION', 'blocking',
           'no identity cases ran; a verdict derived from zero cases would '
           'be a statement about nothing')
        return
    by_id = {c['id'] for c in cases}
    for number, case_id in sorted(REQUIRED_TESTS.items()):
        if case_id not in by_id:
            _f(findings, 'REQUIRED_TEST_ABSENT', 'blocking',
               f'#65 required test {number} is discharged by case {case_id}, '
               f'which did not run', required_test=number, case=case_id)
    arm_ids = {a['id'] for a in (arms or [])}
    for number, arm_id in sorted(REQUIRED_TESTS_BY_ARM.items()):
        if arms is None:
            continue
        if arm_id not in arm_ids:
            _f(findings, 'REQUIRED_TEST_ABSENT', 'blocking',
               f'#65 required test {number} is discharged by falsification '
               f'arm {arm_id}, which did not run', required_test=number,
               arm=arm_id)

    for surface, case_id in sorted(REQUIRED_SURFACES.items()):
        if case_id not in by_id:
            _f(findings, 'REQUIRED_SURFACE_ABSENT', 'blocking',
               f'required surface {surface!r} is discharged by case '
               f'{case_id}, which did not run', surface=surface)


def derive(cases, findings, fork, manifests):
    failed = [c['id'] for c in cases if c['result'] != 'pass']
    blocking = [f for f in findings if f.get('severity') == 'blocking']

    claim = 'ESTABLISHED' if (cases and not failed and not blocking) \
        else 'NOT_ESTABLISHED'

    return {
        'stable_identity': claim,
        'cases_run': len(cases),
        'cases_failed': failed,
        'blocking_findings': sorted({f['code'] for f in blocking}),
        'required_tests': REQUIRED_TESTS,
        'required_tests_by_arm': REQUIRED_TESTS_BY_ARM,
        'required_surfaces': REQUIRED_SURFACES,
        'fork_identity': fork,
        'namespaces': manifests,
        'diagnostic_only': (
            'cases_run is DIAGNOSTIC. The verdict is a conjunction over every '
            'case and every detector; no count or ratio is compared anywhere '
            'in this module.'),
        'verdict_rule': (
            'stable_identity == ESTABLISHED iff at least one case ran AND '
            'every case passed AND every #65 required test and named surface '
            'has a case AND no blocking detector finding was raised.'),
    }


# Which decision reads each field the record produces. Checked in both
# directions by the driver: a computed value nothing consumes is a defect, and
# so is a declared consumer for a value that is not produced.
CONSUMERS = {
    'verdict': 'the gate exit code, and whether #65 may be closed',
    'cases': 'verdict.cases_failed, and the per-requirement coverage check',
    'findings': 'verdict.blocking_findings and the gate exit code',
    'fork_identity': 'whether a result may be quoted at all -- a result from '
                     'a different compiler is a different question',
    'manifests': 'the namespace binding check, and #66\'s starting namespace',
    'falsification': 'whether the detectors above are known to fire; an '
                     'never-falsified detector is not known to work',
    'schema': 'readers and later issues consuming this record',
    'issue': 'readers and later issues consuming this record',
    'generated_by': 'reproducing this record',
    'consumers': 'this check itself, in both directions',
}
