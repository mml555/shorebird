#!/usr/bin/env python3
"""Swap each binding field independently and require a refusal for each.

TWO CONFOUNDS FROM SEMANTIC-LINKER-1, both handled explicitly.

1. CLASSIFICATION MUST NOT REST ON MESSAGE TEXT. Each arm asserts a stable
   CODE and CATEGORY from the verifier's structured output. No arm matches on
   prose.

2. AN IDENTITY ARM MUST PROVE THE TWO SIDES ACTUALLY DIFFER. SL1's
   wrong_runtime_build negative could not be reproduced because every build in
   that lane shared SNAPSHOT_HASH, so the arm passed without exercising
   anything. Every swap here asserts, before running the verifier, that the
   value it substituted differs from the release's own -- and refuses to count
   as a pass otherwise.

A THIRD TRAP, specific to this gate: after swapping a field the map's digest
must be RECOMPUTED. Otherwise every arm refuses with DIGEST_MISMATCH, the
identity comparison is never reached, and a verifier with no binding checks at
all would pass the whole suite. Arms that mean to test integrity re-digest
deliberately; arms that mean to test identity always re-digest.

usage: falsify_binding.py <mapA> <factsA> <mapB> <factsB> <workdir>
"""
import copy
import hashlib
import json
import os
import subprocess
import sys

MAP_A, FACTS_A, MAP_B, FACTS_B, W = sys.argv[1:6]
HERE = os.path.dirname(os.path.abspath(__file__))
# SM1_VERIFIER exists so this suite can be pointed at a deliberately weakened
# verifier and shown to FAIL. Arms that cannot fail prove nothing.
VERIFY = os.environ.get('SM1_VERIFIER', f'{HERE}/verify_binding.py')
A = json.load(open(MAP_A))
B = json.load(open(MAP_B))
FA = json.load(open(FACTS_A))
FB = json.load(open(FACTS_B))
results = []


def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(',', ':')).encode()


def redigest(m):
    m = copy.deepcopy(m)
    m.pop('digest', None)
    m['digest'] = hashlib.sha256(canonical(m)).hexdigest()
    return m


def run(label, m, facts, want_verdict, want_code=None, want_category=None,
        differs=None):
    """differs: (map_value, release_value) that the arm claims to have changed."""
    pre = []
    if differs is not None:
        got, want = differs
        if got == want:
            results.append((label, 'FAIL',
                            'the substituted value equals the release value, '
                            'so this arm exercises nothing'))
            return
        pre.append('sides differ')
    mp, fp = f'{W}/fx_map.json', f'{W}/fx_facts.json'
    if isinstance(m, (bytes, str)):
        open(mp, 'wb').write(m if isinstance(m, bytes) else m.encode())
    else:
        json.dump(m, open(mp, 'w'))
    json.dump(facts, open(fp, 'w'))
    p = subprocess.run([sys.executable, VERIFY, mp, fp, f'{W}/fx_out.json'],
                       capture_output=True, text=True)
    try:
        out = json.load(open(f'{W}/fx_out.json'))
    except Exception:                                     # noqa: BLE001
        results.append((label, 'FAIL', 'the verifier produced no output'))
        return
    bad = []
    if out['verdict'] != want_verdict:
        bad.append(f"verdict {out['verdict']}, expected {want_verdict}")
    if want_code and want_code not in out['codes']:
        bad.append(f'missing code {want_code}, got {out["codes"][:4]}')
    if want_category and want_category not in out['categories']:
        bad.append(f'missing category {want_category}, got {out["categories"]}')
    if want_verdict == 'REFUSED' and p.returncode == 0:
        bad.append('REFUSED but exit status 0')
    results.append((label, 'FAIL' if bad else 'pass',
                    '; '.join(bad) if bad
                    else ', '.join(pre + [f"{out['verdict']}"]
                                   + out['codes'][:2])))


# ---- baselines: both must BIND, or every arm below is vacuous -------------
run('BASELINE map A against release A', A, FA, 'BOUND')
run('BASELINE map B against release B', B, FB, 'BOUND')

# ---- the whole map presented against another release ---------------------
run('map A presented against release B', A, FB, 'REFUSED',
    'RELEASE_ID_MISMATCH', 'HOST_IDENTITY',
    differs=(A['release_id'], FB['release_id']))

# ---- each binding field, swapped INDEPENDENTLY and re-digested -----------
def swap(path, value):
    m = copy.deepcopy(A)
    node = m
    for k in path[:-1]:
        node = node[k]
    node[path[-1]] = value
    return redigest(m)


run('release_id swapped', swap(['release_id'], B['release_id']), FA,
    'REFUSED', 'RELEASE_ID_MISMATCH', 'HOST_IDENTITY',
    differs=(B['release_id'], FA['release_id']))
run('release_kernel_hash swapped',
    swap(['release_kernel_hash'], B['release_kernel_hash']), FA,
    'REFUSED', 'RELEASE_KERNEL_MISMATCH', 'HOST_IDENTITY',
    differs=(B['release_kernel_hash'], FA['release_kernel_hash']))
run('release_aot_identity.sha256 swapped',
    swap(['release_aot_identity', 'sha256'],
         B['release_aot_identity']['sha256']), FA,
    'REFUSED', 'RELEASE_AOT_MISMATCH', 'HOST_IDENTITY',
    differs=(B['release_aot_identity']['sha256'], FA['release_aot_sha256']))
for key, code in (('dart_revision', 'COMPILER_REVISION_MISMATCH'),
                  ('frozen_effective_tree', 'COMPILER_TREE_MISMATCH'),
                  ('gen_snapshot_sha256', 'COMPILER_SNAPSHOT_MISMATCH')):
    # All three releases share one compiler, so a different release cannot
    # supply a differing value -- a synthesized one is used, and the arm still
    # proves it differs from the release's own before it counts.
    forged = 'f' * 40
    run(f'flutter_dart_compiler_identities.{key} swapped',
        swap(['flutter_dart_compiler_identities', key], forged), FA,
        'REFUSED', code, 'HOST_IDENTITY',
        differs=(forged, FA['compiler'][key]))
run('generator_identity.generator_sha256 swapped',
    swap(['generator_identity', 'generator_sha256'], 'e' * 64), FA,
    'REFUSED', 'GENERATOR_MISMATCH', 'HOST_IDENTITY',
    differs=('e' * 64, FA['generator_sha256']))

# ---- the digest field itself, swapped independently ---------------------
# Distinct from "tampered content, stale digest": here the CONTENT is untouched
# and only the digest is replaced, so the arm exercises the digest comparison
# on its own rather than as a side effect of changing something else.
dg = copy.deepcopy(A)
dg['digest'] = B['digest']
run('digest swapped for another map\'s, content untouched', dg, FA,
    'REFUSED', 'DIGEST_MISMATCH', 'MODULE_INTEGRITY',
    differs=(B['digest'], A['digest']))
dg2 = copy.deepcopy(A)
dg2['digest'] = '0' * 64
run('digest replaced with a well-formed but wrong value', dg2, FA,
    'REFUSED', 'DIGEST_MISMATCH', 'MODULE_INTEGRITY',
    differs=('0' * 64, A['digest']))

# ---- defect 3's arm: a tool digest changed, then re-digested -------------
tl = copy.deepcopy(A)
tools = tl['generator_identity']['tools']
first = sorted(tools)[0]
tl['generator_identity']['tools'][first] = 'd' * 64
run(f'generator tool digest changed ({first}) and re-digested',
    redigest(tl), FA, 'REFUSED', 'GENERATOR_TOOLS_MISMATCH', 'HOST_IDENTITY',
    differs=('d' * 64, FA['generator_tools'][first]))
tl2 = copy.deepcopy(A)
tl2['generator_identity'].pop('tools')
run('generator tool digests removed entirely', redigest(tl2), FA,
    'REFUSED', 'GENERATOR_TOOLS_MISSING', 'MODULE_INTEGRITY')

# ---- defect 2's arms: schema_version type strictness --------------------
run('schema_version is JSON true, which Python equates with 1',
    redigest({**copy.deepcopy(A), 'schema_version': True}), FA,
    'REFUSED', 'SCHEMA_VERSION_NOT_AN_INTEGER', 'MODULE_INTEGRITY')
run('schema_version is 1.0, which Python equates with 1',
    redigest({**copy.deepcopy(A), 'schema_version': 1.0}), FA,
    'REFUSED', 'SCHEMA_VERSION_NOT_AN_INTEGER', 'MODULE_INTEGRITY')
run('schema_version is the string "1"',
    redigest({**copy.deepcopy(A), 'schema_version': '1'}), FA,
    'REFUSED', 'SCHEMA_VERSION_NOT_AN_INTEGER', 'MODULE_INTEGRITY')

# ---- a matching build id must not substitute for a matching digest -------
m = copy.deepcopy(A)
m['release_aot_identity']['sha256'] = B['release_aot_identity']['sha256']
run('build id matches but the AOT digest does not', redigest(m), FA,
    'REFUSED', 'RELEASE_AOT_MISMATCH', 'HOST_IDENTITY',
    differs=(B['release_aot_identity']['sha256'], FA['release_aot_sha256']))

# ---- similarity is not identity -----------------------------------------
# Release A and A' are the SAME kernel built twice: byte-identical declaration
# lists, different AOT. Exactly the case #55 names.
if len(sys.argv) > 6:
    FACTS_A2 = sys.argv[6]
    FA2 = json.load(open(FACTS_A2))
    run('map A against a REBUILD of the same source (identical declarations)',
        A, FA2, 'REFUSED', 'RELEASE_AOT_MISMATCH', 'HOST_IDENTITY',
        differs=(A['release_aot_identity']['sha256'], FA2['release_aot_sha256']))
    results.append(('  (that rebuild has identical declarations)',
                    'pass' if FA2.get('declarations_identical_to_a') else 'FAIL',
                    f"declarations_identical={FA2.get('declarations_identical_to_a')}"))

    # THE BUILD-ID COLLISION, ON REAL ARTIFACTS. The rebuild is not a
    # synthesised map combination: it is a second build of the same kernel that
    # genuinely shares release A's GNU build id while differing in sha256. That
    # is the collision G5 measured, and it is what makes "the build id is
    # recorded but never trusted" a demonstrated property rather than a stated
    # intention.
    id_a = A['release_aot_identity'].get('gnu_build_id')
    id_a2 = FA2.get('gnu_build_id')
    sha_a = A['release_aot_identity']['sha256']
    sha_a2 = FA2['release_aot_sha256']
    if id_a is None or id_a2 is None:
        results.append(('real build-id collision pair', 'FAIL',
                        'a build id could not be read from one side'))
    elif id_a != id_a2:
        results.append(('real build-id collision pair', 'FAIL',
                        f'build ids differ ({id_a[:12]} vs {id_a2[:12]}), so '
                        f'this pair does not exercise a collision'))
    elif sha_a == sha_a2:
        results.append(('real build-id collision pair', 'FAIL',
                        'the two artifacts have the same sha256, so there is '
                        'nothing for the digest check to catch'))
    else:
        results.append((
            'real pair: build_id_A == build_id_A2, sha256_A != sha256_A2',
            'pass', f'build_id={id_a[:16]} shared; digests differ'))
        # And the refusal must come from the DIGEST, not the build id.
        v = json.load(open(f'{W}/fx_out.json'))
        run('that real pair refuses on the digest, not the build id',
            A, FA2, 'REFUSED', 'RELEASE_AOT_MISMATCH', 'HOST_IDENTITY')
        last = json.load(open(f'{W}/fx_out.json'))
        results.append((
            '  and RELEASE_BUILD_ID_MISMATCH is absent (ids match)',
            'pass' if 'RELEASE_BUILD_ID_MISMATCH' not in last['codes'] else 'FAIL',
            f"codes={last['codes']}"))

# ---- integrity: unknown schema, corruption, tampering -------------------
run('schema_version unknown to this verifier',
    redigest({**copy.deepcopy(A), 'schema_version': 99}), FA,
    'REFUSED', 'SCHEMA_VERSION_UNSUPPORTED', 'MODULE_INTEGRITY')
run('schema_version absent',
    redigest({k: v for k, v in A.items() if k != 'schema_version'}), FA,
    'REFUSED', 'SCHEMA_VERSION_MISSING', 'MODULE_INTEGRITY')
tampered = copy.deepcopy(A)
tampered['declarations'] = tampered['declarations'][:-1]
run('map content tampered WITHOUT re-digesting', tampered, FA,
    'REFUSED', 'DIGEST_MISMATCH', 'MODULE_INTEGRITY')
run('digest absent', {k: v for k, v in A.items() if k != 'digest'}, FA,
    'REFUSED', 'DIGEST_MISSING', 'MODULE_INTEGRITY')
run('map bytes truncated', canonical(A)[:len(canonical(A)) // 2], FA,
    'REFUSED', 'MAP_UNPARSEABLE', 'MODULE_INTEGRITY')
run('map is not JSON at all', b'\xff\xfe not json', FA,
    'REFUSED', 'MAP_UNPARSEABLE', 'MODULE_INTEGRITY')

print(f'{"arm":62} {"result":6} detail')
print('-' * 116)
for label, verdict, detail in results:
    print(f'{label:62} {verdict:6} {detail}')
failed = [r for r in results if r[1] == 'FAIL']
print('-' * 116)
print(f'arms={len(results)} passed={len(results) - len(failed)} failed={len(failed)}')
print('SM1_G6_BINDING_FALSIFICATION: '
      + ('EVERY_SWAP_REFUSED' if not failed else 'DEFECTS_PRESENT'))
sys.exit(1 if failed else 0)
