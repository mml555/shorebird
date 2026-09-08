#!/usr/bin/env python3
"""The SM1-G5 subset check:  predicted patchable  SUBSET-OF  demonstrated patchable.

This is BINARY SAFETY. One predicted declaration that is not demonstrated is
FAIL_OPEN and the gate cannot pass. Coverage is diagnostic only and must never
affect the verdict -- a percentage cannot excuse an over-claim.

WHAT COUNTS AS DEMONSTRATED. Only the actual shipping patch path visibly
changing ordinary program behaviour for the declaration. Specifically NOT:

  * container parsing succeeding;
  * attach succeeding (IsInterpreted/HasBytecode flipping);
  * a direct C++ invoke of the replacement returning the new value;
  * the predictor agreeing;
  * the absence of a known-bad machine-code shape.

Those are all recorded in the demonstration input for context, and this scorer
IGNORES every one of them. A declaration is demonstrated only when it has at
least one OBSERVED ORDINARY CALL SITE and every observed ordinary call site
moved. Requiring "all" rather than "any" is what makes Base.work -- whose
devirtualizable site moved while its polymorphic site stayed stale -- count as
NOT demonstrated.

The demonstration input must not be derived from the predictor. This scorer
refuses if the demonstration declares itself predictor-derived.

usage: score_subset.py <predictions.json> <demonstrated.json> <out.json>
"""
import json
import sys

PRED, DEMO, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
pred = json.load(open(PRED))
demo = json.load(open(DEMO))

problems = []

# INDEPENDENCE. A demonstration that consumed the predictor cannot witness it.
if demo.get('derived_from_predictor') is True:
    problems.append('the demonstration declares itself predictor-derived')
if demo.get('source') == PRED:
    problems.append('the demonstration input IS the predictions file')

# THE DEMONSTRATION MUST BE INTERNALLY CONSISTENT. It carries the call-site map
# it used, the fields the probe prints, and the fields it deliberately excluded.
# Verifying those against each other means a demonstration cannot quietly claim
# fewer call sites than the program actually has: lowering a row's
# sites_expected also requires shrinking the map, which then no longer covers
# the printed fields.
cmap = demo.get('call_site_map') or {}
printed = set(demo.get('printed_fields') or [])
excluded = set(demo.get('excluded_printed_fields') or {})
if not cmap or not printed:
    problems.append('the demonstration does not carry its call-site map and '
                    'printed-field list, so its completeness cannot be checked')
else:
    covered = {f for v in cmap.values() for f in v}
    if covered | excluded != printed:
        problems.append(
            f'call-site map does not account for every printed field: '
            f'unaccounted={sorted(printed - covered - excluded)} '
            f'stray={sorted(covered - printed)}')

# What the demonstration says moved, by declaration_id.
demonstrated = {}
demo_detail = {}
for r in demo.get('rows', []):
    did = r.get('declaration_id')
    sites = r.get('call_sites') or []
    ordinary = [s for s in sites if s.get('ordinary', True)]
    # UNDER-OBSERVATION IS A REFUSAL. A row whose observed sites were reduced
    # after collection -- dropping the stale ones -- would make an
    # undemonstrated declaration look demonstrated. The collector declares the
    # count from a map derived from the probe source; a mismatch is refused
    # rather than scored.
    expected = r.get('sites_expected')
    mapped = cmap.get(r.get('target'))
    if mapped is not None and expected is not None and len(mapped) != expected:
        problems.append(f'{r.get("key")}: sites_expected={expected} disagrees '
                        f'with the call-site map ({len(mapped)} fields)')
    if expected is None:
        problems.append(f'{r.get("key")}: no sites_expected, so the '
                        f'demonstration cannot be shown to be complete')
    elif expected != len(ordinary):
        problems.append(f'{r.get("key")}: {len(ordinary)} observed call sites '
                        f'but {expected} expected -- an under-observed '
                        f'demonstration cannot witness a prediction')
    # "all observed ordinary call sites moved", and there must be at least one.
    ok = bool(ordinary) and all(s.get('moved') is True for s in ordinary)
    demonstrated[did] = ok
    demo_detail[did] = {
        'key': r.get('key'),
        'ordinary_call_sites': len(ordinary),
        'moved': [s.get('name') for s in ordinary if s.get('moved') is True],
        'stale': [s.get('name') for s in ordinary if s.get('moved') is not True],
        # Recorded and deliberately not used:
        'attach_ok': r.get('attach_ok'),
        'direct_invoke': r.get('direct_invoke'),
    }

rows = pred.get('rows', [])
predicted = [r for r in rows if r.get('predicted_patchable') is True]

violations = []
for r in predicted:
    did = r.get('declaration_id')
    if demonstrated.get(did) is not True:
        violations.append({
            'key': r.get('key'),
            'declaration_id': did,
            'why': ('no demonstration row' if did not in demonstrated
                    else 'demonstration shows a stale ordinary call site: '
                         f"{demo_detail[did]['stale']}"),
        })

n = len(rows)
verdict = 'FAIL_OPEN' if (violations or problems) else 'SUBSET_HOLDS'
out = {
    'schema': 'semantic-map-1/g5-subset/1',
    'gate': 'SM1-G5', 'issue': 54,
    'predictions': PRED,
    'demonstration': DEMO,
    'independence_problems': problems,
    'declarations': n,
    'predicted_patchable': len(predicted),
    'refused': n - len(predicted),
    # DIAGNOSTIC ONLY. Never an input to the verdict.
    'coverage_diagnostic_only': (
        f'{len(predicted)}/{n}'
        + (f' = {100.0 * len(predicted) / n:.1f}%' if n else '')),
    'violations': violations,
    'demonstration_detail': demo_detail,
    'verdict': verdict,
}
json.dump(out, open(OUT, 'w'), indent=2)

print(f'  declarations          {n}')
print(f'  predicted patchable   {len(predicted)}')
print(f'  refused               {n - len(predicted)}')
print(f'  coverage (diagnostic) {out["coverage_diagnostic_only"]}')
for p in problems:
    print(f'  INDEPENDENCE: {p}')
for v in violations:
    print(f'  OVER-CLAIM: {v["key"]} -- {v["why"]}')
print(f'SM1_G5_SUBSET: {verdict}')
sys.exit(1 if verdict == 'FAIL_OPEN' else 0)
