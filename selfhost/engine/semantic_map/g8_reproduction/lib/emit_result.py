#!/usr/bin/env python3
"""G8's top-level result, in the SEMANTIC-LINKER-1 four-partition shape.

    REPRODUCTION / FEASIBILITY_EVIDENCE / KNOWN_FAIL_OPEN_FINDINGS /
    PRODUCTION_PREREQUISITES

WHY THIS IS NOT "ALL ASSERTIONS PASS". The gate previously ended at
`SM1_G8: CLEAN_REPRODUCTION`, which is true and dangerously readable as "the
patchability model is clean". It is not: G5 is REDUCE_SCOPE with zero admitted
declarations and reproduced fail-open mechanisms. A reproduction can be clean
precisely BECAUSE it faithfully reproduces refusals. The four partitions keep
those two facts in separate fields so neither can be read as the other.

EVERY VALUE IS DERIVED. Nothing here is transcribed from a run log or written
by hand. Each partition is computed from structured evidence -- the inventory
check, the negative outcomes, the digest snapshot, the per-gate JSON -- and the
verdict rules below are the only place a status is decided.

THE DIRECTION OF EVERY DEFAULT IS REFUSAL. An input that is missing,
unparseable, or whose binding does not resolve makes a partition WORSE, never
better. There is deliberately no path by which absent evidence yields a green
field: `KNOWN_FAIL_OPEN_FINDINGS: ABSENT` forces `REPRODUCTION: FAIL`, because
a rebuild that stopped producing the programme's refusals would otherwise pass
for the worst possible reason. Likewise a prerequisite whose binding cannot be
resolved becomes EVIDENCE_MISSING and takes the partition to UNDERIVABLE --
unknown stays refusal and is never converted into known-false.

usage: emit_result.py <semantic-map-dir> <inventory> <out.json> \
                      <inventory_check.json> <negative_outcomes.json> \
                      <artifact_digests.json> <gate_status.txt> <transcript>
"""
import datetime
import json
import pathlib
import re
import sys

SM = pathlib.Path(sys.argv[1]).resolve()
INV = sys.argv[2]
OUT = sys.argv[3]
CHECK, OUTCOMES, DIGESTS, GATESTATUS, TRANSCRIPT = sys.argv[4:9]

inv = json.load(open(INV))
notes = []


def read_json(path, what):
    """Never raise. An unreadable input is a recorded refusal, not a crash."""
    try:
        return json.load(open(path))
    except FileNotFoundError:
        notes.append(f'{what}: absent')
    except Exception as ex:                                  # noqa: BLE001
        notes.append(f'{what}: unreadable -- {type(ex).__name__}')
    return None


def read_text(path, what):
    try:
        return pathlib.Path(path).read_text(errors='replace')
    except Exception as ex:                                  # noqa: BLE001
        notes.append(f'{what}: unreadable -- {type(ex).__name__}')
    return None


check = read_json(CHECK, 'inventory_check.json')
outcomes = read_json(OUTCOMES, 'negative_outcomes.json')
digests = read_json(DIGESTS, 'artifact_digests.json')
transcript = read_text(TRANSCRIPT, 'g8_reproduction.txt') or ''

# ---- gate exit statuses, read as DATA ------------------------------------
# Not grepped out of the rendered transcript: an assertion that read a
# formatted line ('^  FAILED' against '  run_route2.sh   FAILED') could never
# match, and a gate failed outright while the check passed.
gates = {}
gs = read_text(GATESTATUS, 'gate status')
if gs is None:
    notes.append('gate statuses unavailable -- treated as not reproduced')
else:
    for line in gs.splitlines():
        parts = line.split()
        if len(parts) == 2:
            gates[parts[0]] = int(parts[1]) if parts[1].isdigit() else 1
EXPECTED_GATES = 7
gates_bad = sorted(k for k, v in gates.items() if v != 0)
gates_missing = EXPECTED_GATES - len(gates)

# ---- REPRODUCTION --------------------------------------------------------
equality = (check or {}).get('equality') or {}
ids = [equality.get(k) for k in ('declared_ids', 'tested_ids', 'caught_ids')]
equality_literal = bool(ids[0]) and ids[0] == ids[1] == ids[2]
check_findings = [f.get('code') for f in (check or {}).get('findings') or []]

want_artifacts = sum(len(g['artifacts']) for g in inv['gates'].values())
digest_checked = (check or {}).get('artifacts_digest_checked', 0)
snapshot_n = len(((digests or {}).get('artifacts') or {}))

neg_tested = len((outcomes or {}).get('tested_ids') or [])
neg_caught = len((outcomes or {}).get('caught_ids') or [])
neg_mutations = (outcomes or {}).get('mutations')
neg_restored = (outcomes or {}).get('restorations')
neg_controls = (outcomes or {}).get('classifier_controls')
neg_bank_intact = (outcomes or {}).get('bank_intact_after')

aot_identical = bool(re.search(r'^\s+IDENTICAL$', transcript, re.M))
g1_identical = 'G1 projection IDENTICAL to the banked copy' in transcript
surface_changed = bool(re.search(r'^  CHANGED', transcript, re.M))

repro_blockers = []
if gates_bad:
    repro_blockers.append(f'gates did not reproduce: {gates_bad}')
if gates_missing:
    repro_blockers.append(f'{gates_missing} gate(s) reported no status')
if not equality_literal:
    repro_blockers.append('inventory == tested == caught is not literal')
if check_findings:
    repro_blockers.append(f'inventory findings: {sorted(set(check_findings))}')
if digest_checked != want_artifacts or snapshot_n != want_artifacts:
    repro_blockers.append(
        f'digest coverage {digest_checked}/{snapshot_n} of {want_artifacts}')
# Every declared negative was tested AND caught; every mutation was restored;
# the tested set is exactly the mutations plus the classifier controls, so a
# silently dropped arm cannot hide inside a total; and the bank survived.
if not (neg_tested and neg_tested == neg_caught
        and neg_restored == neg_mutations
        and isinstance(neg_mutations, int) and isinstance(neg_controls, int)
        and neg_mutations + neg_controls == neg_tested
        and neg_bank_intact is True):
    repro_blockers.append(
        f'negatives tested={neg_tested} caught={neg_caught} '
        f'mutations={neg_mutations} restored={neg_restored} '
        f'controls={neg_controls} bank_intact={neg_bank_intact}')
if surface_changed:
    repro_blockers.append('product surface changed')
if notes:
    repro_blockers.append(f'inputs unusable: {notes}')

# ---- FEASIBILITY_EVIDENCE ------------------------------------------------
# What the lane SUBSTANTIVELY found, which must survive a rebuild unchanged.
inl = read_json(SM / 'g5_patchability/evidence/inlining_state.json',
                'inlining_state.json') or {}
sub = read_json(SM / 'g5_patchability/evidence/subset.json',
                'subset.json') or {}
fam = read_json(SM / 'g7_cost/evidence/families.json',
                'families.json') or {}
acct = inl.get('accounting') or {}
feasibility = {
    'reader_accounting': acct,
    'reader_accounting_balances': bool(acct) and
    acct.get('accounted') == acct.get('total_g1_rows'),
    'subset_verdict': sub.get('verdict'),
    'declarations_examined': sub.get('declarations'),
    'predicted_patchable': sub.get('predicted_patchable'),
    'canonical_aot_reproduced': aot_identical,
    'g1_projection_reproduced': g1_identical,
    'retention_measured_over_projected':
        ((fam.get('families') or {}).get('retention_cost_at_scale') or {})
        .get('measured_over_projected'),
}
feas_ok = (not gates_bad and not gates_missing
           and feasibility['reader_accounting_balances']
           and feasibility['canonical_aot_reproduced']
           and feasibility['g1_projection_reproduced']
           and feasibility['subset_verdict'] is not None)

# ---- KNOWN_FAIL_OPEN_FINDINGS -------------------------------------------
# Re-derived AS FINDINGS from each gate's own evidence, in the exact form that
# evidence takes. Assuming one uniform shape once made a present finding look
# absent, so the shape is declared per finding.
fail_open = []
for f in inv['known_fail_open_findings']['findings']:
    path = SM / f['gate'] / f['where']
    body = read_text(path, f"{f['gate']}/{f['where']}")
    if body is None:
        fail_open.append({**{k: f[k] for k in ('id', 'gate', 'where', 'means')},
                          'status': 'EVIDENCE_UNREADABLE', 'count': None})
        continue
    n = len(re.findall(f['pattern'], body))
    fail_open.append({**{k: f[k] for k in ('id', 'gate', 'where', 'means')},
                      'status': ('REPRODUCED' if n >= f['min_count']
                                 else 'NOT_REPRODUCED'),
                      'count': n, 'min_count': f['min_count']})
declared_fo = len(inv['known_fail_open_findings']['findings'])
reproduced_fo = [x for x in fail_open if x['status'] == 'REPRODUCED']
fo_state = ('REPRODUCED' if reproduced_fo and len(reproduced_fo) == declared_fo
            else 'ABSENT')
if fo_state != 'REPRODUCED':
    repro_blockers.append(
        'known FAIL_OPEN findings did not all reproduce: '
        f'{[x["id"] for x in fail_open if x["status"] != "REPRODUCED"]}')

# ---- PRODUCTION_PREREQUISITES -------------------------------------------
def resolve_binding(b):
    """Return (ok, detail). An unresolvable binding is never 'ok'."""
    path = SM / b['gate'] / b['where']
    if b['kind'] == 'text':
        body = read_text(path, f"{b['gate']}/{b['where']}")
        if body is None:
            return False, 'evidence unreadable'
        n = len(re.findall(b['pattern'], body))
        return n >= b.get('min_count', 1), f'{n} match(es)'
    if b['kind'] == 'json':
        doc = read_json(path, f"{b['gate']}/{b['where']}")
        if doc is None:
            return False, 'evidence unreadable'
        cur = doc
        for seg in b['path']:
            if not isinstance(cur, dict) or seg not in cur:
                return False, f'path absent at {seg!r}'
            cur = cur[seg]
        if 'expect_gt' in b:
            return (isinstance(cur, (int, float))
                    and cur > b['expect_gt']), f'value {cur}'
        if 'expect_eq' in b:
            return cur == b['expect_eq'], f'value {cur}'
        if b.get('expect_present'):
            return cur is not None, f'value {cur!r}'
        return False, 'binding declares no expectation'
    return False, f"unknown binding kind {b['kind']!r}"

prereqs = []
contradictions = []
for e in inv['production_prerequisites']['entries']:
    ok, detail = resolve_binding(e['binding'])
    # The status is DERIVED from what the binding's evidence implies, not read
    # from the 'status' field. A binding that merely proved the evidence
    # existed would still leave the status declared, so editing this inventory
    # to say RESOLVED would have been believed.
    implied = e['binding'].get('implies_status')
    if not ok:
        derived_status = 'EVIDENCE_MISSING'
    elif implied is None:
        derived_status = 'EVIDENCE_MISSING'
        detail += ' -- binding declares no implies_status'
    else:
        derived_status = implied
        if implied != e['status']:
            derived_status = 'STATUS_CONTRADICTS_EVIDENCE'
            contradictions.append(
                f"{e['id']}: declared {e['status']}, evidence implies {implied}")
    prereqs.append({
        'id': e['id'],
        'status': derived_status,
        'declared_status': e['status'],
        'implied_status': implied,
        'severity': e['severity'],
        'statement': e['statement'],
        'why': e['why'],
        'observed_consequence': e['observed_consequence'],
        'binding_resolved': ok,
        'binding_detail': detail,
        'evidence': f"{e['binding']['gate']}/{e['binding']['where']}",
        'consumed_by': e['consumed_by'],
    })
underivable = [p['id'] for p in prereqs
               if p['status'] in ('EVIDENCE_MISSING',
                                  'STATUS_CONTRADICTS_EVIDENCE')]
blocking = [p['id'] for p in prereqs if p['status'] == 'UNRESOLVED']
carry = [p['id'] for p in prereqs if p['status'] == 'CARRY_FORWARD']
# ONE decision, worst-first, so nothing downstream can overwrite it. An
# earlier version appended the contradictions blocker with a bare `if` in the
# middle of an if/elif chain, which re-entered the chain and reset UNDERIVABLE
# back to UNRESOLVED -- an unresolvable binding was reported as a merely
# unresolved prerequisite. The reporting falsifier caught it on four arms.
if underivable:
    prereq_state = 'UNDERIVABLE'
elif blocking:
    prereq_state = 'UNRESOLVED'
else:
    prereq_state = 'RESOLVED'
if underivable:
    repro_blockers.append(f'prerequisite bindings unresolved: {underivable}')
if contradictions:
    repro_blockers.append(
        f'declared status contradicts evidence: {contradictions}')

# ---- the four partitions -------------------------------------------------
result = {
    'REPRODUCTION': 'FAIL' if repro_blockers else 'PASS',
    'FEASIBILITY_EVIDENCE': 'REPRODUCED' if feas_ok else 'NOT_REPRODUCED',
    'KNOWN_FAIL_OPEN_FINDINGS': fo_state,
    'PRODUCTION_PREREQUISITES': prereq_state,
}

doc = {
    'schema': 'semantic-map-1/g8-reproduction/1',
    'gate': 'SM1-G8', 'issue': 57, 'tracker': 48,
    'generated': datetime.datetime.now(datetime.timezone.utc)
                 .strftime('%Y-%m-%dT%H:%M:%SZ'),
    'result': result,
    'verdict_rule':
        'REPRODUCTION cannot be PASS while any mandatory input is missing or '
        'unparseable, a gate did not reproduce, the stable-id equality is not '
        'literal, digest coverage is short, a negative went uncaught or '
        'unrestored, the product surface moved, a declared FAIL_OPEN finding '
        'stopped reproducing, or a prerequisite binding did not resolve. '
        'Reproducing a known fail-open refusal is a reproduced FINDING and is '
        'never rendered as a safety result. CLEAN_REPRODUCTION describes the '
        'reproduction, never the patchability model.',
    'reproduction': {
        'blockers': repro_blockers,
        'gate_exit_status': gates,
        'gates_expected': EXPECTED_GATES,
        'equality': {k: len(equality.get(k) or []) for k in
                     ('declared_ids', 'tested_ids', 'caught_ids')},
        'equality_literal': equality_literal,
        'artifacts_expected': want_artifacts,
        'artifacts_digest_checked': digest_checked,
        'artifacts_snapshotted': snapshot_n,
        'negatives': {'tested': neg_tested, 'caught': neg_caught,
                      'mutations': neg_mutations, 'restored': neg_restored,
                      'classifier_controls': neg_controls,
                      'bank_intact_after': neg_bank_intact},
        'product_surface_changed': surface_changed,
        'input_notes': notes,
    },
    'feasibility_evidence': feasibility,
    'known_fail_open_findings': {
        'declared': declared_fo,
        'reproduced': len(reproduced_fo),
        'findings': fail_open,
        'why_this_is_not_a_pass':
            'These are refusals the programme depends on. If a clean rebuild '
            'stopped producing them the gate would be passing for the wrong '
            'reason, so ABSENT forces REPRODUCTION: FAIL.',
    },
    'production_prerequisites': {
        'blocking': blocking,
        'carry_forward': carry,
        'evidence_missing': underivable,
        'contradictions': contradictions,
        'entries': prereqs,
    },
    'reproducibility_expectations': inv['reproducibility_expectations'],
}
json.dump(doc, open(OUT, 'w'), indent=2)

# ---- the rendered partitions --------------------------------------------
w = sys.stdout.write
w('############ RESULT -- FOUR PARTITIONS, NOT "ALL TESTS PASS" ############\n')
w('  CLEAN_REPRODUCTION describes the REPRODUCTION. It does not say the\n')
w('  patchability model is clean -- G5 is REDUCE_SCOPE with zero admitted\n')
w('  declarations, and the fail-open mechanisms below reproduced as findings.\n')
w('  Every field is derived; none is transcribed.\n\n')
for k, v in result.items():
    w(f'  {k:26} {v}\n')
w('\n')

w('  REPRODUCTION\n')
w(f'    gates            {len(gates)}/{EXPECTED_GATES} reported, '
  f'{len(gates_bad)} non-zero\n')
w(f'    stable-id equality {"==".join(str(len(equality.get(k) or [])) for k in ("declared_ids","tested_ids","caught_ids"))}'
  f'  literal={equality_literal}\n')
w(f'    artifacts        {digest_checked}/{want_artifacts} digest-checked, '
  f'{snapshot_n} snapshotted\n')
w(f'    negatives        tested={neg_tested} caught={neg_caught} '
  f'mutations={neg_mutations} restored={neg_restored} '
  f'controls={neg_controls} bank_intact={neg_bank_intact}\n')
w(f'    product surface  {"CHANGED" if surface_changed else "unchanged"}\n')
for b in repro_blockers:
    w(f'    BLOCKER          {b}\n')
w('\n  FEASIBILITY_EVIDENCE\n')
w(f'    reader accounting  {acct}  balances='
  f'{feasibility["reader_accounting_balances"]}\n')
w(f'    subset             {feasibility["subset_verdict"]}  admitted '
  f'{feasibility["predicted_patchable"]}/{feasibility["declarations_examined"]}\n')
w(f'    canonical AOT      reproduced={aot_identical}\n')
w(f'    G1 projection      reproduced={g1_identical}\n')
w(f'    retention cost     measured/projected='
  f'{feasibility["retention_measured_over_projected"]}\n')
w('\n  KNOWN_FAIL_OPEN_FINDINGS  '
  f'{len(reproduced_fo)}/{declared_fo} reproduced as findings\n')
for x in fail_open:
    w(f'    {x["status"]:18} {x["id"]}  ({x["count"]} vs min '
      f'{x.get("min_count")})\n')
    w(f'                       {x["means"]}\n')
w('\n  PRODUCTION_PREREQUISITES\n')
for p in prereqs:
    w(f'    {p["status"]:16} {p["severity"]:24} {p["id"]}\n')
    w(f'                     {p["statement"]}\n')
    w(f'                     binding: {p["evidence"]} -- {p["binding_detail"]}\n')
w(f'\n    blocking={len(blocking)} carry_forward={len(carry)} '
  f'evidence_missing={len(underivable)}\n')

sys.exit(1 if repro_blockers else 0)
