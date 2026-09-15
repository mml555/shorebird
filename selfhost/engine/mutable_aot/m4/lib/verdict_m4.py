#!/usr/bin/env python3
"""MAOT-4 (#68) -- derive the verdicts from the evidence.

Two verdicts, for the reason #67 learned: a true technical result must not be
able to carry an untrue milestone claim.

  arm64_aot_optimizer_invariants   the Phase A posture, on this architecture
  issue_68_closure                 that, plus every acceptance item met
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rules_m4 as R          # noqa: E402

TARGET_ARCH = 'arm64'

# #68 hardens the cell #67 linked; it adds none. EB-01/EB-02 stay UNMODELED,
# and RS-09 stays UNMODELED because giving it modes would be a change to a
# closed corpus.
T0_ROW_LINKAGE = {
    'EB-01': {
        'row_title': 'top-level function body',
        'covered_by_issue_68': {
            'dispatch': ['direct'], 'compilation': ['aot'],
            'heat': ['cold', 'hot'], 'target_arch': [TARGET_ARCH],
        },
        'not_covered': ['tearoff_pre', 'tearoff_post', 'dynamic', 'jit'],
        'row_result_after_68': 'UNMODELED',
        'what_68_adds': 'the same cell as #67, hardened: the conservative '
                        'posture is an enforced per-pass rule with a '
                        'falsification per optimization class, not a property '
                        'that happened to hold for one fixture',
    },
    'EB-02': {
        'row_title': 'static method body',
        'covered_by_issue_68': {
            'dispatch': ['direct'], 'compilation': ['aot'],
            'heat': ['cold', 'hot'], 'target_arch': [TARGET_ARCH],
        },
        'not_covered': ['tearoff_pre', 'tearoff_post', 'dynamic', 'jit'],
        'row_result_after_68': 'UNMODELED',
        'what_68_adds': 'same',
    },
    'RS-09': {
        'row_title': 'inline caches and dispatch specialization state',
        'covered_by_issue_68': {},
        'not_covered': ['every mode -- the row is scaffolded with none'],
        'row_result_after_68': 'UNMODELED',
        'what_68_adds': 'nothing. Giving this row modes would be a change to '
                        'a closed corpus, and the runtime dispatch semantics '
                        'it names belong to #69.',
    },
}

CONDITIONS = {
    'every_optimizer_class_has_a_rule':
        'does every optimizer class #68 names have a rule with an enforcement '
        'site, a disposition, a producer, a consumer and a falsification?',
    'blocking_dispositions_actually_block':
        'measured, not read from the enum: does each blocking disposition '
        'produce an install refusal, and does SLOT_PRESERVING not?',
    'conservative_posture_holds':
        'do all the adversarial variants -- prefer-inline callee, '
        'constant-return callee, nested chain, mutable caller with immutable '
        'callee and the inverse -- observe their replacements?',
    'hot_sites_observe_replacement':
        'do heavily-executed precompiled call sites observe it too, after '
        'enough iterations to specialize?',
    'second_replacement_advances':
        'does a second install move the version again and execute the second '
        'body?',
    'devirtualization_join_present':
        'for the devirtualized target, does the record carry BOTH a '
        'devirtualization and a static-call-lowering decision, same target '
        'and caller, both SLOT_PRESERVING?',
    'unmodeled_dispatch_blocks_install':
        'is a selected instance member recorded UNMODELED_BLOCKING and its '
        'installation refused, until #69?',
    'dead_release_declaration_addressable':
        'is a declaration the release never calls still installable, with its '
        'version advancing?',
    'escape_metadata_is_consumed':
        'does removing the detection, the consumption, or the state at '
        'materialization each let a bypass install successfully? Metadata '
        'nobody reads must fail exactly like no metadata.',
    'blocking_record_survives_to_the_consumer':
        'when a blocking decision exists, does its escape projection survive '
        'into the descriptor AND does the real install decision refuse? A '
        'consumed_by string alone must never satisfy this.',
    'optimized_and_conservative_agree':
        'do the optimized build and a conservative AOT control produce '
        'identical mutation semantics?',
    'required_falsifications_detected':
        'did every required falsification actually fire?',
    'measurements_recorded':
        'are the size, compile-time, call-cost and prevented-optimization '
        'counts present? No threshold is compared.',
    'build_provenance_bound':
        'were the binaries built from the exact MAOT source bytes the record '
        'names?',
    'target_architecture_recorded':
        'does the record say which architecture this was proven on?',
    't0_linkage_exact_and_unpromoted':
        'is the #64 linkage exactly the demonstrated modes, with EB-01, '
        'EB-02 and RS-09 all left UNMODELED?',
}

BANK = {
    'H01': ('live', 'a bypassed dispatch cell goes undetected because escape '
                    'detection is disabled'),
    'H02': ('live', 'escape metadata is produced but no install decision '
                    'reads it'),
    'H03': ('live', 'escape state is dropped when the registry is rebuilt at '
                    'materialization'),
    'H04': ('live', 'a constant result is folded through a mutable boundary, '
                    'so the call reaches the cell and the caller ignores it'),
    'H05': ('live', 'DEPENDENCY_REQUIRED admits an optimization with no '
                    'dependency token and no consumer'),
    'H06': ('live', 'UNMODELED_BLOCKING does not block'),
    'H07': ('live', 'the disposition model blocks everything, so blocking '
                    'carries no information'),
    'H08': ('live', 'an instance member is installable although no '
                    'instance-call path traverses the cell'),
    'H09': ('live', 'a devirtualized call is claimed slot-preserving with no '
                    'static-call-lowering record to join'),
    'H10': ('live', 'a vm:prefer-inline mutable callee is inlined, so its '
                    'caller cannot observe a replacement'),
    'H11': ('live', 'a whole #64 row is promoted from evidence covering one '
                    'of its dispatch modes'),
    'H12': ('live', 'a declaration the release never calls is dropped and '
                    'becomes unpatchable'),
    'H13': ('live', 'the binaries were built from different source bytes than '
                    'the record names'),
    'H14': ('live', 'an optimized and a conservative build disagree about '
                    'mutation semantics'),
}


def evaluate(observations, findings):
    o = observations
    calls = o.get('calls') or {}
    dec = o.get('optimizer_decisions') or []
    entries = {e['declaration_id']: e for e in (o.get('registry_after') or {})
               .get('entries', [])}

    def entry(suffix):
        return next((v for k, v in entries.items() if k.endswith(suffix)),
                    None)

    c = {}

    c['every_optimizer_class_has_a_rule'] = (
        bool(R.RULES)
        and all(all(f in v and v[f] for f in R.REQUIRED_FIELDS)
                for v in R.RULES.values())
        and all(v['disposition'] in
                ('FORBIDDEN', 'SLOT_PRESERVING', 'DEPENDENCY_REQUIRED',
                 'UNMODELED_BLOCKING') for v in R.RULES.values()))

    # Measured from the injection runs, not read from the enum.
    disp = o.get('disposition_effects') or {}
    c['blocking_dispositions_actually_block'] = (
        bool(disp)
        and all(disp.get(d, {}).get('install') == -3 for d in R.BLOCKING)
        and disp.get('SLOT_PRESERVING', {}).get('install') == 0)

    c['conservative_posture_holds'] = (
        calls.get('tiny.0') == 'OLD-TINY' and calls.get('tiny.1') == 'NEW-TINY'
        and calls.get('constantish.0') == 'OLD-CONST'
        and calls.get('constantish.1') == 'NEW-CONST'
        and calls.get('chain.0') == 'OLD-A-OLD-B-PLAIN-C'
        and calls.get('chain.1') == 'NEW-A'
        and calls.get('immutableCaller.0') == 'OLD-TINY/OLD-CONST'
        and calls.get('immutableCaller.1') == 'NEW-TINY/NEW-CONST')
    c['hot_sites_observe_replacement'] = (
        calls.get('hot.tiny') == 'NEW-TINY'
        and calls.get('hot.chain') == 'NEW-A'
        and (calls.get('hot.iterations') or 0) >= 100000)
    c['second_replacement_advances'] = (
        calls.get('tiny.2') == 'NEW-CONST'
        and calls.get('tiny.version.2') == 'PATCH_CODE:v3')

    # The join, from the persisted record rather than console output.
    join = o.get('devirtualization_join') or {}
    c['devirtualization_join_present'] = (
        join.get('target') is not None
        and join.get('caller') is not None
        and join.get('devirtualization_slot_preserving', 0) > 0
        and join.get('static_call_lowering_slot_preserving', 0) > 0
        and join.get('instance_dispatch_unmodeled_blocking', 0) > 0
        and join.get('install_refused') is True)

    inst = entry('cls:OnlyShape::method:describe')
    c['unmodeled_dispatch_blocks_install'] = (
        inst is not None and inst.get('installable') is False
        and calls.get('install.devirt') == -3
        and calls.get('devirt.1') == 'OLD-DEVIRT')

    c['dead_release_declaration_addressable'] = (
        calls.get('unreachable.version.0') == 'AOT:v1'
        and calls.get('install.unreachable') == 0
        and calls.get('unreachable.version.1') == 'PATCH_CODE:v2')

    esc = o.get('escape_controls') or {}
    c['escape_metadata_is_consumed'] = (
        esc.get('baseline', {}).get('install') == 0
        and esc.get('bypass', {}).get('install') == -3
        and all(esc.get(k, {}).get('install') == 0
                and esc.get(k, {}).get('call') == 'OLD-TINY'
                for k in ('no_detect', 'no_consume', 'drop_state')))

    # A record can outlive its projection: --maot_drop_escape_state leaves a
    # FORBIDDEN decision serialized while the descriptor's escape count is
    # zero. consumed_by would still claim a consumer. All three must hold.
    surv = o.get('blocking_projection') or {}
    c['blocking_record_survives_to_the_consumer'] = (
        surv.get('blocking_decisions', 0) > 0
        and surv.get('escape_projection', 0) > 0
        and surv.get('install_refused') is True
        and surv.get('drop_state_decisions', 0) > 0
        and surv.get('drop_state_projection', -1) == 0
        and surv.get('drop_state_install_refused') is False)

    cons = o.get('conservative_control') or {}
    c['optimized_and_conservative_agree'] = (
        bool(cons.get('compared'))
        and cons.get('disagreements') == []
        and cons.get('flags'))

    c['required_falsifications_detected'] = (
        o.get('falsifications_failed') == [])

    m = o.get('measurements') or {}
    c['measurements_recorded'] = all(
        m.get(k) is not None for k in
        ('aot_elf_bytes', 'compile_seconds', 'direct_call_ns_mutable',
         'prevented_inlines', 'devirtualizations_recorded',
         'indirect_call_sites_total'))

    c['build_provenance_bound'] = (
        o.get('build_digest_matches') is True
        and bool((o.get('build_digest') or {}).get('fork_commit')))
    c['target_architecture_recorded'] = o.get('target_arch') == TARGET_ARCH

    demonstrated = {'dispatch': ['direct'], 'compilation': ['aot'],
                    'heat': ['cold', 'hot'], 'target_arch': [TARGET_ARCH]}
    c['t0_linkage_exact_and_unpromoted'] = (
        all(v['row_result_after_68'] == 'UNMODELED'
            for v in T0_ROW_LINKAGE.values())
        and T0_ROW_LINKAGE['EB-01']['covered_by_issue_68'] == demonstrated
        and T0_ROW_LINKAGE['EB-02']['covered_by_issue_68'] == demonstrated
        and T0_ROW_LINKAGE['RS-09']['covered_by_issue_68'] == {}
        and o.get('t0_rows_promoted') in (None, []))

    blocking = [f for f in findings if f.get('severity') == 'blocking']
    phase_blocking = [f for f in blocking
                      if f.get('code') != 'ACCEPTANCE_ITEM_NOT_MET']
    ok = all(c.values()) and not phase_blocking

    ledger = build_ledger(c, o.get('live_arm_count') or 0)
    unmet = sorted(u['item'] for u in ledger if not u['met'])

    return {
        'arm64_aot_optimizer_invariants':
            'ESTABLISHED' if ok else 'NOT_ESTABLISHED',
        'issue_68_closure': 'READY' if (ok and not unmet) else 'NOT_READY',
        'target_arch': TARGET_ARCH,
        'acceptance_ledger': ledger,
        'acceptance_items_unmet': unmet,
        't0_row_linkage': T0_ROW_LINKAGE,
        'rule_table': R.RULES,
        'conditions': c,
        'conditions_failed': sorted(k for k, v in c.items() if not v),
        'condition_meanings': CONDITIONS,
        'blocking_findings': sorted({f['code'] for f in blocking}),
        'verdict_rule': (
            'arm64_aot_optimizer_invariants == ESTABLISHED iff every '
            'condition holds and no non-acceptance blocking finding was '
            'raised. issue_68_closure == READY iff that and no acceptance '
            'item is unmet. Conjunctions throughout; no count, ratio or '
            'threshold is compared, and no outcome string is reachable '
            'unconditionally.'),
        'not_claimed': [
            f'Proven on {TARGET_ARCH} only.',
            'M1 is not complete. Virtual, interface, super and the remaining '
            'call forms are #69 and #70.',
            'No #64 row is promoted; EB-01, EB-02 and RS-09 stay UNMODELED.',
            'Phase B is not done: no optimization crosses the boundary with '
            'invalidation state, because none carries one. '
            'DEPENDENCY_REQUIRED fails closed for that reason.',
            'No structural class migration, no additions, no product CLI.',
        ],
    }


def build_ledger(conditions, live_arm_count=0):
    """#68's acceptance items, each computed from a condition."""
    return [
        {'item': 'mutability exists as explicit compiler metadata before '
                 'optimization',
         'met': conditions['devirtualization_join_present']
                and conditions['every_optimizer_class_has_a_rule'],
         'evidence': '#65 DeclarationId carried in kernel metadata and bound '
                     'at load, before any optimizer pass runs'},
        {'item': 'every relevant optimizer pass has a documented and enforced '
                 'rule',
         'met': conditions['every_optimizer_class_has_a_rule']
                and conditions['blocking_dispositions_actually_block'],
         'evidence': f'{len(R.RULES)} rules, each with enforcement site, '
                     f'producer, consumer and falsification'},
        {'item': 'the conservative M1 configuration prevents silent bypasses',
         'met': conditions['conservative_posture_holds']
                and conditions['hot_sites_observe_replacement']
                and conditions['escape_metadata_is_consumed'],
         'evidence': 'every adversarial variant observes its replacement, and '
                     'each disabling control lets a bypass through'},
        {'item': 'optimized and non-optimized direct/static fixtures both '
                 'observe replacements',
         'met': conditions['optimized_and_conservative_agree'],
         'evidence': 'optimized AOT versus conservative AOT control'},
        {'item': 'dead or unreached-at-release mutable declarations remain '
                 'patch-addressable',
         'met': conditions['dead_release_declaration_addressable'],
         'evidence': 'a declaration the release never calls installs and its '
                     'version advances'},
        {'item': 'falsification of each major optimization class changes the '
                 'gate',
         'met': conditions['required_falsifications_detected'],
         'evidence': f'{live_arm_count} live arms'},
        {'item': 'any dependency metadata is consumed by a real decision',
         'met': conditions['blocking_record_survives_to_the_consumer'],
         'evidence': 'blocking decision AND surviving projection AND real '
                     'install refusal -- a consumed_by string alone does not '
                     'satisfy it'},
        {'item': 'exact #64 linkage for the demonstrated modes, with EB-01, '
                 'EB-02 and RS-09 left unpromoted',
         'met': conditions['t0_linkage_exact_and_unpromoted'],
         'evidence': 'direct / aot / cold+hot / arm64; H11 refuses a '
                     'whole-row promotion'},
    ]


CONSUMERS = {
    'verdict': 'the gate exit code, the Phase A claim, and separately whether '
               '#68 may close',
    'observations': 'every condition in the verdict',
    'registry_after': 'the descriptor, escape and installability conditions',
    'optimizer_decisions': 'the rule-table and join conditions',
    'falsification': 'required_falsifications_detected',
    'falsification_bank': 'whether every live bank entry has an arm',
    'findings': 'verdict.blocking_findings and the gate exit code',
    'identities': 'whether any of this may be quoted',
    'schema': 'readers and later issues',
    'issue': 'readers and later issues',
    'generated_by': 'reproducing this record',
    'consumers': 'this check itself, in both directions',
}
