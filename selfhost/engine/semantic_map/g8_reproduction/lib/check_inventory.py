#!/usr/bin/env python3
"""Prove  inventory == tested == caught  across every gate.

Three sets, and every difference between them is a finding:

    INVENTORY   what inventory.json declares must exist
    TESTED      what the regenerated transcripts actually record
    CAUGHT      the NEGATIVE verdicts -- controls that genuinely failed

  declared but not tested   an arm nobody runs. Indistinguishable from an arm
                            that cannot run.
  tested but not declared   an arm outside the inventory. The inventory is
                            then not the single source of truth it claims.
  declared negative not caught
                            a control that never failed. That is the vacuous
                            -check class this programme has hit repeatedly:
                            an arm that cannot fail certifies nothing.

Also verifies the deterministic bindings exactly, the structural bindings
shape-only, the known FAIL_OPEN findings are re-derived AS findings, and the
timing summaries come from the retained samples rather than from prose.

usage: check_inventory.py <semantic-map-dir> <inventory.json> <out.json>
"""
import json
import pathlib
import re
import sys

SM, INV, OUT = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
# The falsifier re-enters this checker per mutation; on those runs the outcome
# file does not exist yet, so the equality check is skipped rather than
# reported as a failure of the bank under test.
NO_OUTCOMES = '--no-outcomes' in sys.argv
OUTCOMES = None if NO_OUTCOMES else (sys.argv[4] if len(sys.argv) > 4 else None)
inv = json.load(open(INV))
findings = []


def finding(code, detail):
    findings.append({'code': code, 'detail': detail})


# Leading whitespace is significant here only as a trap: a control's
# verdict is printed through `sed 's/^/  /'` when it runs inside another
# script, so an anchored pattern silently misses exactly the CONTROL
# markers -- the ones whose absence this checker is meant to report.
MARKER = re.compile(r'^[ \t]*(SM1_G[0-9A-Z_]*: [A-Z_]+)[ \t]*$', re.M)

tested, caught, missing_artifacts = {}, {}, []
for gate, spec in inv['gates'].items():
    gdir = SM / gate
    for rel in spec['scripts']:
        p = gdir / rel
        if not p.exists():
            finding('SCRIPT_MISSING', f'{gate}/{rel}')
        elif not p.stat().st_mode & 0o111:
            finding('SCRIPT_NOT_EXECUTABLE', f'{gate}/{rel}')
    for rel in spec['artifacts']:
        p = gdir / rel
        if not p.exists() or p.stat().st_size == 0:
            missing_artifacts.append(f'{gate}/{rel}')
            finding('ARTIFACT_MISSING_OR_EMPTY', f'{gate}/{rel}')

    seen = set()
    for p in (gdir / 'evidence').glob('*.txt'):
        seen |= set(MARKER.findall(p.read_text()))
    tested[gate] = sorted(seen)

    declared = set(spec['positive']) | set(spec['negative'])
    caught[gate] = sorted(seen & set(spec['negative']))

    for m in sorted(set(spec['positive']) - seen):
        finding('DECLARED_POSITIVE_NOT_TESTED', f'{gate}: {m}')
    for m in sorted(set(spec['negative']) - seen):
        finding('DECLARED_CONTROL_NEVER_FAILED',
                f'{gate}: {m} -- the control did not produce its failure '
                f'verdict, so the arm it guards is unproven')
    for m in sorted(seen - declared):
        finding('TESTED_BUT_NOT_DECLARED',
                f'{gate}: {m} -- present in evidence, absent from the '
                f'inventory, so the inventory is not the single source of truth')

# ---- known FAIL_OPEN findings must be re-derived AS findings -------------
reproduced_findings = {}
for f in inv['known_fail_open_findings']['findings']:
    p = SM / f['gate'] / f['where']
    if not p.exists():
        finding('FAIL_OPEN_EVIDENCE_MISSING', f"{f['id']}: {f['where']}")
        continue
    n = len(re.findall(f['pattern'], p.read_text()))
    reproduced_findings[f['id']] = n
    if n < f['min_count']:
        finding('FAIL_OPEN_FINDING_NOT_REPRODUCED',
                f"{f['id']}: {n} occurrences in {f['where']}, "
                f"{f['min_count']} required -- a refusal the programme "
                f"depends on stopped being produced")

# ---- deterministic bindings, EXACT ---------------------------------------
fam_path = SM / 'g7_cost' / 'evidence' / 'families.json'
det = inv['deterministic_bindings']['g7_cost']
if not fam_path.exists():
    finding('DETERMINISTIC_EVIDENCE_MISSING', str(fam_path))
else:
    fam = json.load(open(fam_path))
    r = fam['families']['retention_cost_at_scale']
    m = fam['families']['map_size']
    got = {
        'retention_measured_delta_bytes': r['measured_delta_bytes'],
        'retention_measured_delta_pct': r['measured_delta_pct'],
        'g4_projection_bytes': r['g4_projection_bytes'],
        'g4_projection_pct': r['g4_projection_pct'],
        'measured_over_projected': r['measured_over_projected'],
        'map_bytes': m['map_bytes'],
        'map_over_aot_pct': m['map_over_aot_pct'],
    }
    for k, want in det.items():
        if got.get(k) != want:
            finding('DETERMINISTIC_BINDING_CHANGED',
                    f'{k}: reproduced {got.get(k)}, bound {want}')

# ---- structural bindings, SHAPE ONLY -------------------------------------
sam_path = SM / 'g7_cost' / 'evidence' / 'samples.jsonl'
st = inv['structural_bindings']['g7_cost']
if not sam_path.exists():
    finding('TIMING_SAMPLES_MISSING', str(sam_path))
else:
    rows = [json.loads(l) for l in sam_path.read_text().splitlines() if l.strip()]
    for row in rows[:1]:
        for f in st['required_sample_fields']:
            if f not in row:
                finding('SAMPLE_FIELD_MISSING', f)
    labels = {r['label'] for r in rows}
    for stage in st['required_stages']:
        if stage not in labels:
            finding('TIMING_STAGE_MISSING', stage)
    for order in st['required_orders']:
        reps = {r['rep'] for r in rows if r['order'] == order}
        if not reps:
            finding('TIMING_ORDER_MISSING', order)
        elif len(reps) < st['min_reps_per_order']:
            finding('TIMING_REPS_INSUFFICIENT',
                    f'{order}: {len(reps)} reps, {st["min_reps_per_order"]} required')
    if st['zero_producer_failures'] and any(r['exit'] != 0 for r in rows):
        finding('TIMING_PRODUCER_FAILED',
                f'{sum(1 for r in rows if r["exit"] != 0)} samples exited non-zero')
    # The summaries must come from THESE samples, not from prose.
    if fam_path.exists():
        fam = json.load(open(fam_path))
        if fam.get('samples') != len(rows):
            finding('SUMMARY_NOT_FROM_SAMPLES',
                    f"families.json reports {fam.get('samples')} samples, "
                    f"{len(rows)} are retained")
        od = fam.get('order_dependence') or {}
        if not od:
            finding('CLASSIFIER_INPUTS_MISSING', 'no order_dependence recorded')
        else:
            any_stage = next(iter(od.values()))
            for f in st['required_classifier_inputs']:
                if f not in any_stage:
                    finding('CLASSIFIER_INPUT_MISSING', f)

# ---- inventory == tested == caught, LITERALLY over stable ids -----------
declared_ids = sorted([e['id'] for e in inv['falsifiable']['entries']]
                      + [c['id'] for c in inv['classifier_controls']['entries']])
equality = {'declared_ids': declared_ids}
if OUTCOMES and pathlib.Path(OUTCOMES).exists():
    oc = json.load(open(OUTCOMES))
    equality['tested_ids'] = oc['tested_ids']
    equality['caught_ids'] = oc['caught_ids']
    if declared_ids != oc['tested_ids']:
        finding('DECLARED_NOT_TESTED',
                f"declared but not exercised: "
                f"{sorted(set(declared_ids) - set(oc['tested_ids']))}; "
                f"exercised but not declared: "
                f"{sorted(set(oc['tested_ids']) - set(declared_ids))}")
    if declared_ids != oc['caught_ids']:
        finding('DECLARED_NOT_CAUGHT',
                f"declared but not caught: "
                f"{sorted(set(declared_ids) - set(oc['caught_ids']))} -- an "
                f"entry whose mutation the checker did not detect")
    if not oc.get('bank_intact_after'):
        finding('BANK_NOT_RESTORED', 'the bank was not consistent after the '
                                     'negatives ran')
elif not NO_OUTCOMES:
    finding('OUTCOMES_MISSING',
            'no falsifier outcomes supplied, so inventory == tested == caught '
            'cannot be asserted -- it is not enough that the transcripts '
            'happen to contain the right markers')

summary = {
    'schema': 'semantic-map-1/g8-inventory-check/1',
    'gate': 'SM1-G8', 'issue': 57,
    'inventory': {g: sorted(set(s['positive']) | set(s['negative']))
                  for g, s in inv['gates'].items()},
    'tested': tested,
    'caught': caught,
    'missing_artifacts': missing_artifacts,
    'known_fail_open_findings_reproduced': reproduced_findings,
    'equality': equality,
    'findings': findings,
    'verdict': 'INVENTORY_CONSISTENT' if not findings else 'INVENTORY_DEFECTS',
}
json.dump(summary, open(OUT, 'w'), indent=2)

for gate in inv['gates']:
    d = set(summary['inventory'][gate])
    t = set(tested[gate])
    c = set(caught[gate])
    print(f'  {gate}')
    print(f'    declared {len(d):>3}   tested {len(t):>3}   caught {len(c):>3}'
          f'   declared==tested: {d == t}')
print('  known FAIL_OPEN findings, re-derived as findings:')
for k, n in reproduced_findings.items():
    print(f'    {k:34} {n} occurrence(s)')
for f in findings:
    print(f'    {f["code"]:34} {f["detail"][:76]}')
if 'tested_ids' in equality:
    print(f"  declared=={len(declared_ids)} tested=={len(equality['tested_ids'])} "
          f"caught=={len(equality['caught_ids'])}  literal equality: "
          f"{declared_ids == equality['tested_ids'] == equality['caught_ids']}")
print(f'SM1_G8_INVENTORY: {summary["verdict"]}')
sys.exit(1 if findings else 0)
