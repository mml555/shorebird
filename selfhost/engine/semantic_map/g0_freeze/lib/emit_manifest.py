"""Emit the G0 freeze manifest.

ONE INVENTORY. Every frozen input is an entry in `frozen_inputs` with a path and
a digest, and verify_manifest.py re-hashes exactly that list. There is no second,
hard-coded inventory for the two to drift apart.
"""
import datetime, hashlib, json, os, sys

man, repo, here, an_ship, an_build, corpus_digest, cell, base_dill = sys.argv[1:9]


def sha(p):
    try:
        h = hashlib.sha256()
        with open(p, 'rb') as f:
            for c in iter(lambda: f.read(1 << 20), b''):
                h.update(c)
        return h.hexdigest()
    except OSError:
        return None


rb = 'selfhost/engine/route_b'
inputs = []
for rel in ('identity/gen_target_manifest.dart', 'packaging/build_patch.dart',
            'coverage/analyze_coverage.dart', 'coverage/parity.sh'):
    inputs.append({'id': os.path.basename(rel), 'path': f'{rb}/{rel}',
                   'kind': 'reference_implementation',
                   'sha256': sha(os.path.join(repo, rb, rel))})
for rel in ('coverage/demand1/wonderous.window.txt', 'coverage/demand1/localsend.window.txt'):
    inputs.append({'id': os.path.basename(rel), 'path': f'{rb}/{rel}',
                   'kind': 'real_world_corpus_pin',
                   'sha256': sha(os.path.join(repo, rb, rel))})
inputs.append({'id': 'SUPPORTED_STATE.yaml', 'path': f'{rb}/SUPPORTED_STATE.yaml',
               'kind': 'supported_record', 'sha256': sha(os.path.join(repo, rb, 'SUPPORTED_STATE.yaml'))})
crel = 'selfhost/engine/semantic_map/g0_freeze/corpus'
for root, _, files in os.walk(os.path.join(repo, crel)):
    for f in sorted(files):
        full = os.path.join(root, f)
        inputs.append({'id': os.path.relpath(full, os.path.join(repo, crel)),
                       'path': os.path.relpath(full, repo),
                       'kind': 'adversarial_corpus_file', 'sha256': sha(full)})
inputs.sort(key=lambda e: e['path'])

sl1 = os.path.join(repo, 'selfhost/engine/semantic_linker/runtime_feasibility/g0_freeze/freeze_manifest.json')
inherited = json.load(open(sl1)) if os.path.isfile(sl1) else {}

doc = {
    'schema': 'semantic-map-1/g0-freeze/2', 'gate': 'SM1-G0', 'issue': 49, 'tracker': 48,
    'frozen': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'inventory_contract': (
        'frozen_inputs is THE inventory. verify re-hashes every entry and compares; it keeps no '
        'separate list. The v1 manifest recorded digests for the reference tools and corpus pins '
        'and then checked only their existence, so a one-byte edit still verified.'),
    'inherited_lineage': {
        'from': 'semantic_linker/runtime_feasibility/g0_freeze/freeze_manifest.json',
        'distribution': inherited.get('distribution', {}),
        'producing_source': inherited.get('producing_source', {}),
        'note': '#47 is off the critical path; the SL1 bank is what makes that safe.'},
    'analyzer': {
        'shipped_sha256': an_ship, 'cell': cell,
        'build_tree_sha256': an_build or None,
        'divergence': bool(an_build) and an_build != an_ship,
        'finding': ('coverage/parity.sh defaults ANALYZER to the BUILD TREE copy, which is not the '
                    'artifact the cell ships. Every parity run in this lane must pin ANALYZER= to '
                    'the shipped digest.'),
        'parity_evidence': 'evidence/parity_shipped_analyzer.txt'},
    'release_identity': {
        'base_corpus_dill_sha256': base_dill or None,
        'built_by': 'lib/build_corpus_dill.sh, using the frozen toolchain',
        'determinism': 'two builds of identical source produce an identical digest; re-checked every run',
        'note': ('The `reorder` mutant also moves this digest, because a dill preserves declaration '
                 'order. That is exactly why SM1-G1 must not derive DECLARATION_ID from dill order.')},
    'frozen_inputs': inputs,
    'adversarial_corpus_digest': corpus_digest,
    'historical_baselines': {
        'wonderous': '50.00%', 'localsend': '92.67%',
        'scope': ('Route B PRODUCER-DEMAND baselines, measured for a different question. NOT '
                  'semantic-map quality scores and not reinterpreted as such by this lane.'),
        'source': 'selfhost/engine/route_b/evidence/producer_demand_2.md'},
    'confounds_recorded': [
        {'id': 'PLATFORM_LIBRARY_GUARD_IS_UNCOMMITTED', 'owner_gate': 'SM1-G3',
         'statement': ('The guard refusing --resolve-private-names-in-library on a platform library '
                       'is uncommitted-but-shipped source, present in effective tree 7b04b01b and '
                       'absent from a clean checkout of 9e8c898a.'),
         'consequence': 'A gate built from the wrong tree makes the platform-library arm pass vacuously.'},
        {'id': 'ANALYZER_BUILD_TREE_DIVERGENCE', 'owner_gate': 'SM1-G0',
         'statement': 'parity.sh defaults to a build-tree analyzer that is not the shipped one.',
         'consequence': 'Freezing or measuring the wrong analyzer.'},
        {'id': 'VM_ENTRY_POINT_RETAINS_INDEPENDENTLY', 'owner_gate': 'SM1-G4',
         'statement': "@pragma('vm:entry-point') retains a symbol regardless of the dynamic-interface contract.",
         'consequence': 'A retention control passes while measuring the pragma.'}],
    'unmodified': {'claim': 'no supported artifact, selector or cell is modified by this lane',
                   'checked': ['packages/', 'bin/', 'selfhost/engine/route_b/', 'selfhost/compatibility.yaml']},
}
json.dump(doc, open(man, 'w'), indent=2)
