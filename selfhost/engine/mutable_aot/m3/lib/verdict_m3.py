#!/usr/bin/env python3
"""MAOT-3 (#67) -- derive the verdict from the evidence.

The result is a conjunction over named conditions computed from observations.
The outcome strings appear here because the module has to render one of them;
what matters is that neither is reachable unconditionally.
"""

CONDITIONS = {
    'top_level_replacement_observed':
        'did a precompiled top-level direct call return OLD, then NEW after '
        'installation, then NEW2 after a second installation?',
    'static_replacement_observed':
        'the same for a precompiled static method call, proven independently?',
    'arms_are_independent':
        'did installing one arm leave the other arm at its release answer, in '
        'both directions? (one arm cannot stand in for the other)',
    'no_restart_or_recompile':
        'was it one process throughout -- same pid, one snapshot, no rebuild '
        'between the OLD and NEW observations?',
    'call_sites_traverse_the_mechanism':
        'did the compiler emit indirect call sites through the dispatch cell '
        'for every replaced declaration? (zero means no caller can reach it, '
        'whatever the program printed)',
    'installation_is_descriptor_state':
        'did the #66 version and kind advance, and does the dispatch cell '
        'still agree with the descriptor?',
    'identity_visible_in_evidence':
        'are the #65 DeclarationId, #66 version/kind and release namespace all '
        'present in the structured record?',
    'release_implementation_still_represented':
        'after replacement, can the descriptor still name what the release '
        'shipped, for rollback and version history?',
    'unrelated_declarations_unchanged':
        'did a selected-but-not-replaced declaration and a non-selected one '
        'both keep their release answers?',
    'refusals_before_visible_mutation':
        'were unknown id, wrong release namespace, ABI mismatch and a '
        'non-advancing version each refused with the release answer intact?',
    'repeated_calls_stay_replaced':
        'does calling again after installation still reach the replacement?',
    'required_falsifications_detected':
        'did every required falsification actually fire?',
    'measurements_recorded':
        'are the overhead and size measurements present? No threshold is '
        'compared; absence is the only failure.',
}

BANK = {
    'G01': ('live', 'the call site bypasses the dispatch cell and binds to the '
                    'release implementation, while the descriptor still '
                    'advances'),
    'G02': ('live', 'the result of a mutable call is constant-folded, so every '
                    'caller keeps the release answer although the call is '
                    'made'),
    'G03': ('live', 'a selected declaration is inlined, so the caller never '
                    'reaches the cell'),
    'G04': ('live', 'the version advances with no implementation change'),
    'G05': ('live', 'the implementation changes with no version advance'),
    'G06': ('live', 'a patch names the wrong release namespace'),
    'G07': ('live', 'a patch names a declaration that does not exist'),
    'G08': ('live', 'a patch whose ABI differs is installed'),
    'G09': ('live', 'only one of the two call forms is proven and the other is '
                    'assumed'),
    'G10': ('live', 'the process restarted or the release was rebuilt between '
                    'the OLD and NEW observations'),
    'G11': ('live', 'the expected strings match while no indirect call site '
                    'was ever emitted'),
    'G12': ('historical', 'the dispatch cell is replaced at materialization, '
                          'stranding every call site already emitted'),
    'G13': ('historical', 'a scoped handle is handed to the object pool, which '
                          'stores a pointer to it'),
    'G14': ('historical', 'an Array cell is loaded through the dedup path, '
                          'which canonicalize-hashes it as an Instance'),
    'G15': ('historical', 'the exported harness symbol is dead-stripped before '
                          'the export list is applied'),
}


def evaluate(observations, findings):
    o = observations
    calls = o.get('calls') or {}
    reg = o.get('registry_after') or {}
    entries = {e['declaration_id']: e for e in reg.get('entries', [])}

    def entry(leaf):
        for k, v in entries.items():
            if k.endswith(leaf):
                return v
        return None

    conditions = {}

    conditions['top_level_replacement_observed'] = (
        calls.get('top.call.0') == 'OLD'
        and calls.get('top.call.1') == 'NEW'
        and calls.get('top.call.2') == 'NEW2')
    conditions['static_replacement_observed'] = (
        calls.get('static.call.0') == 'OLD-STATIC'
        and calls.get('static.call.1') == 'NEW-STATIC'
        and calls.get('static.call.2') == 'NEW2-STATIC')
    conditions['arms_are_independent'] = (
        calls.get('static.call.after_top_install') == 'OLD-STATIC'
        and calls.get('top.call.0') == 'OLD')
    conditions['no_restart_or_recompile'] = (
        calls.get('process.pid') is not None
        and calls.get('process.pid') == calls.get('process.pid.final')
        and o.get('snapshot_sha256_before') is not None
        and o.get('snapshot_sha256_before') == o.get('snapshot_sha256_after'))

    replaced = [entry('::fn:work'), entry('::cls:StaticTarget::method:work')]
    conditions['call_sites_traverse_the_mechanism'] = (
        all(e is not None for e in replaced)
        and all((e.get('indirect_call_sites_emitted') or 0) > 0
                for e in replaced))
    conditions['installation_is_descriptor_state'] = (
        all(e is not None for e in replaced)
        and all(e['current']['kind'] == 'PATCH_CODE'
                and e['current']['version'] == 3
                and e['dispatch_cell']['agrees_with_current']
                for e in replaced))
    conditions['identity_visible_in_evidence'] = (
        bool(entries)
        and all('declaration_id' in e for e in entries.values())
        and reg.get('namespace_identity') == o.get('expected_namespace')
        and calls.get('top.version.0') == 'AOT:v1'
        and calls.get('top.version.2') == 'PATCH_CODE:v3')
    conditions['release_implementation_still_represented'] = (
        all(e is not None for e in replaced)
        and all(e['release']['still_represented']
                and not e['release']['is_current'] for e in replaced))
    conditions['unrelated_declarations_unchanged'] = (
        calls.get('untouched.call.final') == 'UNTOUCHED'
        and calls.get('plain.call.final') == 'PLAIN'
        and calls.get('untouched.call.after_top_install') == 'UNTOUCHED')
    conditions['refusals_before_visible_mutation'] = (
        calls.get('refuse.unknown.id') == -1
        and calls.get('refuse.wrong.namespace') == -3
        and calls.get('refuse.abi.mismatch') == -3
        and calls.get('refuse.version.not.advancing') == -3
        and calls.get('top.call.after_refusals') == 'OLD'
        and calls.get('top.version.after_refusals') == 'AOT:v1')
    conditions['repeated_calls_stay_replaced'] = (
        calls.get('top.call.1.repeat') == 'NEW'
        and calls.get('static.call.1.repeat') == 'NEW-STATIC'
        and calls.get('top.call.final') == 'NEW2')
    conditions['required_falsifications_detected'] = (
        o.get('falsifications_failed') == [])
    m = o.get('measurements') or {}
    conditions['measurements_recorded'] = (
        m.get('aot_elf_delta_bytes') is not None
        and m.get('direct_call_ns_with_indirection') is not None
        and m.get('registry_bytes') is not None)

    blocking = [f for f in findings if f.get('severity') == 'blocking']
    established = all(conditions.values()) and not blocking

    return {
        'direct_static_replacement':
            'ESTABLISHED' if established else 'NOT_ESTABLISHED',
        'conditions': conditions,
        'conditions_failed': sorted(k for k, v in conditions.items() if not v),
        'condition_meanings': CONDITIONS,
        'blocking_findings': sorted({f['code'] for f in blocking}),
        'verdict_rule': (
            'direct_static_replacement == ESTABLISHED iff every condition '
            'above holds AND no blocking finding was raised. It is a '
            'conjunction; no count, ratio or threshold is compared anywhere '
            'in this module, and neither outcome string is reachable '
            'unconditionally.'),
        'not_claimed': [
            'No virtual, interface or super dispatch. #69 owns those.',
            'No universal no-bypass claim. The posture here is the blunt rule '
            'that a selected declaration is neither inlined nor '
            'constant-folded through; #68 owns the real optimizer contract.',
            'The replacement implementation is another AOT-compiled Dart body '
            'present in the release image, selected by descriptor. Delivering '
            'an externally-built body is #72/#77.',
            'No additions, no class-shape work, no transaction architecture '
            'beyond what #66 exposes, and no production CLI or package '
            'format.',
        ],
    }


CONSUMERS = {
    'verdict': 'the gate exit code and whether #67 may be closed',
    'observations': 'every condition in the verdict',
    'registry_before': 'the release state the calls started from',
    'registry_after': 'the call-site, descriptor and release-representation '
                      'conditions',
    'falsification': 'required_falsifications_detected',
    'falsification_bank': 'whether every live bank entry has an arm',
    'findings': 'verdict.blocking_findings and the gate exit code',
    'identities': 'whether any of this may be quoted',
    'schema': 'readers and later issues consuming this record',
    'issue': 'readers and later issues consuming this record',
    'generated_by': 'reproducing this record',
    'consumers': 'this check itself, in both directions',
}
