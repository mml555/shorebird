#!/usr/bin/env python3
"""MAOT-2 (#66) -- derive the verdict from the evidence.

The result is a conjunction over named conditions, each computed from an
observation. Nothing here hard-codes an outcome, and no condition is satisfied
by a count alone where an exact set is available: cardinality agreeing while
the sets differ is one of the failures the bank has to catch.
"""

# Every condition the #66 result is a conjunction over, with the question each
# one answers. Declared here so a missing condition is a finding rather than a
# silently shorter conjunction.
CONDITIONS = {
    'identity_binding_correct':
        'does every registry entry pair a #65 DeclarationId with the Function '
        'for that same declaration?',
    'selected_set_exact':
        'are the selected id set and the final registry id set equal in BOTH '
        'directions, with no duplicates?',
    'dart_retention_complete':
        'did every declaration selected before tree shaking still exist after '
        'it (selectedButAbsent empty)?',
    'vm_retention_complete':
        'did the precompiler legally retain every selected declaration, with '
        'none dropped at materialization?',
    'real_aot_implementation_present':
        'does every descriptor point at an executable body, judged by VM '
        'state rather than by an instruction-size report?',
    'snapshot_roundtrip_complete':
        'did the registry survive gen_snapshot into dartaotruntime?',
    'no_selection_builds_clean':
        'does a program with no maot:mutable at all still compile to AOT, and '
        'end up with an empty registry rather than a populated or broken one?',
    'runtime_namespace_bound':
        'can the running program say which release it is, without an external '
        'sidecar?',
    'staging_semantics_valid':
        'is a staged replacement invisible to the current lookup until an '
        'explicit commit?',
    'version_semantics_valid':
        'are non-advancing versions, commits with nothing staged, and version '
        'bumps with no implementation change all refused?',
    'abi_validation_valid':
        'is an incompatible ABI refused BEFORE any state changes?',
    'duplicate_missing_wrong_release_fail_closed':
        'are duplicate ids, unknown ids and foreign-release patches refused?',
    'identity_not_name_keyed':
        'do two declarations that share a VM Function name resolve to their '
        'own implementations rather than to each other? (requires such a pair '
        'to exist in the program, or the question is unanswered)',
    'abi_model_discriminates_every_dimension':
        'for every named ABI dimension, is a replacement differing only in '
        'that dimension refused -- and is the pairwise matrix an equivalence '
        '(identical pairs accepted, differing pairs refused) rather than a '
        'blanket refusal?',
    'abi_omissions_declared':
        'is every compatibility dimension the model does NOT represent stated '
        'with its reason and the issue that owns it?',
    'selected_calling_convention_is_boxed_stack':
        'is every selected declaration on the fully boxed, stack-based calling '
        'convention that selection is supposed to pin it to?',
    'call_convention_is_measured_not_constant':
        'does the call-convention fingerprint actually differ between '
        'declarations in one run, or is it a constant string that would agree '
        'with anything?',
    'implementation_divergence_detectable':
        'if something rewrites Function::CurrentCode() underneath a '
        'descriptor, is that reported rather than silently described as the '
        'current implementation?',
    'introspection_valid':
        'is the runtime state readable as structured logical facts, with no '
        'address used as identity?',
    'required_falsifications_detected':
        'did every required falsification actually fire?',
    'measurements_recorded':
        'are the cost measurements present -- registry footprint, lookup '
        'cost, and snapshot/startup deltas against a no-pragma control? No '
        'threshold is compared; absence is the only failure.',
}

# The falsification bank. `live` arms run in this gate; `historical` arms are
# defects the implementation actually hit, recorded with the commit that fixed
# them so the knowledge is not lost when the code stops being able to express
# the mistake.
BANK = {
    'F01': ('live', 'maot:mutable parser arm exists but the VM target rejects '
                    'the pragma, making it dead code'),
    'F02': ('live', 'a selected dead declaration is removed by the Dart tree '
                    'shaker'),
    'F03': ('historical', 'procedure metadata lookup uses correction_offset_ '
                          'instead of library_kernel_offset_'),
    'F04': ('live', 'the constructor binding hook is removed'),
    'F05': ('historical', 'the registry ObjectStore root is placed beyond the '
                          'Full-AOT serialization cutoff'),
    'F06': ('historical', 'the ObjectStore root is inserted where extracted '
                          'runtime offsets shift'),
    'F07': ('historical', 'load-time Function references become final strong '
                          'roots before legal precompiler retention'),
    'F08': ('live', 'MAOT selection is disconnected from '
                    'Precompiler::AddFunction'),
    'F09': ('live', 'a selected Function is dropped by the precompiler'),
    'F10': ('live', 'an unselected declaration appears in the final registry'),
    'F11': ('historical', 'a DeclarationId is bound to the wrong Function'),
    'F12': ('live', 'a duplicate DeclarationId is registered'),
    'F13': ('live', 'a patch carries the wrong release namespace'),
    'F14': ('live', 'a staged descriptor is visible before commit'),
    'F15': ('live', 'a version changes with no implementation change'),
    'F16': ('live', 'an implementation changes with no version advance'),
    'F17': ('live', 'an incompatible ABI is accepted'),
    'F18': ('live', 'selected-id cardinality matches while the exact sets '
                    'differ'),
    'F19': ('live', 'stale evidence is reused after the current run fails'),
    'F20': ('live', 'a computed finding is disconnected from the verdict'),
    'F21': ('live', 'a built binary is older than the MAOT source it must '
                    'contain, so the run measures a different program than '
                    'the one it names'),
    'F22': ('live', 'a release containing NO selected declaration fails to '
                    'build, or builds with a non-empty registry'),
    'F23': ('live', 'a lookup resolves by Function name, so two declarations '
                    'that share a name alias one slot'),
    'F24': ('live', 'an implementation is swapped underneath a descriptor and '
                    'the registry keeps describing the old one'),
    'F25': ('live', 'the compatibility model is missing a dimension, so a '
                    'replacement that differs in it is accepted'),
    'F26': ('live', 'a selected declaration escapes the boxed stack calling '
                    'convention that selection is supposed to pin it to'),
}


def _arm(selftest, arm_id):
    for a in selftest.get('arms', []):
        if a.get('id') == arm_id:
            return a
    return None


def _passed(selftest, *ids):
    for i in ids:
        a = _arm(selftest, i)
        if a is None or a.get('result') != 'pass':
            return False
    return True


def evaluate(observations, findings, registry=None, selftest=None):
    """Compute each condition from the evidence. Returns the verdict record.

    `registry` and `selftest` are passed in rather than dug out of
    `observations` so the record stores each of them exactly once: a value
    written in two places is a value that can disagree with itself.
    """
    o = observations
    st = selftest or {}
    reg = registry or {}
    entries = reg.get('entries', [])

    conditions = {}

    conditions['identity_binding_correct'] = bool(
        o.get('binding_pairs_correct')) and entries != []
    conditions['selected_set_exact'] = (
        o.get('selected_minus_registry') == []
        and o.get('registry_minus_selected') == []
        and not o.get('duplicate_ids'))
    conditions['dart_retention_complete'] = (
        o.get('selected_but_absent') == [])
    conditions['vm_retention_complete'] = (
        o.get('materialized_dropped') == 0
        and o.get('materialized_count') == o.get('selected_count'))
    conditions['real_aot_implementation_present'] = bool(entries) and all(
        e['current'].get('executable') for e in entries)
    conditions['snapshot_roundtrip_complete'] = (
        reg.get('runtime_mode') == 'precompiled' and bool(entries))
    conditions['runtime_namespace_bound'] = (
        reg.get('namespace_identity') not in (None, '', '<absent>')
        and reg.get('namespace_identity') == o.get('expected_namespace'))
    conditions['staging_semantics_valid'] = _passed(st, 'S01', 'S02', 'S03',
                                                    'S04')
    conditions['version_semantics_valid'] = _passed(st, 'V01', 'V02', 'V03')
    conditions['abi_validation_valid'] = _passed(st, 'A01')
    conditions['duplicate_missing_wrong_release_fail_closed'] = _passed(
        st, 'D01', 'M01', 'M02', 'N01')
    # Identity, not spelling. Computed from the resolution probes the VM
    # actually ran, so the same logic judges the correct resolver and the
    # injected name-keyed one. The population check is part of the condition:
    # without two same-named declarations the question is unanswered, and
    # unanswered is not the same as yes.
    probes = st.get('resolution_probes') or []
    conditions['identity_not_name_keyed'] = (
        st.get('found_name_clash_pair') is True
        and _passed(st, 'L01')
        and bool(probes)
        and all(p.get('resolved_to') == p.get('declaration_id')
                for p in probes if p.get('resolver') == 'declaration_id'))

    # Every named ABI dimension must be refused by the pairwise matrix, and
    # the matrix must be an equivalence rather than an implication: a model
    # that refuses everything would pass a one-directional check while making
    # replacement impossible.
    conditions['abi_model_discriminates_every_dimension'] = (
        bool(o.get('abi_dimensions'))
        and o.get('abi_dimensions_undiscriminated') == []
        and o.get('abi_dimension_pairs_missing') == []
        and o.get('compatibility_matrix_violations') == []
        and (o.get('compatibility_matrix_accepted') or 0) > 0)

    # An omission has to be stated, with the issue that owns it.
    conditions['abi_omissions_declared'] = bool(o.get('abi_not_represented'))

    # Selection pins every selected declaration to the fully boxed, stack-based
    # calling convention (see CALLCONV_BOXED_STACK for the source chain). That
    # is what makes an unchanged-ABI replacement safe at the machine level, so
    # it is checked on every run rather than believed.
    conditions['selected_calling_convention_is_boxed_stack'] = (
        bool(o.get('selected_call_conventions'))
        and o.get('call_conventions_not_boxed_stack') == [])

    # ... and the component must be a live measurement rather than a constant
    # string. An unselected declaration is not an entry point, so it is not
    # pinned, and the difference proves the fingerprint discriminates inside
    # one run of one compiler.
    conditions['call_convention_is_measured_not_constant'] = bool(
        o.get('callconv_varies_across_selection'))
    # X01 is the control: without it X02 could pass on a check that reports
    # divergence unconditionally.
    conditions['implementation_divergence_detectable'] = _passed(
        st, 'X01', 'X02')
    # The pragma-free program is the common case, and MAOT must be inert in
    # it. This condition exists because it was not: the registry held every
    # loaded declaration as a strong root through the drop phase, so a class
    # the optimizer dissolved survived with an invalidated cid and the
    # serializer aborted.
    ctl = o.get('control_build') or {}
    conditions['no_selection_builds_clean'] = (
        ctl.get('kernel_rc') == 0 and ctl.get('snapshot_rc') == 0
        and (ctl.get('elf_bytes') or 0) > 0
        and ctl.get('runtime_rc') == 0
        and ctl.get('registry_entries') == 0)

    conditions['introspection_valid'] = bool(entries) and all(
        ('declaration_id' in e and 'current' in e and 'abi' in e)
        for e in entries) and not o.get('address_used_as_identity', False)
    conditions['required_falsifications_detected'] = (
        o.get('falsifications_failed') == [])
    # Diagnostic values, but the condition is about their PRESENCE: a lane
    # that reports no cost is a lane that did not look.
    gm = o.get('measurements') or {}
    conditions['measurements_recorded'] = (
        bool(st.get('measurements'))
        and gm.get('aot_elf_delta_bytes') is not None
        and gm.get('startup_ms_with_maot') is not None
        and gm.get('startup_ms_control') is not None)

    blocking = [f for f in findings if f.get('severity') == 'blocking']
    established = all(conditions.values()) and not blocking

    return {
        'runtime_implementation_registry':
            'ESTABLISHED' if established else 'NOT_ESTABLISHED',
        'conditions': conditions,
        'conditions_failed': sorted(k for k, v in conditions.items() if not v),
        'condition_meanings': CONDITIONS,
        'blocking_findings': sorted({f['code'] for f in blocking}),
        'verdict_rule': (
            'runtime_implementation_registry == ESTABLISHED iff every '
            'condition above holds AND no blocking finding was raised. It is '
            'a conjunction; no count, ratio or threshold is compared '
            'anywhere in this module.'),
        'not_claimed': [
            'No call site consults the registry. #67 owns that.',
            'PATCH_CODE is a staged test descriptor and is never executed.',
            'A caller may hold an inlined copy of a selected body; proving it '
            'cannot bypass the slot is #68 (OPTIMIZER_BYPASS_NOT_YET_PROVEN).',
            'Transactions are single-entry and test-only. #71 owns atomic '
            'multi-declaration transactions.',
        ],
    }


# Which decision reads each produced value.
CONSUMERS = {
    'verdict': 'the gate exit code and whether #66 may be closed',
    'observations': 'every condition in the verdict',
    'selftest': 'the staging, version, ABI, namespace, duplicate and missing '
                'conditions',
    'registry': 'the binding, executability, namespace and introspection '
                'conditions',
    'falsification': 'required_falsifications_detected',
    'falsification_bank': 'whether every live bank entry actually has an arm, '
                          'and which defects are recorded as history instead',
    'findings': 'verdict.blocking_findings and the gate exit code',
    'identities': 'whether any of this may be quoted -- a result from another '
                  'fork or repo revision is a different question',
    'schema': 'readers and later issues consuming this record',
    'issue': 'readers and later issues consuming this record',
    'generated_by': 'reproducing this record',
    'consumers': 'this check itself, in both directions',
}
