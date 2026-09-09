#!/usr/bin/env python3
"""Falsify the B0 classifier, in BOTH directions.

The first version tested only a hard-coded VALIDATION_INPUT_UNDERIVED control
and never left the retention generator incomplete while introducing a separate
complete release-side source -- so it could not have detected that the verdict
ignored the candidate sources entirely. That was the decisive defect, and these
arms exist to make it impossible to reintroduce.

The two counterfactuals the ruling requires:

  generator stays callable-only, a synthetic release-consumed COMPLETE policy
  appears                                     -> the verdict must MOVE
  that source is removed again                -> UNDERIVED must return

Both weakened classifiers are controlled: one hard-coding UNDERIVED and one
hard-coding DERIVABLE. A single-direction control cannot catch a verdict that
is pinned the other way.

usage: falsify_b0.py <derive_tool> <sources.json> <repo-root> <freeze> <workdir>
"""
import copy
import json
import pathlib
import shutil
import subprocess
import sys

TOOL = pathlib.Path(sys.argv[1])
SOURCES = pathlib.Path(sys.argv[2])
REPO = pathlib.Path(sys.argv[3])
FREEZE = pathlib.Path(sys.argv[4])
W = pathlib.Path(sys.argv[5])
if W.exists():
    shutil.rmtree(W)
W.mkdir(parents=True)

SECTIONS = ['callable', 'extendable', 'can-be-overridden',
            'can-be-used-as-type']
base = json.loads(SOURCES.read_text())


def run(doc, tool=TOOL):
    src, out = W / 'sources.json', W / 'b0.json'
    if out.exists():
        out.unlink()
    src.write_text(json.dumps(doc))
    subprocess.run([sys.executable, str(tool), str(src), str(REPO),
                    str(FREEZE), str(out)], capture_output=True, text=True)
    if not out.exists():
        return None
    try:
        return json.load(open(out))
    except Exception:                                        # noqa: BLE001
        return None


def mutate(fn):
    d = copy.deepcopy(base)
    fn(d['sources'])
    return d


COMPLETE_POLICY = {
    'what': 'a synthetic release-consumed policy carrying all four sections',
    'release_bound': True,
    'release_consumed': True,
    'spec_path': 'selfhost/synthetic_release_policy.yaml',
    'spec_sha256': 'f' * 64,
    'sections': {s: True for s in SECTIONS},
    'validated_positive': True,
}


def generator_is_callable_only(srcs):
    """The state the real run is in: the production release-supplement
    interface supplies one section of four."""
    srcs['release_supplement_interface']['sections'] = {
        s: (s == 'callable') for s in SECTIONS}
    srcs['release_supplement_interface']['validated_positive'] = False


ARMS = [
 # ---- the two counterfactuals the ruling names --------------------------
 ('separate-complete-source-while-generator-stays-partial',
  lambda s: (generator_is_callable_only(s),
             s.__setitem__('declared_policy:synthetic', dict(COMPLETE_POLICY))),
  lambda d: (d['b0_result'] == 'COMPLETE_SPECIFICATION_DERIVABLE'
             and d['complete_sources'] == ['declared_policy:synthetic']
             and d['source_roles']['release_supplement_interface']['role'] == 'partial'),
  'THE decisive arm. The retention generator is left callable-only and an '
  'independent complete release-consumed policy appears. The verdict must '
  'move -- the previous version would have said UNDERIVED regardless.'),

 ('remove-that-source-and-underived-returns',
  lambda s: generator_is_callable_only(s),
  lambda d: (d['b0_result'] == 'VALIDATION_INPUT_UNDERIVED'
             and d['complete_sources'] == []),
  'With the synthetic source gone the answer must return to UNDERIVED, so the '
  'previous arm is not simply a classifier that always says DERIVABLE.'),

 # ---- partial must not be mistaken for complete ------------------------
 ('generator-completed-but-not-validated',
  lambda s: (s['release_supplement_interface'].__setitem__(
                 'sections', {x: True for x in SECTIONS}),
             s['release_supplement_interface'].__setitem__(
                 'validated_positive', False)),
  lambda d: (d['b0_result'] == 'VALIDATION_INPUT_UNDERIVED'
             and d['source_roles']['release_supplement_interface']['role'] == 'unusable'),
  'All four sections present is not enough: a specification that does not '
  'validate the release patch is not a usable validation input.'),

 ('complete-source-not-release-consumed',
  lambda s: (generator_is_callable_only(s),
             s.__setitem__('declared_policy:orphan',
                           {**COMPLETE_POLICY, 'release_consumed': False})),
  lambda d: (d['b0_result'] == 'VALIDATION_INPUT_UNDERIVED'
             and d['source_roles']['declared_policy:orphan']['role']
             == 'unusable'),
  'A complete specification no release build consumes is not a production '
  'input -- this is the experiment-fixture case, at the role level.'),

 ('complete-source-not-release-bound',
  lambda s: (generator_is_callable_only(s),
             s.__setitem__('declared_policy:floating',
                           {**COMPLETE_POLICY, 'release_bound': False})),
  lambda d: d['b0_result'] == 'VALIDATION_INPUT_UNDERIVED',
  'Not release-bound means the same release could get a different '
  'specification, which is what "deterministic, release-bound" excludes.'),

 # ---- the permanently ineligible source --------------------------------
 ('module-derived-permissions-stay-ineligible',
  lambda s: (generator_is_callable_only(s),
             s['the_module_itself'].__setitem__('release_bound', True),
             s['the_module_itself'].__setitem__('release_consumed', True)),
  lambda d: (d['source_roles']['the_module_itself']['role'] == 'ineligible'
             and d['b0_result'] == 'VALIDATION_INPUT_UNDERIVED'),
  'Every property flipped in its favour and it must STILL be ineligible: '
  'reading permissions off the patch would refuse nothing, and no evidence '
  'promotes that.'),

 ('semantic-map-nonzero-is-not-a-conversion',
  lambda s: (generator_is_callable_only(s),
             s['semantic_map_admitted_set'].__setitem__('admitted', 4211)),
  lambda d: (d['source_roles']['semantic_map_admitted_set']['role']
             == 'unusable'
             and d['b0_result'] == 'VALIDATION_INPUT_UNDERIVED'),
  'A nonzero admitted count is not a specification. Without a converter whose '
  'output validates, the map is not a source however much it admits.'),

 # ---- discovery reach: a source behind a non-build_* consumer ----------
 ('complete-source-behind-a-publish-consumer',
  lambda s: (generator_is_callable_only(s),
             s.__setitem__('declared_policy:via_publish', {
                 **COMPLETE_POLICY,
                 'what': 'a complete policy reached through '
                         'publish_4b_patch.sh, a production consumer that no '
                         'build_* glob would have found',
                 'consumers': ['selfhost/engine/route_b/publish_4b_patch.sh'],
                 'consumer_tiers': ['reachable']})),
  lambda d: (d['b0_result'] == 'COMPLETE_SPECIFICATION_DERIVABLE'
             and 'declared_policy:via_publish' in d['complete_sources']),
  'The ruling required this: a complete source consumed through a production '
  'path outside build_* must be found and must move the verdict. The old '
  'three-glob universe could not have seen a publish_ consumer at all.'),

 ('remove-the-publish-consumer-source-and-underived-returns',
  lambda s: generator_is_callable_only(s),
  lambda d: (d['b0_result'] == 'VALIDATION_INPUT_UNDERIVED'
             and d['complete_sources'] == []),
  'And removing it must restore UNDERIVED, so the previous arm is not a '
  'classifier that says DERIVABLE whenever any extra source appears.'),

 # ---- evidence integrity ----------------------------------------------
 ('sources-record-unreadable',
  None,
  lambda d: d['b0_result'] == 'B0_EVIDENCE_MISSING',
  'No sources to inspect is not the same as no complete source existing, and '
  'must not be reported as the latter.'),
]

print('ROUTE-B-DI-1 / B0 -- classifier falsification, both directions')
print(f'  {len(ARMS)} arms.\n')
baseline = run(base)
if baseline is None:
    raise SystemExit('  baseline produced nothing')
print(f'  baseline: {baseline["b0_result"]}')
print(f'  roles: ' + ', '.join(
    f'{k}={v["role"]}' for k, v in sorted(baseline['source_roles'].items())))
print()

failed = []
results = {}
for name, mut, check, why in ARMS:
    if mut is None:
        out = W / 'b0.json'
        if out.exists():
            out.unlink()
        subprocess.run([sys.executable, str(TOOL), str(W / 'nope.json'),
                        str(REPO), str(FREEZE), str(out)],
                       capture_output=True, text=True)
        d = json.load(open(out)) if out.exists() else None
    else:
        d = run(mutate(mut))
    ok = d is not None and bool(check(d))
    results[name] = d['b0_result'] if d else 'NO-OUTPUT'
    if not ok:
        failed.append(name)
    print(f'  {"pass" if ok else "FAIL"}  {name:52} -> {results[name]}')
    print(f'        {why}')

# ---- BOTH weakened classifiers ---------------------------------------
print('\n  CONTROLS -- a classifier pinned either way must fail the arms that')
print('  expect the other answer. One direction alone cannot catch a verdict')
print('  pinned the opposite way, which is how the original defect survived.')
STUB = ('import json,sys\n'
        "json.dump({'b0_result': %r,\n"
        "  'complete_sources': %s, 'partial_sources': [],\n"
        "  'ineligible_sources': [], 'unusable_sources': [],\n"
        "  'sections_with_no_release_bound_source': [],\n"
        "  'source_roles': {}, 'verdict_rule': '',\n"
        "  'provenance_available': {}}, open(sys.argv[4],'w'))\n")
for label, verdict, comp in (
        ('hard-coded UNDERIVED', 'VALIDATION_INPUT_UNDERIVED', '[]'),
        ('hard-coded DERIVABLE', 'COMPLETE_SPECIFICATION_DERIVABLE',
         "['declared_policy:synthetic']")):
    stub = W / f'weak_{verdict}.py'
    stub.write_text(STUB % (verdict, comp))
    survivors = []
    for name, mut, check, _why in ARMS:
        if mut is None:
            continue
        d = run(mutate(mut), tool=stub)
        try:
            if d is not None and check(d):
                survivors.append(name)
        except Exception:                                    # noqa: BLE001
            pass
    # A pinned classifier legitimately satisfies arms whose EXPECTED verdict is
    # the one it is pinned to -- but only if the arm checks nothing else. Any
    # arm it satisfies that expects the other verdict is a real failure.
    wrong = [n for n in survivors if results.get(n) != verdict]
    print(f'    {label}: satisfies {len(survivors)} arm(s)')
    if wrong:
        failed.append(f'{label} satisfied arms expecting the other verdict: '
                      f'{wrong}')
        print(f'      FAIL  {wrong}')
    else:
        print('      pass  only arms whose own expectation is that verdict')

print(f'\n  arms={len(ARMS)} failed={len(failed)}')
if failed:
    print(f'  FAILURES: {failed}')
print(f'B0_FALSIFICATION: '
      f'{"DEFECTS_PRESENT" if failed else "EVERY_ARM_DISCRIMINATES"}')
sys.exit(1 if failed else 0)
