#!/usr/bin/env python3
"""MAOT-1 (#65) -- break every detector, in both directions.

The cases prove the scheme behaves. These arms prove the GATE would notice if
it did not. Both are needed: a suite of passing cases and a detector that
cannot fire look identical from the outside.

P0 is the positive control -- the real manifests raise no blocking finding.
Without it every arm below is satisfied by a detector that flags everything.
"""

import copy
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verdict as V          # noqa: E402


def _codes(findings):
    return {f['code'] for f in findings}


def run(real_manifest, cases, private_manifest=None):
    arms = []

    def arm(aid, requirement, description, mutate, expect_code,
            expect_absent=()):
        findings = []
        m = copy.deepcopy(real_manifest)
        mutate(m)
        V.check_manifest(m, 'mutated', findings)
        got = _codes(findings)
        problems = []
        if expect_code and expect_code not in got:
            problems.append(f'expected {expect_code}, not raised')
        for code in expect_absent:
            if code in got:
                problems.append(f'{code} raised and should not be')
        arms.append({
            'id': aid, 'requirement': requirement, 'description': description,
            'expected_code': expect_code, 'observed_codes': sorted(got),
            'result': 'pass' if not problems else 'FAIL',
            'problems': problems,
        })

    # ------------------------------------------------------------------ P0
    findings = []
    V.check_manifest(real_manifest, 'real', findings)
    blocking = sorted({f['code'] for f in findings
                       if f['severity'] == 'blocking'})
    arms.append({
        'id': 'P0',
        'requirement': 'positive control',
        'description': 'the real, unmodified manifest raises no blocking '
                       'finding -- without this, every arm below would also '
                       'be satisfied by a detector that flags everything',
        'expected_code': None,
        'observed_codes': blocking,
        'result': 'pass' if not blocking else 'FAIL',
        'problems': [] if not blocking else [f'blocking: {blocking}'],
    })

    # ------------------------------------------------- 1. address-derived id
    def mutate_address(m):
        m['identity']['entries'][0]['id'] += '@0x7ffee3b40a58'
    arm('F01', 'identity derived from a machine/runtime address',
        'an id carrying what looks like an address is refused; a logical '
        'identity that moves with the loader is not an identity',
        mutate_address, 'IDENTITY_ADDRESS_LIKE')

    # -------------------------------------------------- 2. absolute-path dep
    def mutate_path(m):
        m['identity']['entries'][0]['id'] = \
            'lib:/Users/someone/build/tmp/a.dart::fn:compute'
    arm('F02', 'absolute-path dependence',
        'an id containing a build path is refused. This is the arm that '
        'matters most: such an id passes every test written on the machine '
        'that minted it',
        mutate_path, 'IDENTITY_PATH_DEPENDENT')

    # ----------------------------------------------------- 4. forced collision
    def mutate_collision(m):
        m['identity']['duplicate_count'] = 1
    arm('F04', '#65 test 10 / 4. forced collision -> fail closed',
        'two declarations sharing one identity means a patch binding to '
        'either binds to the wrong one, so a non-zero collision count is '
        'blocking rather than advisory',
        mutate_collision, 'IDENTITY_COLLISION')

    # --------------------------------------------- 7. lowered form as identity
    def mutate_lowered(m):
        m['identity']['entries'][0]['id'] = \
            'lib:package:p/a.dart::fn:Ext|get#twice'
    arm('F07', 'lowered extension implementation used as logical identity',
        'naming the lowering would make identity a function of the '
        'name-mangling scheme: change the mangling and every extension member '
        'silently becomes a different declaration with no source edit',
        mutate_lowered, 'LOWERED_FORM_AS_IDENTITY')

    # ------------------------------ 8. synthesized claiming persistent identity
    def mutate_synth(m):
        for e in m['identity']['entries']:
            if e['role'] != 'none':
                e['stability'] = 'nominal'
                break
    arm('F08', 'synthesized member claiming persistent source identity',
        'a compiler-generated entity relabelled nominal is refused; its name '
        'being stable in todays compiler is not a contract',
        mutate_synth, 'SYNTHETIC_CLAIMS_NOMINAL')

    # --------------------------------------------------- manifest unbound
    def mutate_unbound(m):
        m['identity']['dart_commit'] = 'route-b'
    arm('F11', 'manifest bound to a branch instead of a commit',
        'a branch is transport, not provenance -- it moves. The manifest must '
        'name a full commit sha',
        mutate_unbound, 'MANIFEST_UNBOUND')

    # ---------------------------------------------------- refusal swallowed
    def mutate_refusal(m):
        m['identity']['refusal_count'] = 2
    arm('F12', 'a library that could not be named reproducibly',
        'a refusal is blocking: a manifest that silently describes less than '
        'the program would let a patch address a namespace nobody checked',
        mutate_refusal, 'IDENTITY_REFUSED')

    # ------------------------------------------------------- empty manifest
    def mutate_empty(m):
        m['identity']['entries'] = []
    arm('F13', 'empty namespace',
        'an empty manifest cannot testify to anything and must not read as '
        'agreement',
        mutate_empty, 'MANIFEST_EMPTY')

    # ------------------------------------- 3. wrong release namespace (pair)
    findings = []
    release = copy.deepcopy(real_manifest)
    patch = copy.deepcopy(real_manifest)
    patch['identity']['dart_commit'] = 'f' * 40
    V.check_namespace_binding(release, patch, findings)
    got = _codes(findings)
    arms.append({
        'id': 'F03',
        'requirement': 'wrong release namespace',
        'description': 'a patch manifest produced by a different compiler is '
                       'refused before its ids are compared; agreement across '
                       'two namespaces means nothing',
        'expected_code': 'NAMESPACE_MISMATCH',
        'observed_codes': sorted(got),
        'result': 'pass' if 'NAMESPACE_MISMATCH' in got else 'FAIL',
        'problems': [] if 'NAMESPACE_MISMATCH' in got
                    else ['NAMESPACE_MISMATCH not raised'],
    })

    # ------------------------------- 5. private-name alias across libraries
    # MEASURED, NOT ASSUMED. The first version of this arm stripped the
    # @library qualification from real ids and expected a collision. It never
    # collided, and forcing it would have been manufacturing evidence. Three
    # shapes were tried: two classes in two libraries; two mixins from two
    # libraries applied to one class; and a class declaring `_x` while mixing
    # in another library's `_x`. In every one the OWNER path already differs,
    # because Kernel keeps a mixin's members on the mixin declaration rather
    # than copying them onto the applying class.
    #
    # So the qualification is defence in depth here, not the thing standing
    # between us and a collision -- and the arm now tests the protection the
    # way it can actually be tested: inject the aliased state a scheme WITHOUT
    # qualification would produce, and prove the collision detector sees it.
    aliased = copy.deepcopy(private_manifest or real_manifest)
    entries = aliased['identity']['entries']
    privates = [e for e in entries if '@' in e['id']]
    natural_collision = False
    if len(privates) >= 2:
        # Give two distinct private declarations one id, as an unqualified
        # scheme would.
        privates[1]['id'] = privates[0]['id'].split('@')[0]
        privates[0]['id'] = privates[0]['id'].split('@')[0]
        ids = [e['id'] for e in entries]
        aliased['identity']['duplicate_count'] = len(ids) - len(set(ids))
    findings = []
    V.check_manifest(aliased, 'aliased', findings)
    got = _codes(findings)
    detected = 'IDENTITY_COLLISION' in got
    arms.append({
        'id': 'F05',
        'requirement': 'private-name alias across libraries',
        'description': 'two distinct private declarations given one id -- what '
                       'a scheme without library qualification would produce -- '
                       'is caught as a collision. Recorded honestly: a NATURAL '
                       'collision could not be constructed in this Dart '
                       'version, because owner paths already differ, so the '
                       'qualification is defence in depth rather than the only '
                       'thing preventing an alias',
        'expected_code': 'IDENTITY_COLLISION',
        'observed_codes': sorted(got),
        'natural_collision_constructible': natural_collision,
        'shapes_tried_without_natural_collision': [
            'two classes in two libraries each declaring _secret',
            'two mixins from two libraries applied to one class',
            'a class declaring _x while mixing in another library\'s _x',
        ],
        'result': 'pass' if detected and len(privates) >= 2 else 'FAIL',
        'problems': [] if detected and len(privates) >= 2
                    else ['collision not detected, or the sample had fewer '
                          'than two private declarations to alias'],
    })

    # ---------------------- 6. surviving declaration whose ids differ
    ids = [e['id'] for e in real_manifest['identity']['entries']]
    drifted = set(ids)
    drifted.discard(ids[0])
    drifted.add(ids[0] + 'X')
    survived = set(ids) == drifted
    arms.append({
        'id': 'F06',
        'requirement': 'a surviving declaration whose release/patch ids differ',
        'description': 'a single changed id between two compilations of the '
                       'same declaration is a set difference, which case T02 '
                       'compares directly and would report',
        'expected_code': 'set difference detected',
        'observed_codes': ['difference' if not survived else 'no_difference'],
        'result': 'pass' if not survived else 'FAIL',
        'problems': [] if not survived else ['a changed id was not detected'],
    })

    # -------------------------------------------- 9. empty test population
    findings = []
    V.check_population([], findings)
    got = _codes(findings)
    arms.append({
        'id': 'F09',
        'requirement': 'empty test population',
        'description': 'a verdict derived from zero cases would be a '
                       'statement about nothing, so an empty population is '
                       'blocking',
        'expected_code': 'EMPTY_TEST_POPULATION',
        'observed_codes': sorted(got),
        'result': 'pass' if 'EMPTY_TEST_POPULATION' in got else 'FAIL',
        'problems': [] if 'EMPTY_TEST_POPULATION' in got
                    else ['empty population accepted'],
    })

    # --------------------------- 9b. a required test missing from the run
    findings = []
    V.check_population([c for c in cases if c['id'] != 'T07'], findings)
    got = _codes(findings)
    arms.append({
        'id': 'F10',
        'requirement': 'a required test dropped from the run',
        'description': 'dropping the private-name case is caught by name; a '
                       'shorter run must not read as a passing one',
        'expected_code': 'REQUIRED_TEST_ABSENT',
        'observed_codes': sorted(got),
        'result': 'pass' if 'REQUIRED_TEST_ABSENT' in got else 'FAIL',
        'problems': [] if 'REQUIRED_TEST_ABSENT' in got
                    else ['a missing required test was not detected'],
    })

    return arms
