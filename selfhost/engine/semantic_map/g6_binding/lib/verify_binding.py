#!/usr/bin/env python3
"""Verify a semantic map against the release it is presented with.

A map describes ONE release. Presenting it against another must refuse even if
the declarations look similar -- similarity is not identity.

STRUCTURED CATEGORIES, reusing SEMANTIC-LINKER-1's vocabulary:

    HOST_IDENTITY      the map does not belong to this release: release id,
                       kernel hash, AOT digest, or compiler identity differs
    MODULE_INTEGRITY   the map itself cannot be trusted: unknown schema
                       version, missing field, or digest mismatch

SL1's finding is carried forward: CLASSIFICATION MUST NOT RELY ON THE ERROR
STRING. SL1 saw corrupt bytecode report as "Unable to find class ° in
Library:'dart:core'" -- an import-resolution message for an integrity cause. So
every refusal here is decided on a structured field comparison and carries a
stable code plus its category; the human-readable text is derived from the
comparison, never parsed to produce it.

An unknown schema_version REFUSES rather than degrading: a map written to a
contract this verifier does not implement cannot be partially honoured.

usage: verify_binding.py <map.json> <release-facts.json> <out.json>
"""
import hashlib
import json
import sys

SUPPORTED_SCHEMA_VERSIONS = (1,)

MAP, FACTS, OUT = sys.argv[1], sys.argv[2], sys.argv[3]

findings = []


def refuse(code, category, detail):
    findings.append({'code': code, 'category': category, 'detail': detail})


def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(',', ':')).encode()


try:
    m = json.load(open(MAP))
except Exception as ex:                                   # noqa: BLE001
    # A map that will not parse is an integrity failure, decided structurally
    # (the parse raised) rather than by inspecting any message.
    m = None
    refuse('MAP_UNPARSEABLE', 'MODULE_INTEGRITY',
           f'{type(ex).__name__} while reading the map')

facts = json.load(open(FACTS))

if m is not None:
    # ---- schema, before anything else is interpreted --------------------
    sv = m.get('schema_version')
    if sv is None:
        refuse('SCHEMA_VERSION_MISSING', 'MODULE_INTEGRITY',
               'the map declares no schema_version')
    elif sv not in SUPPORTED_SCHEMA_VERSIONS:
        refuse('SCHEMA_VERSION_UNSUPPORTED', 'MODULE_INTEGRITY',
               f'schema_version={sv!r}; this verifier implements '
               f'{list(SUPPORTED_SCHEMA_VERSIONS)}')

    # ---- integrity of the map's own content ------------------------------
    declared = m.get('digest')
    if declared is None:
        refuse('DIGEST_MISSING', 'MODULE_INTEGRITY', 'the map carries no digest')
    else:
        recomputed = hashlib.sha256(
            canonical({k: v for k, v in m.items() if k != 'digest'})).hexdigest()
        if recomputed != declared:
            refuse('DIGEST_MISMATCH', 'MODULE_INTEGRITY',
                   f'declared {declared[:16]}..., recomputed {recomputed[:16]}...')

    # ---- binding to THIS release ----------------------------------------
    # Each field is compared on its own so a swap of any one of them refuses,
    # and each comparison records both sides so an arm can prove they differ.
    def bind(field, code, got, want):
        if got is None:
            refuse(f'{code}_MISSING', 'MODULE_INTEGRITY',
                   f'the map carries no {field}')
        elif got != want:
            refuse(code, 'HOST_IDENTITY',
                   f'{field}: map says {str(got)[:24]}..., '
                   f'release is {str(want)[:24]}...')

    bind('release_id', 'RELEASE_ID_MISMATCH',
         m.get('release_id'), facts['release_id'])
    bind('release_kernel_hash', 'RELEASE_KERNEL_MISMATCH',
         m.get('release_kernel_hash'), facts['release_kernel_hash'])

    aot = m.get('release_aot_identity') or {}
    # IDENTITY IS THE DIGEST. The build id is compared too, but a matching
    # build id can never substitute for a matching digest -- G5 measured that
    # two different AOTs can share one.
    bind('release_aot_identity.sha256', 'RELEASE_AOT_MISMATCH',
         aot.get('sha256'), facts['release_aot_sha256'])
    if (aot.get('gnu_build_id') is not None
            and facts.get('gnu_build_id') is not None
            and aot['gnu_build_id'] != facts['gnu_build_id']):
        refuse('RELEASE_BUILD_ID_MISMATCH', 'HOST_IDENTITY',
               'the recorded GNU build id differs from this release')

    ci = m.get('flutter_dart_compiler_identities') or {}
    for key, code in (('dart_revision', 'COMPILER_REVISION_MISMATCH'),
                      ('frozen_effective_tree', 'COMPILER_TREE_MISMATCH'),
                      ('gen_snapshot_sha256', 'COMPILER_SNAPSHOT_MISMATCH')):
        bind(f'flutter_dart_compiler_identities.{key}', code,
             ci.get(key), facts['compiler'][key])

    gi = m.get('generator_identity') or {}
    bind('generator_identity.generator_sha256', 'GENERATOR_MISMATCH',
         gi.get('generator_sha256'), facts['generator_sha256'])

verdict = 'BOUND' if not findings else 'REFUSED'
categories = sorted({f['category'] for f in findings})
out = {
    'schema': 'semantic-map-1/g6-binding/1',
    'gate': 'SM1-G6', 'issue': 55,
    'map': MAP,
    'release': facts.get('release_name'),
    'verdict': verdict,
    'categories': categories,
    'codes': [f['code'] for f in findings],
    'findings': findings,
    'classified_from': 'structured field comparison, not message text',
}
json.dump(out, open(OUT, 'w'), indent=2)

print(f'  verdict {verdict}')
for f in findings:
    print(f'    {f["category"]:16} {f["code"]:32} {f["detail"][:60]}')
sys.exit(1 if findings else 0)
