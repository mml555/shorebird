#!/usr/bin/env python3
"""Falsify the Stage A CLASSIFIER, without rebuilding anything.

The arms take minutes each because they compile a host AOT. The classifier is
what turns those records into a verdict, and a classifier that reported
VALIDATOR_CLOSES_* regardless of its input would be the most expensive vacuous
check in this lane -- it would certify the prerequisite closed. So it gets its
own negatives, driven by mutating the recorded arms rather than re-running
them.

Every arm names the field it mutates and the classifier state that must
result. An arm asserting only "something changed" would pass when the wrong
thing changed.

CONTROL: a weakened classifier that hard-codes the baseline result must fail
every arm.

usage: falsify_stage_a.py <arms.jsonl> <classifier.py> <workdir>
"""
import copy
import json
import pathlib
import shutil
import subprocess
import sys

ARMS = pathlib.Path(sys.argv[1])
CLASSIFY = pathlib.Path(sys.argv[2])
W = pathlib.Path(sys.argv[3])
if W.exists():
    shutil.rmtree(W)
W.mkdir(parents=True)

# The per-arm records are persisted inside the classifier's OWN output, under
# `arms` -- the intermediate jsonl lives in a temp directory the harness
# removes. Reading the persisted copy also means these negatives run against
# exactly the evidence the banked verdict was computed from.
_doc = json.loads(ARMS.read_text())
base = [_doc['arms'][k] for k in _doc['arms']]
if not base:
    raise SystemExit('no arm records in the input')


def run(records, tool=CLASSIFY):
    src = W / 'arms.jsonl'
    out = W / 'result.json'
    # Delete first: a crashed classifier must not be scored on the previous
    # arm's output.
    if out.exists():
        out.unlink()
    src.write_text(''.join(json.dumps(r) + '\n' for r in records))
    subprocess.run([sys.executable, str(tool), str(src), str(out)],
                   capture_output=True, text=True)
    if not out.exists():
        return None
    try:
        return json.load(open(out))
    except Exception:                                        # noqa: BLE001
        return None


def mutate(fn):
    """Apply a mutation. `drop` must be used to REMOVE an arm: popping from
    the index left the record in the list, so the missing-arm negative was
    mutating nothing and 'passed' against an unchanged input."""
    recs = copy.deepcopy(base)
    idx = {r['id']: r for r in recs}
    dropped = fn(idx)
    if isinstance(dropped, str):
        recs = [r for r in recs if r['id'] != dropped]
    return recs


def compiled_ok(a):
    a['bytecode_produced'] = True
    a['module_compile_exit'] = 0
    a['load_exit'] = 0


def refused(a):
    a['bytecode_produced'] = False
    a['module_compile_exit'] = 254
    a['load_exit'] = None


ARMS_SPEC = [
 ('weakened-producer-drops-validate',
  lambda i: [i[k].__setitem__('validate_flag_passed', False)
             for k in ('policy_no_extendable', 'policy_no_overridable')],
  lambda d: (d['stage_a_result'] != 'VALIDATOR_CLOSES_ALL_EXERCISED_ONE_ARM_VACUOUS'
             and any('void' in f for f in d['findings'])),
  '#61 requirement 4: a producer that drops --validate must be caught. Arms '
  'that ran without the flag are void, whatever they observed.'),

 ('positive-does-not-load',
  lambda i: i['positive_full'].__setitem__('load_exit', 1),
  lambda d: (d['attribution_established'] is False
             and d['policy_closed'] == []),
  'A negative that "fails" in a harness where the positive does not work '
  'proves nothing, so no arm may be counted closed.'),

 ('positive-loads-but-host-answered',
  lambda i: i['positive_full'].__setitem__('dispatch', 'AOT-BASE'),
  lambda d: d['attribution_established'] is False,
  'The module must actually override: AOT-BASE means the host answered, so '
  'the positive did not demonstrate what it claims.'),

 ('validator-refuses-irrelevant-delta',
  lambda i: refused(i['positive_full_plus']),
  lambda d: d['attribution_established'] is False,
  'If adding an entry the module never uses causes a refusal, the validator '
  'refuses on any specification difference and every negative is closed for '
  'the wrong reason.'),

 ('flag-control-also-refuses',
  lambda i: refused(i['control_no_validate']),
  lambda d: d['attribution_established'] is False,
  'If the restricted specification refuses even WITHOUT --validate, the '
  'refusal is not attributable to the flag -- it broke something else.'),

 ('silent-bypass-survives',
  lambda i: compiled_ok(i['policy_no_overridable']),
  lambda d: (d['silent_bypass_survives'] is True
             and 'policy_no_overridable' in d['policy_still_open']
             and d['stage_a_result'] == 'VALIDATOR_CLOSES_SOME'),
  'The historical FAIL_OPEN_SILENT_BYPASS built AND loaded. That is the exact '
  'failure this issue exists to eliminate and must not read as closed.'),

 ('type-rule-not-enforced-so-arm-not-vacuous',
  lambda i: compiled_ok(i['rule_type_withdrawn']),
  lambda d: (d['type_rule_enforced_on_exercising_module'] is False
             and 'policy_no_type' in d['policy_still_open']
             and d['stage_a_result'] == 'VALIDATOR_CLOSES_SOME'),
  'Vacuity is only an excuse if the RULE is separately shown enforced. With a '
  'module that does exercise it still compiling, no_type is a real gap.'),

 ('specification-input-accepted',
  lambda i: compiled_ok(i['input_unparseable']),
  lambda d: (d['specification_input_all_refused'] is False
             and d['stage_a_result'] == 'SPECIFICATION_INPUT_NOT_FAIL_CLOSED'),
  'An unparseable specification that still produces a module means the '
  'producer compiled unvalidated.'),

 ('policy-arm-missing-entirely',
  lambda i: 'policy_no_extendable',   # returned id -> dropped from the list
  lambda d: (d['owned_policy_arms']['policy_no_extendable']['state']
             == 'ARM_MISSING'
             and any('did not run' in f for f in d['findings'])),
  'An arm that never ran must be reported missing, never counted as absent '
  'of violations.'),

 ('adjacent-arm-not-folded-into-policy',
  lambda i: compiled_ok(i['adjacent_no_callable']),
  # Strengthened: the original check was satisfied by a classifier that
  # reported NOTHING, which is how the weakened control survived it. It must
  # now also show the real policy arms still classified and the adjacent arm
  # recorded in its own field.
  lambda d: ('adjacent_no_callable' not in d['policy_closed']
             and 'adjacent_no_callable' not in d['policy_still_open']
             and set(d['owned_policy_arms']) == {
                 'policy_no_extendable', 'policy_no_type',
                 'policy_no_overridable'}
             and d['adjacent_import_resolution_arm']['state']
             == 'COMPILED_AND_LOADED'),
  '#61: the import-resolution arm stays independently classified and must not '
  'be converted into a policy pass to make the lane green.'),
]

print('ROUTE-B-DI-1 / Stage A -- classifier falsification')
print(f'  {len(ARMS_SPEC)} arms, mutating the recorded evidence only.\n')
baseline = run(base)
if baseline is None:
    raise SystemExit('  baseline classification produced nothing')
BASE_RESULT = baseline['stage_a_result']
print(f'  baseline: {BASE_RESULT}')
print(f'  attribution={baseline["attribution_established"]} '
      f'closed={baseline["policy_closed"]} '
      f'vacuous={sorted(baseline["policy_vacuous_arms"])}\n')

failed = []
for name, mut, check, why in ARMS_SPEC:
    d = run(mutate(mut))
    ok = d is not None and bool(check(d))
    if not ok:
        failed.append(name)
    got = d['stage_a_result'] if d else 'NO-OUTPUT'
    print(f'  {"pass" if ok else "FAIL"}  {name:44} -> {got}')
    print(f'        {why}')

print('\n  CONTROL -- a classifier hard-coding the baseline must fail every arm')
weak = W / 'weak_classify.py'
weak.write_text(
    'import json,sys\n'
    f"json.dump({{'stage_a_result': {BASE_RESULT!r},\n"
    "  'attribution_established': True, 'policy_closed': [],\n"
    "  'policy_still_open': [], 'policy_vacuous_arms': {},\n"
    "  'owned_policy_arms': {}, 'findings': [],\n"
    "  'silent_bypass_survives': False,\n"
    "  'adjacent_import_resolution_arm': {'state': None},\n"
    "  'type_rule_enforced_on_exercising_module': True,\n"
    "  'specification_input_all_refused': True},\n"
    "  open(sys.argv[2],'w'))\n")
survivors = []
for name, mut, check, _why in ARMS_SPEC:
    d = run(mutate(mut), tool=weak)
    try:
        if d is not None and check(d):
            survivors.append(name)
    except Exception:                                        # noqa: BLE001
        pass
print(f'    arms the weakened classifier still satisfies: {len(survivors)}')
if survivors:
    print(f'    SURVIVORS: {survivors}')
    failed.append(f'weakened classifier satisfied {survivors}')
else:
    print('    pass  it satisfies none')

print(f'\n  arms={len(ARMS_SPEC)} failed={len(failed)}')
if failed:
    print(f'  FAILURES: {failed}')
print(f'STAGE_A_FALSIFICATION: '
      f'{"DEFECTS_PRESENT" if failed else "EVERY_ARM_DISCRIMINATES"}')
sys.exit(1 if failed else 0)
