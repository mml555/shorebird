#!/usr/bin/env python3
"""Collect every candidate module-validation SOURCE, with its properties.

The B0 verdict is a function of source roles, so this is where the facts about
each candidate come from. Nothing here decides anything; it records.

DISCOVERY IS NOT PATTERN MATCHING. A file carrying the permission keys is not a
release policy. An earlier version matched any such YAML, found four experiment
probe FIXTURES, and would have supported "derivable" on them. A candidate
counts as release-consumed only if a release or build script actually
references it, and the fixtures that fail that test are recorded with the
reason rather than dropped.

Each candidate that supplies all four sections is handed to the real validator
with the positive module, because "has the sections" and "validates the
release's own patch" are different claims -- and the second is the one B0
needs. The caller supplies the validation callback via a results file, so this
module stays free of build-tool paths.

usage: collect_sources.py <repo-root> <generated-spec> <generated-attempt-log>
                          <extra-attempts.json> <out.json>

  extra-attempts.json maps a discovered policy path to
  {"produced_module": bool} -- the runner fills it in after compiling.
"""
import hashlib
import json
import pathlib
import re
import sys

REPO = pathlib.Path(sys.argv[1])
GEN_SPEC = pathlib.Path(sys.argv[2])
GEN_ATTEMPT = pathlib.Path(sys.argv[3])
EXTRA = pathlib.Path(sys.argv[4])
OUT = sys.argv[5]

SECTIONS = ['callable', 'extendable', 'can-be-overridden',
            'can-be-used-as-type']
PERMISSION_KEYS = r'^\s*(extendable|can-be-overridden|can-be-used-as-type)\s*:'


def sections_in(text):
    return {s: bool(re.search(rf'^{re.escape(s)}:', text, re.M))
            for s in SECTIONS}


def read(p):
    try:
        return p.read_text(errors='replace')
    except Exception:                                        # noqa: BLE001
        return None


def sha(p):
    try:
        return hashlib.sha256(p.read_bytes()).hexdigest()
    except Exception:                                        # noqa: BLE001
        return None


# ---- which scripts count as release/build consumers -------------------
RELEASE_SCRIPTS = sorted(
    set(REPO.glob('selfhost/engine/route_b/build_*.sh'))
    | set(REPO.glob('selfhost/engine/route_b/release*.sh'))
    | set(REPO.glob('scripts/*.sh')))
script_text = ''
for sc in RELEASE_SCRIPTS:
    t = read(sc)
    if t:
        script_text += t

sources = {}

# ---- 1. the retention generator ---------------------------------------
gen_text = read(GEN_SPEC)
attempt = read(GEN_ATTEMPT)
sources['route_b_generator'] = {
    'what': 'selfhost/engine/route_b/gen_dynamic_interface.dart, run on the '
            "release's own kernel under a named --policy",
    'release_bound': True,
    'release_consumed': True,
    'why_release_bound': 'reads the release kernel (--dill); the same release '
                         'and policy give the same specification',
    'spec_path': str(GEN_SPEC),
    'spec_sha256': sha(GEN_SPEC),
    'sections': sections_in(gen_text) if gen_text is not None
    else {s: None for s in SECTIONS},
    'validated_positive': bool(
        attempt and re.search(r'^produced=yes', attempt, re.M)),
    'refusal_kinds': {
        'extendable': len(re.findall(
            r'Cannot extend, implement or mix-in class', attempt or '')),
        'can-be-overridden': len(re.findall(
            r'Cannot override member', attempt or '')),
        'can-be-used-as-type': len(re.findall(
            r'Cannot use class .* as a type', attempt or '')),
        'callable': len(re.findall(r'Cannot invoke member', attempt or '')),
    },
}

# ---- 2. any declared policy a release build consumes ------------------
try:
    extra = json.loads(EXTRA.read_text())
except Exception:                                            # noqa: BLE001
    extra = {}

containing, excluded = [], []
for g in ('selfhost/*.yaml', 'selfhost/**/*.yaml', 'packages/**/*.yaml'):
    for p in sorted(REPO.glob(g)):
        if not p.is_file() or p.name.endswith('.patch'):
            continue
        t = read(p)
        if t and re.search(PERMISSION_KEYS, t, re.M):
            rel = str(p.relative_to(REPO))
            if p.name in script_text:
                containing.append(rel)
            else:
                excluded.append(rel)

for rel in containing:
    p = REPO / rel
    t = read(p) or ''
    sources[f'declared_policy:{rel}'] = {
        'what': f'{rel}, a declared policy referenced by a release build',
        'release_bound': True,
        'release_consumed': True,
        'spec_path': rel,
        'spec_sha256': sha(p),
        'sections': sections_in(t),
        'validated_positive': bool(
            extra.get(rel, {}).get('produced_module')),
    }

# An excluded file that is NOT under a probe/evidence/fixture path is worth
# naming as a source rather than leaving in a list, so its role is COMPUTED.
# selfhost/engine/dynmod/di.yaml is one: a hand-written harness policy carrying
# three of the four sections. It is not release-consumed, so it comes out
# `unusable` -- but that is a derived answer, and it also records the useful
# fact that a permission surface CAN be written. Nothing derives or ships one.
FIXTURE_MARKERS = ('/probe/', '/evidence/', '/fixture')
for rel in excluded:
    if any(m in f'/{rel}' for m in FIXTURE_MARKERS):
        continue
    p = REPO / rel
    t = read(p) or ''
    sources[f'unconsumed_policy:{rel}'] = {
        'what': f'{rel}, a hand-written policy outside any probe directory',
        # NOT release-bound. Marking it so was a modelling error: it is a
        # static file naming a harness app's own library, not something
        # determined by a release, so re-running a release cannot reproduce it
        # and a different release would get the same stale policy. That is
        # exactly what "deterministic, release-bound" excludes -- and with it
        # wrongly marked bound, its three sections made the count of
        # unsourced sections read 1 instead of 3.
        'release_bound': False,
        'release_consumed': False,
        'spec_path': rel,
        'spec_sha256': sha(p),
        'sections': sections_in(t),
        'validated_positive': False,
        'why_unusable': 'neither release-bound nor release-consumed: a static '
                        'hand-written file naming a harness app, which no '
                        'release or build script references. It does show a '
                        'permission surface can be WRITTEN by hand -- what '
                        'does not exist is anything that DERIVES one from a '
                        'release.',
    }

# ---- 3. the semantic map's admitted set -------------------------------
sub = REPO / 'selfhost/engine/semantic_map/g5_patchability/evidence/subset.json'
admitted, verdict = None, None
try:
    _s = json.loads(sub.read_text())
    admitted, verdict = _s['predicted_patchable'], _s['verdict']
except Exception:                                            # noqa: BLE001
    pass
sources['semantic_map_admitted_set'] = {
    'what': "SEMANTIC-MAP-1's set of declarations established safely patchable",
    'release_bound': True,
    'release_consumed': False,
    # No sections: a set of declarations is not a specification until
    # something converts it into one. A nonzero count is not a conversion,
    # which is why `sections` stays empty rather than being inferred from it.
    'sections': {s: False for s in SECTIONS},
    'validated_positive': False,
    'admitted': admitted,
    'map_verdict': verdict,
    'why_unusable': (
        f'admits {admitted} declarations and no converter to a validation '
        'specification exists. Even a nonzero count would not make it a '
        'source without a converter whose output is demonstrated to validate.'),
}

# ---- 4. the module itself: permanently ineligible ---------------------
sources['the_module_itself'] = {
    'what': 'reading the required permissions off the patch being validated',
    'release_bound': False,
    'release_consumed': False,
    'permanently_ineligible': True,
    'sections': {s: True for s in SECTIONS},
    'validated_positive': True,
    'why_unusable': (
        'it would permit whatever the patch does, so validation would refuse '
        'nothing. Recorded with every property SATISFIED on purpose: if the '
        'role rule can be talked into promoting it, that is a defect the '
        'record should expose rather than hide.'),
}

json.dump({
    'schema': 'route-b-di-1/b0-sources/1',
    'sources': sources,
    'discovery': {
        'permission_key_pattern': PERMISSION_KEYS,
        'release_scripts_searched': [str(x.relative_to(REPO))
                                     for x in RELEASE_SCRIPTS],
        'referenced_by_a_release_build': containing,
        'excluded_as_experiment_fixtures': excluded,
        'excluded_under_a_probe_or_evidence_path': [
            r for r in excluded
            if any(m in f'/{r}' for m in ('/probe/', '/evidence/',
                                          '/fixture'))],
        'excluded_elsewhere_named_as_sources': [
            r for r in excluded
            if not any(m in f'/{r}' for m in ('/probe/', '/evidence/',
                                              '/fixture'))],
        'why_excluded': 'they carry the permission keys but no release or '
                        'build script references them, so counting them would '
                        'let a test input pass as production policy',
    },
}, open(OUT, 'w'), indent=2)

for name, s in sources.items():
    sup = sorted(k for k, v in (s['sections'] or {}).items() if v)
    print(f'  {name}\n    sections={sup or "none"} '
          f'consumed={s.get("release_consumed")} '
          f'validated={s.get("validated_positive")}')
print(f'  discovered release-consumed policies: {containing or "none"}')
print(f'  excluded fixtures: {len(excluded)}')
