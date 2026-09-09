#!/usr/bin/env python3
"""B0: can Route B mechanically derive a COMPLETE, release-bound
module-validation specification?

#61's B0 boundary. Stage A proved the existing validator refuses real
violations, so the mechanism works. It also proved di_full.yaml is not a
module-validation specification. B0 asks the next question and refuses to
answer it from memory: for a target release, is there a deterministic,
release-bound source for the COMPLETE specification -- with a digest, the
release/AOT identity, the Dart/cell identity, the derivation identity, and an
explicit relationship to the host policy?

A module-validation specification has FOUR sections, and the validator enforces
all four independently (dynamic_interface_annotator.dart annotates each). So
"complete" means every section a real patch needs has a source.

THE ONE THING THIS MUST NOT DO. The missing sections cannot be derived from the
MODULE. `extendable`, `can-be-overridden` and `can-be-used-as-type` say what a
patch is PERMITTED to do to the host; reading them off the patch would permit
whatever that patch happens to do, and validation would refuse nothing. That is
not a conservative approximation -- it is the vacuous case, and it would make
this whole prerequisite unclosable while appearing closed. So a candidate
source only counts if it is release-side.

usage: derive_validation_input.py <generated-spec> <validate-attempt-log> \
                                  <repo-root> <freeze-manifest> <out.json>
"""
import datetime
import hashlib
import json
import pathlib
import re
import subprocess
import sys

GEN_SPEC = pathlib.Path(sys.argv[1])
ATTEMPT = pathlib.Path(sys.argv[2])
REPO = pathlib.Path(sys.argv[3])
FREEZE = pathlib.Path(sys.argv[4])
OUT = sys.argv[5]

notes = []
SECTIONS = ['callable', 'extendable', 'can-be-overridden',
            'can-be-used-as-type']


def read(p, what):
    try:
        return p.read_text(errors='replace')
    except Exception as ex:                                  # noqa: BLE001
        notes.append(f'{what}: unreadable -- {type(ex).__name__}')
        return None


spec_text = read(GEN_SPEC, 'generated specification')
attempt = read(ATTEMPT, 'validation attempt log')

# ---- what the release-bound generator actually emits -------------------
emitted = {}
if spec_text is not None:
    for s in SECTIONS:
        emitted[s] = bool(re.search(rf'^{re.escape(s)}:', spec_text, re.M))
else:
    emitted = {s: None for s in SECTIONS}

# ---- what the validator refused when handed that spec -----------------
VIOLATION_KINDS = {
    'extendable': r'Cannot extend, implement or mix-in class',
    'can-be-overridden': r'Cannot override member',
    'can-be-used-as-type': r'Cannot use class .* as a type',
    'callable': r'Cannot invoke member',
}
refused_kinds = {}
if attempt is not None:
    for section, pat in VIOLATION_KINDS.items():
        refused_kinds[section] = len(re.findall(pat, attempt))
else:
    refused_kinds = {s: None for s in VIOLATION_KINDS}
attempt_produced_module = bool(
    attempt is not None and re.search(r'^produced=yes', attempt, re.M))

# ---- candidate release-side sources, checked not assumed --------------
def grep_repo(pattern, globs):
    hits = []
    for g in globs:
        for p in sorted(REPO.glob(g)):
            if p.is_file() and not p.name.endswith('.patch'):
                try:
                    if re.search(pattern, p.read_text(errors='replace')):
                        hits.append(str(p.relative_to(REPO)))
                except Exception:                            # noqa: BLE001
                    pass
    return hits


candidates = {}
candidates['route_b_generator'] = {
    'what': 'selfhost/engine/route_b/gen_dynamic_interface.dart',
    'release_bound': True,
    'why_release_bound': 'reads the release kernel (--dill) under a named '
                         '--policy, so the same release and policy give the '
                         'same specification',
    'sections_it_supplies': [s for s, v in emitted.items() if v],
    'sections_it_does_not_supply': [s for s, v in emitted.items() if v is False],
}
# A file containing these keys is not automatically a release policy. The
# first version of this check matched four experiment probe/ FIXTURES and
# concluded a declared policy exists -- which would have wrongly supported
# "derivable". A release-side policy is one a RELEASE BUILD consumes, so that
# is what is tested: the candidate must be referenced by a script that builds
# or releases, not merely contain the right keys.
PERMISSION_KEYS = r'^\s*(extendable|can-be-overridden|can-be-used-as-type)\s*:'
containing = grep_repo(PERMISSION_KEYS,
                       ['selfhost/*.yaml', 'selfhost/**/*.yaml',
                        'packages/**/*.yaml'])
RELEASE_SCRIPTS = sorted(
    set(REPO.glob('selfhost/engine/route_b/build_*.sh'))
    | set(REPO.glob('selfhost/engine/route_b/release*.sh'))
    | set(REPO.glob('scripts/*.sh')))
script_text = ''
for sc in RELEASE_SCRIPTS:
    try:
        script_text += sc.read_text(errors='replace')
    except Exception:                                        # noqa: BLE001
        pass
consumed = [c for c in containing if pathlib.Path(c).name in script_text]
excluded = [c for c in containing if c not in consumed]
candidates['declared_release_policy'] = {
    'what': 'a release-side declaration of what a patch may extend, override '
            'or use as a type, CONSUMED by a release build',
    'release_bound': True,
    'files_containing_the_keys': containing,
    'referenced_by_a_release_build': consumed,
    'excluded_as_experiment_fixtures': excluded,
    'why_excluded': 'these contain the permission keys but no release or '
                    'build script references them: they are experiment '
                    'fixtures, and counting them would let a test input pass '
                    'as production policy',
    'release_scripts_searched': [str(x.relative_to(REPO))
                                 for x in RELEASE_SCRIPTS],
    'exists': bool(consumed),
}
sub = REPO / 'selfhost/engine/semantic_map/g5_patchability/evidence/subset.json'
admitted = None
try:
    _s = json.loads(sub.read_text())
    admitted = _s['predicted_patchable']
    sub_verdict = _s['verdict']
except Exception as ex:                                      # noqa: BLE001
    sub_verdict = f'unreadable ({type(ex).__name__})'
    notes.append('semantic-map subset.json unreadable')
candidates['semantic_map_admitted_set'] = {
    'what': "SEMANTIC-MAP-1's set of declarations established safely patchable",
    'release_bound': True,
    'admitted': admitted,
    'verdict': sub_verdict,
    'usable': bool(admitted),
    'why_not': 'the map admits none, so it cannot name a permitted surface. '
               'FINAL classified MODIFY_MAP_DESIGN for that reason.',
}
candidates['the_module_itself'] = {
    'what': 'reading the required permissions off the patch being validated',
    'release_bound': False,
    'usable': False,
    'why_not': 'it would permit whatever the patch does, so validation would '
               'refuse nothing. Not a conservative approximation -- the '
               'vacuous case, which would make this prerequisite appear '
               'closed while enforcing nothing.',
}

def is_usable(v):
    """Explicit, because the first version relied on `and`/`or` precedence
    across three clauses and called a non-release-bound candidate usable."""
    if not v.get('release_bound'):
        return False
    if v.get('usable') is False:
        return False
    return bool(v.get('sections_it_supplies') or v.get('exists')
                or v.get('usable'))


usable = sorted(k for k, v in candidates.items() if is_usable(v))
missing_sections = [s for s, v in emitted.items() if v is False]

# ---- the provenance #61 requires --------------------------------------
prov = {}
if spec_text is not None:
    prov['specification_sha256'] = hashlib.sha256(
        GEN_SPEC.read_bytes()).hexdigest()
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
        'sha256': hashlib.sha256(gen.read_bytes()).hexdigest(),
    }
prov['release_aot_identity'] = (
    'obtainable -- G6 already binds a map to the full AOT SHA-256, and the '
    'same binding applies here. Recorded as available rather than collected, '
    'because there is no complete specification to bind yet.')
prov['relationship_to_host_policy'] = (
    'the generated specification IS the host policy: the same file is passed '
    'to gen_kernel --dynamic-interface for retention. A validation '
    'specification would have to be that file plus the three permission '
    'sections, and widening the host half is not free -- the annotator '
    'annotates all four sections, and whole-library dart:core retention was '
    'measured at +310%.')

# ---- the B0 verdict ---------------------------------------------------
if spec_text is None or attempt is None:
    b0 = 'B0_EVIDENCE_MISSING'
elif not missing_sections and attempt_produced_module:
    b0 = 'COMPLETE_SPECIFICATION_DERIVABLE'
else:
    b0 = 'VALIDATION_INPUT_UNDERIVED'

doc = {
    'schema': 'route-b-di-1/stage-b0/1',
    'issue': 61, 'stage': 'B0',
    'generated': datetime.datetime.now(datetime.timezone.utc)
                 .strftime('%Y-%m-%dT%H:%M:%SZ'),
    'question': 'Is there a deterministic, release-bound source for a '
                'COMPLETE module-validation specification?',
    'b0_result': b0,
    'sections_required': SECTIONS,
    'sections_emitted_by_release_generator': emitted,
    'sections_missing': missing_sections,
    'validator_refusal_kinds_against_generated_spec': refused_kinds,
    'generated_spec_produced_a_module': attempt_produced_module,
    'candidate_sources': candidates,
    'usable_sources': usable,
    'provenance_available': prov,
    'notes': notes,
    'does_not_claim':
        'That the validator is insufficient. Stage A showed it refuses real '
        'violations and accepts a complete specification, including with '
        'MEMBER-scoped dart:core entries rather than whole-library ones. The '
        'gap measured here is the INPUT, not the mechanism.',
}
json.dump(doc, open(OUT, 'w'), indent=2)

w = sys.stdout.write
w('  SECTIONS a module-validation specification needs, and who supplies them\n')
for s in SECTIONS:
    v = emitted[s]
    w(f'    {"emitted" if v else "MISSING" if v is False else "unknown":8} '
      f'{s:22} refusals when absent: {refused_kinds.get(s)}\n')
w(f'\n  the release generator emitted a module: {attempt_produced_module}\n')
w('\n  CANDIDATE RELEASE-SIDE SOURCES\n')
for k, v in candidates.items():
    mark = 'usable' if k in usable else 'no'
    w(f'    {mark:7} {k}\n')
    if v.get('why_not'):
        w(f'            {v["why_not"]}\n')
w(f'\n  provenance fields available: {sorted(prov)}\n')
if notes:
    w(f'  notes: {notes}\n')
w(f'\nB0: {b0}\n')
sys.exit(0 if b0 == 'COMPLETE_SPECIFICATION_DERIVABLE' else 1)
