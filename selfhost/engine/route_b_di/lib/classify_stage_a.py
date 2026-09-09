#!/usr/bin/env python3
"""Classify Stage A from the structured arm records.

#61: "Prefer structured records over error-string matching... closure of this
prerequisite must not depend only on matching VM/runtime error prose."

So the decision uses only these fields: whether the validate flag was passed,
whether a bytecode artifact was PRODUCED, the compile exit status, and whether
the host then loaded it. The diagnostic message is carried through as evidence
and is reported, but no verdict depends on it.

THE ATTRIBUTION CHAIN. A refusal in a policy arm means "the validation policy
refused" only if all three of these hold:

  positive_full         the identical compile succeeded and the module ran, so
                        the harness is not broken
  positive_full_plus    adding an entry the module does not use still
                        compiles, so the validator is not refusing on any
                        specification difference
  control_no_validate   the same restricted specification with the flag
                        DROPPED compiles, so the refusal is caused by passing
                        the flag and not by the specification breaking the
                        host build or the import dill

If any of those three fails, no policy arm can be called closed, however many
of them refused -- a negative that "fails" where nothing works proves nothing.

usage: classify_stage_a.py <arms.jsonl> <out.json>
"""
import datetime
import json
import pathlib
import sys

arms = {}
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if line.strip():
        a = json.loads(line)
        arms[a['id']] = a
OUT = sys.argv[2]

POLICY = ['policy_no_extendable', 'policy_no_type', 'policy_no_overridable']
INPUT = ['input_empty', 'input_unparseable', 'input_missing']
# Recorded, and deliberately NOT counted toward the policy result: it measures
# specification completeness, not policy enforcement.
COMPLETENESS = 'host_spec_as_module_spec'
findings = []


def get(aid):
    a = arms.get(aid)
    if a is None:
        findings.append(f'{aid}: arm did not run')
    return a


def outcome(a):
    """Derived state of one arm, from status and artifacts only."""
    if a is None:
        return 'ARM_MISSING'
    if a['bytecode_produced']:
        if a['module_compile_exit'] != 0:
            return 'COMPILED_DESPITE_NONZERO_EXIT'
        if a['load_exit'] is None:
            return 'COMPILED_NOT_LOADED'
        if a['load_exit'] == 0:
            return 'COMPILED_AND_LOADED'
        return 'COMPILED_LOAD_REFUSED'
    if a['module_compile_exit'] != 0:
        return 'REFUSED_AT_COMPILE'
    return 'NO_ARTIFACT_ZERO_EXIT'


states = {aid: outcome(a) for aid, a in arms.items()}

# ---- the three attribution preconditions -------------------------------
pos = get('positive_full')
plus = get('positive_full_plus')
ctl = get('control_no_validate')

pre = {
 'HARNESS_POSITIVE_HEALTHY': {
   'value': (pos is not None and states.get('positive_full')
             == 'COMPILED_AND_LOADED' and pos.get('dispatch') == 'PATCH-CHILD'),
   'from': f"positive_full={states.get('positive_full')}, "
           f"dispatch={pos.get('dispatch') if pos else None} "
           '(PATCH-CHILD proves the module really ran and overrode the host)',
 },
 'VALIDATOR_IGNORES_IRRELEVANT_SPEC_DELTA': {
   'value': states.get('positive_full_plus') == 'COMPILED_AND_LOADED',
   'from': f"positive_full_plus={states.get('positive_full_plus')} -- an entry "
           'the module never uses was added and it still compiled and ran',
 },
 'REFUSAL_IS_CAUSED_BY_THE_FLAG': {
   'value': states.get('control_no_validate') in (
       'COMPILED_AND_LOADED', 'COMPILED_LOAD_REFUSED', 'COMPILED_NOT_LOADED'),
   'from': f"control_no_validate={states.get('control_no_validate')} -- the "
           'same restricted specification with --validate dropped still '
           'produced a module, so a refusal with the flag is attributable to '
           'the flag',
 },
}
attribution_ok = all(v['value'] for v in pre.values())
if not attribution_ok:
    findings.append(
        'attribution preconditions not met: '
        f'{[k for k, v in pre.items() if not v["value"]]} -- no policy arm may '
        'be called closed')

# ---- the owned policy arms ---------------------------------------------
policy = {}
for aid in POLICY:
    a = get(aid)
    st = states.get(aid, 'ARM_MISSING')
    # The flag is part of the claim. An arm that refused WITHOUT --validate
    # refused for some other reason and cannot be evidence that the validator
    # closes anything.
    flagged = bool(a and a.get('validate_flag_passed'))
    closed = attribution_ok and st == 'REFUSED_AT_COMPILE' and flagged
    policy[aid] = {
        'state': st,
        'closed_by_validator': closed,
        'validate_flag_passed': a['validate_flag_passed'] if a else None,
        'spec': a['spec'] if a else None,
        'spec_sha256': a['spec_sha256'] if a else None,
        'module_compile_exit': a['module_compile_exit'] if a else None,
        'bytecode_produced': a['bytecode_produced'] if a else None,
        'load_exit': a['load_exit'] if a else None,
        'dispatch': a['dispatch'] if a else None,
        # Diagnostic only. Nothing above depends on it.
        'diagnostic_first_line': ((a['module_compile_message'] or '')
                                  .strip().splitlines() or [''])[0][:200]
        if a else None,
    }
    if a and not a['validate_flag_passed']:
        findings.append(f'{aid}: ran without --validate; the arm is void')

# ---- was an "open" arm actually VACUOUS? -------------------------------
# G6A's no_type arm withdraws can-be-used-as-type for n_host.Base, but
# m_ok.dart never uses Base as a TYPE -- it only EXTENDS it, which the
# validator governs under `extendable`. So there is nothing for the validator
# to refuse and the arm measures nothing. That is a different fact from "the
# validator does not enforce the rule", and conflating them would either
# excuse a real gap or invent one.
#
# The distinction is settled structurally by two NEW arms over m_type.dart --
# m_ok plus one type annotation: the rule is enforced iff the positive
# compiles and the withdrawn-permission case refuses. The historical arm is
# left exactly as it was; it is never re-pointed at the new module.
rule_pos = states.get('rule_type_positive')
rule_wd = states.get('rule_type_withdrawn')
type_rule_enforced = (rule_pos == 'COMPILED_AND_LOADED'
                      and rule_wd == 'REFUSED_AT_COMPILE')
vacuous = {}
if (policy['policy_no_type']['state'] == 'COMPILED_AND_LOADED'
        and type_rule_enforced):
    vacuous['policy_no_type'] = {
        'why': 'm_ok.dart never uses n_host.Base as a type, so withdrawing '
               'can-be-used-as-type withdraws a permission the module does '
               'not exercise. The historical FAIL_OPEN measured nothing.',
        'rule_enforced_on_a_module_that_does_exercise_it': True,
        'evidence': {'rule_type_positive': rule_pos,
                     'rule_type_withdrawn': rule_wd,
                     'module': 'm_type.dart = m_ok.dart + one Base type '
                               'annotation'},
    }
    policy['policy_no_type']['vacuous_arm'] = True

closed = [k for k, v in policy.items() if v['closed_by_validator']]
vacuous_ids = sorted(vacuous)
open_still = [k for k, v in policy.items()
              if not v['closed_by_validator'] and k not in vacuous]

# member_not_overridable's historical failure was a SILENT BYPASS: the module
# built and loaded and the host implementation answered. Closing it means that
# artifact must not exist, so a successful load is checked explicitly.
silent_bypass_survives = (
    policy['policy_no_overridable']['bytecode_produced'] is True
    and policy['policy_no_overridable']['load_exit'] == 0)
if silent_bypass_survives:
    findings.append(
        'policy_no_overridable still builds AND loads: the '
        'FAIL_OPEN_SILENT_BYPASS survived, which is the exact failure this '
        'issue exists to eliminate')

# ---- input integrity, a separate category ------------------------------
inputs = {}
for aid in INPUT:
    st = states.get(aid, 'ARM_MISSING')
    inputs[aid] = {'state': st, 'refused': st == 'REFUSED_AT_COMPILE'}
    if st in ('COMPILED_AND_LOADED', 'COMPILED_NOT_LOADED',
              'COMPILED_LOAD_REFUSED'):
        findings.append(
            f'{aid}: a bad specification still produced a module -- '
            'unusable validation input must refuse, never compile '
            'unvalidated')
input_ok = all(v['refused'] for v in inputs.values())

# ---- the adjacent arm stays its own thing ------------------------------
adj = get('adjacent_no_callable')
adjacent = {
    'state': states.get('adjacent_no_callable'),
    'note': 'Recorded and NOT counted toward the policy result. G6A closed '
            'this at load as IMPORT_RESOLUTION; converting it into a '
            'dynamic-interface policy pass merely to make this lane green is '
            'what #61 forbids.',
    'load_exit': adj['load_exit'] if adj else None,
    'bytecode_produced': adj['bytecode_produced'] if adj else None,
}

# ---- the Stage A result ------------------------------------------------
if not attribution_ok:
    stage_a = 'BASELINE_OR_ATTRIBUTION_NOT_ESTABLISHED'
elif open_still:
    # A genuinely unrefused violation. This is the validator falling short.
    stage_a = 'VALIDATOR_CLOSES_SOME'
elif not input_ok:
    stage_a = 'SPECIFICATION_INPUT_NOT_FAIL_CLOSED'
elif len(closed) == len(POLICY):
    stage_a = 'VALIDATOR_CLOSES_ALL_THREE'
elif vacuous_ids and len(closed) + len(vacuous_ids) == len(POLICY):
    # Every historical arm is accounted for: refused where the module
    # violates, and shown vacuous where it does not -- with the rule itself
    # separately demonstrated enforced. Deliberately NOT reported as
    # ALL_THREE: one of the three historical arms was never a test, and that
    # is the PM's call to accept, not mine to round up.
    stage_a = 'VALIDATOR_CLOSES_ALL_EXERCISED_ONE_ARM_VACUOUS'
else:
    stage_a = 'VALIDATOR_CLOSES_NONE'

doc = {
    'schema': 'route-b-di-1/stage-a/1',
    'issue': 61, 'stage': 'A',
    'generated': datetime.datetime.now(datetime.timezone.utc)
                 .strftime('%Y-%m-%dT%H:%M:%SZ'),
    'decides_from': 'validate_flag_passed, bytecode_produced, '
                    'module_compile_exit, load_exit. NOT the diagnostic text.',
    'stage_a_result': stage_a,
    'attribution_preconditions': pre,
    'attribution_established': attribution_ok,
    'arm_states': states,
    'owned_policy_arms': policy,
    'policy_closed': closed,
    'policy_still_open': open_still,
    'policy_vacuous_arms': vacuous,
    'type_rule_enforced_on_exercising_module': type_rule_enforced,
    'silent_bypass_survives': silent_bypass_survives,
    'specification_input_arms': inputs,
    'specification_input_all_refused': input_ok,
    'adjacent_import_resolution_arm': adjacent,
    'host_specification_completeness': {
        'arm': COMPLETENESS,
        'state': states.get(COMPLETENESS),
        'refused_the_positive_module': states.get(COMPLETENESS)
            == 'REFUSED_AT_COMPILE',
        'note': "G6A's di_full.yaml was written for gen_kernel "
                '--dynamic-interface, which annotates rather than validates. '
                'If it refuses the POSITIVE module here, the host '
                'specification is not by itself a module-validation '
                'specification -- which is a direct input to Stage B, because '
                'Route B would have to obtain a COMPLETE specification and '
                'not merely the one the host build already uses.',
    },
    'out_of_scope': {
        'HOST_IDENTITY': ['wrong_platform_dill', 'wrong_runtime_build'],
        'why': '#61 explicitly does not own these and they are neither '
               'counted as success nor as failure here.',
    },
    'findings': findings,
    'arms': arms,
}
json.dump(doc, open(OUT, 'w'), indent=2)

w = sys.stdout.write
w('  ATTRIBUTION PRECONDITIONS (all three must hold before any arm counts)\n')
for k, v in pre.items():
    w(f'    {str(v["value"]):5}  {k}\n           {v["from"]}\n')
w(f'\n  attribution established: {attribution_ok}\n')
w('\n  OWNED POLICY ARMS\n')
for k, v in policy.items():
    w(f'    {"CLOSED" if v["closed_by_validator"] else "OPEN  "}  {k:24} '
      f'{v["state"]:32} exit={v["module_compile_exit"]} '
      f'produced={v["bytecode_produced"]} load={v["load_exit"]}\n')
    if v['diagnostic_first_line']:
        w(f'            diagnostic (evidence only): '
          f'{v["diagnostic_first_line"]}\n')
w(f'\n  closed={len(closed)}/{len(POLICY)}  vacuous={len(vacuous_ids)}  '
  f'still_open={len(open_still)}  '
  f'silent_bypass_survives={silent_bypass_survives}\n')
if vacuous:
    w('\n  VACUOUS ARMS -- the module does not exercise the withdrawn '
      'permission\n')
    for k, v in vacuous.items():
        w(f'    {k}\n      {v["why"]}\n')
        w(f'      rule enforced on a module that DOES exercise it: '
          f'positive={rule_pos}, withdrawn={rule_wd}\n')
w('\n  SPECIFICATION INPUT ARMS (separate category from policy)\n')
for k, v in inputs.items():
    w(f'    {"REFUSED" if v["refused"] else "ACCEPTED"}  {k:22} {v["state"]}\n')
w(f'\n  ADJACENT: adjacent_no_callable = {adjacent["state"]} '
  f'(load_exit={adjacent["load_exit"]}) -- not counted\n')
if findings:
    w('\n  FINDINGS\n')
    for f in findings:
        w(f'    - {f}\n')
w(f'\nSTAGE_A: {stage_a}\n')
# Both fully-accounted states exit clean; the PM rules on which one counts.
sys.exit(0 if stage_a in ('VALIDATOR_CLOSES_ALL_THREE',
                          'VALIDATOR_CLOSES_ALL_EXERCISED_ONE_ARM_VACUOUS')
         else 1)
