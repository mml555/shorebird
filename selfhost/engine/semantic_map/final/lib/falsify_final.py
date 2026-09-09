#!/usr/bin/env python3
"""Sensitivity controls for the FINAL assembler.

#58: "A verdict that could not have come out any other way is not worth
publishing." So the strongest control here is not that the assembler reacts to
damage -- it is that EVERY verdict in the allowed vocabulary is REACHABLE from
some state of the evidence. Five arms drive the computation to each of the five
verdicts in turn, and a sixth drives it to NOT_ESTABLISHED, proving the ladder
does not silently default when no predicate holds.

Four control families, per the authorization:

  A. per-row evidence sensitivity -- derived, one arm per (row, evidence file)
     pair, deleted and corrupted; the row must read NOT_ESTABLISHED
  B. verdict reachability -- each allowed verdict reached from a described
     state of the evidence
  C. a weakened assembler that hard-codes the baseline verdict must FAIL
     family B
  D. stale outputs must not survive a failed assembly as apparent current
     output

Everything runs against a scratch COPY of the evidence tree. Nothing under the
real evidence directories is written, so a control cannot corrupt the bank it
is measuring.

usage: falsify_final.py <semantic-map-dir> <final-dir> <workdir>
"""
import collections
import json
import pathlib
import shutil
import subprocess
import sys

SM = pathlib.Path(sys.argv[1]).resolve()
FINAL = pathlib.Path(sys.argv[2]).resolve()
W = pathlib.Path(sys.argv[3]).resolve()
EXTRACT = FINAL / 'lib' / 'extract_matrix.py'
VERDICT = FINAL / 'lib' / 'compute_verdict.py'
MANIFEST = FINAL / 'lib' / 'build_manifest.py'
RESULT = FINAL / 'lib' / 'gen_result.py'
REG = FINAL / 'evidence_registry.json'
GARBAGE = b'\x00\x01not evidence\xff\xfe'


def fresh():
    if W.exists():
        shutil.rmtree(W)
    W.mkdir(parents=True)
    shutil.copytree(SM, W / 'sm', symlinks=True)
    shutil.copy(REG, W / 'registry.json')


def assemble(verdict_tool=None):
    """Run extract -> verdict. Returns (matrix, verdict) or (None, None)."""
    m, v = W / 'matrix.json', W / 'verdict.json'
    for p in (m, v):
        if p.exists():
            p.unlink()          # never score an arm on a previous result
    subprocess.run([sys.executable, str(EXTRACT), str(W / 'sm'),
                    str(W / 'registry.json'), str(m)],
                   capture_output=True, text=True)
    if not m.exists():
        return None, None
    subprocess.run([sys.executable, str(verdict_tool or VERDICT), str(m),
                    str(v)], capture_output=True, text=True)
    try:
        return json.load(open(m)), (json.load(open(v)) if v.exists() else None)
    except Exception:                                        # noqa: BLE001
        return None, None


def ev(rel):
    return W / 'sm' / rel


reg = json.loads(REG.read_bytes())
rows = reg['rows']
failed = []
lines = []


def say(s=''):
    lines.append(s)
    print(s)


say('SM1-FINAL -- sensitivity controls')
say()
fresh()
base_m, base_v = assemble()
if not base_m or not base_v:
    raise SystemExit('  baseline assembly produced nothing')
BASE_VERDICT = base_v['verdict']
say(f'  baseline verdict: {BASE_VERDICT}')
say(f'  baseline NOT_ESTABLISHED rows: '
    f'{base_m["not_established"] or "none"}')
if base_m['not_established']:
    raise SystemExit('  baseline has unresolved rows; fix the pointers first')
say()

# ---- A. per-row evidence sensitivity, derived ---------------------------
say('  A. PER-ROW EVIDENCE SENSITIVITY (derived: every row x every file it '
    'names)')
say('     Removing or corrupting a row\'s evidence must make THAT row read')
say('     NOT_ESTABLISHED. A row that survived losing its own evidence would')
say('     be answering from somewhere other than the evidence.')
pairs = []
for row in rows:
    for f in sorted({s['file'] for s in row['probes'].values()}):
        pairs.append((row['row'], f))
say(f'     {len(pairs)} (row, file) pairs x 2 mutations = {len(pairs) * 2} arms')
a_fail = []
for rowname, rel in pairs:
    for mutation in ('deleted', 'corrupted'):
        fresh()
        p = ev(rel)
        if mutation == 'deleted':
            p.unlink()
        else:
            p.write_bytes(GARBAGE)
        m, _ = assemble()
        got = (m['matrix'][rowname]['category'] if m else 'NO-OUTPUT')
        if got != 'NOT_ESTABLISHED':
            a_fail.append(f'{rowname}/{pathlib.Path(rel).name}-{mutation}'
                          f' -> {got}')
for f in a_fail:
    say(f'     FAIL  {f}')
say(f'     arms={len(pairs) * 2} failed={len(a_fail)}')
failed += a_fail
say()

# ---- B. verdict reachability -------------------------------------------
say('  B. VERDICT REACHABILITY -- every allowed verdict must be reachable')
say('     If only one verdict could ever come out, publishing it proves')
say('     nothing about the evidence.')


def set_json(rel, fn):
    p = ev(rel)
    d = json.load(open(p))
    fn(d)
    json.dump(d, open(p, 'w'), indent=2)


G5S = 'g5_patchability/evidence/subset.json'
G5I = 'g5_patchability/evidence/inlining_state.json'
G4 = 'g4_retention/evidence/g4_retention.json'
G8R = 'g8_reproduction/evidence/g8_result.json'


def make_admitted():
    set_json(G5S, lambda d: d.update(verdict='SUBSET_HOLDS',
                                     predicted_patchable=7))


def resolve_prereqs():
    def fn(d):
        for e in d['production_prerequisites']['entries']:
            e['status'] = 'RESOLVED'
        d['production_prerequisites']['blocking'] = []
    set_json(G8R, fn)


def retention_met():
    set_json(G4, lambda d: d.update(acceptance='MET', fail_open_classes=[],
                                    retention_enforcement='FULL'))


def break_accounting():
    set_json(G5I, lambda d: d['accounting'].update(accounted=30))


def attribute_tool_defect():
    def fn(d):
        d['production_prerequisites']['entries'][0]['severity'] = \
            'ANALYZER_DEFECT'
    set_json(G8R, fn)


B_ARMS = [
 ('PROCEED', 'a non-empty admitted set, retention failing closed, and no '
             'blocking prerequisite',
  lambda: (make_admitted(), retention_met(), resolve_prereqs())),
 ('MODIFY_ANALYZER', 'a shortfall ATTRIBUTED to an analyzer defect while the '
                     'model rows all hold',
  attribute_tool_defect),
 ('MODIFY_MAP_DESIGN', 'the evidence as it stands: empty admitted set, full '
                       'accounting, blocking prerequisites open',
  lambda: None),
 ('REDUCE_SCOPE', 'a non-empty admitted set while retention still does not '
                  'fail closed',
  make_admitted),
 ('ABANDON_OR_REDESIGN', 'the refusal accounting no longer covers every '
                         'declaration, so the unsafe class is not '
                         'mechanically identifiable',
  break_accounting),
 ('NOT_ESTABLISHED', 'no predicate holds -- prerequisites resolved but the '
                     'admitted set still empty; the ladder must not default',
  resolve_prereqs),
]
b_fail = []
for want, why, mutate in B_ARMS:
    fresh()
    mutate()
    _, v = assemble()
    got = v['verdict'] if v else 'NO-OUTPUT'
    ok = got == want
    if not ok:
        b_fail.append(f'{want} (got {got})')
    say(f'     {"pass" if ok else "FAIL"}  {want:22} <- {why}')
say(f'     arms={len(B_ARMS)} failed={len(b_fail)}')
failed += b_fail
say()

# ---- C. weakened assembler ---------------------------------------------
say('  C. WEAKENED ASSEMBLER -- one that hard-codes the baseline verdict')
say('     must FAIL family B. Without this, family B proves the assembler')
say('     reacts to input, not that it reacts correctly.')
weak = W.parent / 'weak_verdict.py'
weak.write_text(
    'import json,sys\n'
    f"json.dump({{'verdict': {BASE_VERDICT!r}, 'selected_by_predicate': None,\n"
    "  'ladder_trace': [], 'predicates': {}, 'rows_not_established': [],\n"
    "  'rows_not_positive': [], 'blocking_prerequisites': [],\n"
    "  'next_lane': [], 'non_proven_claims': []}, open(sys.argv[2],'w'))\n")
survivors = []
for want, _why, mutate in B_ARMS:
    fresh()
    mutate()
    _, v = assemble(verdict_tool=weak)
    if v and v['verdict'] == want:
        survivors.append(want)
say(f'     family-B arms the weakened assembler still satisfies: '
    f'{len(survivors)}')
if len(survivors) != 1:
    # It must satisfy exactly the one arm whose expected verdict IS the
    # baseline -- and no other. Satisfying more would mean those arms were
    # not discriminating; satisfying none would mean the control is broken.
    failed.append(f'weakened assembler satisfied {len(survivors)} arms '
                  f'({survivors}); expected exactly the baseline arm')
    say(f'     FAIL  survivors={survivors}')
else:
    say(f'     pass  it satisfies only {survivors[0]}, which IS the baseline')
say()

# ---- D. stale outputs must not survive a failed assembly ---------------
say('  D. STALE OUTPUTS -- a previous RESULT.md and manifest must not read as')
say('     current output after an assembly that failed. This runs the REAL')
say('     orchestrator against corrupted evidence. The first version of this')
say('     control deleted the stale files ITSELF and then asserted they were')
say('     gone, which could not fail -- it was checking its own cleanup, not')
say('     run_final.sh\'s contract.')
fresh()
scratch_final = W / 'final'
shutil.copytree(FINAL, scratch_final, symlinks=True)
shutil.rmtree(scratch_final / 'evidence', ignore_errors=True)
(scratch_final / 'evidence').mkdir(parents=True)
STALE_MD = '# STALE REPORT\n\n    PROCEED\n'
(scratch_final / 'RESULT.md').write_text(STALE_MD)
(scratch_final / 'evidence' / 'provenance_manifest.json').write_text(
    '{"stale": true}\n')
ev('g5_patchability/evidence/subset.json').write_bytes(GARBAGE)
import os
nested_env = {**os.environ, 'SM1_FINAL_NESTED': '1'}
r = subprocess.run(['bash', str(scratch_final / 'run_final.sh'),
                    str(W / 'sm'), str(scratch_final)],
                   capture_output=True, text=True, env=nested_env)
md = (scratch_final / 'RESULT.md').read_text() \
    if (scratch_final / 'RESULT.md').exists() else ''
man = scratch_final / 'evidence' / 'provenance_manifest.json'
try:
    stale_manifest_survived = json.loads(man.read_text()).get('stale') is True
except Exception:                                            # noqa: BLE001
    stale_manifest_survived = False
d_checks = collections.OrderedDict([
 ('degraded: orchestrator exits non-zero', r.returncode != 0),
 ('degraded: the stale RESULT.md did not survive', md != STALE_MD),
 ('degraded: RESULT.md leads with an INCOMPLETE banner',
  'THIS ASSEMBLY IS INCOMPLETE' in md),
 ('degraded: the verdict is marked PROVISIONAL', 'PROVISIONAL' in md),
 ('degraded: RESULT.md names the unresolved row',
  'PATCHABILITY_SUBSET_PROPERTY' in md),
 ('degraded: the stale manifest did not survive', not stale_manifest_survived),
])

# The other path: a stage that CRASHES rather than degrading. Removing the
# registry makes extract_matrix unable to run at all, and then RESULT.md must
# be a generated failure notice -- not a report, and not the stale one.
fresh()
crash_final = W / 'final_crash'
shutil.copytree(FINAL, crash_final, symlinks=True)
shutil.rmtree(crash_final / 'evidence', ignore_errors=True)
(crash_final / 'evidence').mkdir(parents=True)
(crash_final / 'RESULT.md').write_text(STALE_MD)
(crash_final / 'evidence_registry.json').unlink()
r2 = subprocess.run(['bash', str(crash_final / 'run_final.sh'),
                     str(W / 'sm'), str(crash_final)],
                    capture_output=True, text=True, env=nested_env)
md2 = (crash_final / 'RESULT.md').read_text() \
    if (crash_final / 'RESULT.md').exists() else ''
d_checks['crashed: orchestrator exits non-zero'] = r2.returncode != 0
d_checks['crashed: the stale RESULT.md did not survive'] = md2 != STALE_MD
d_checks['crashed: RESULT.md says ASSEMBLY FAILED'] = 'ASSEMBLY FAILED' in md2
d_checks['crashed: RESULT.md does not claim a verdict'] = \
    '    PROCEED' not in md2 and 'MODIFY_MAP_DESIGN' not in md2
for label, ok in d_checks.items():
    say(f'     {"pass" if ok else "FAIL"}  {label}')
    if not ok:
        failed.append(f'stale-output control: {label}')
say()

say(f'  TOTAL arms={len(pairs) * 2 + len(B_ARMS) + len(B_ARMS) + len(d_checks)} '
    f'failed={len(failed)}')
if failed:
    say(f'  FAILURES: {failed}')
say(f'SM1_FINAL_SENSITIVITY: '
    f'{"DEFECTS_PRESENT" if failed else "EVERY_CONTROL_DISCRIMINATES"}')
sys.exit(1 if failed else 0)
