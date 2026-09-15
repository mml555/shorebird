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
        'site, a disposition, a producer, a consumer and a falsification -- '
        'compared against an INDEPENDENT required-class set, so deleting a '
        'class fails the check instead of shrinking what it inspects?',
    'recognized_population_is_sdk_only':
        'read out of the VM\'s own recognized/intrinsic tables: does every '
        'row name an SDK library, and is vm:recognized unable to assign '
        'recognized_kind on its own? Those two facts are what close the '
        'class, together with no_sdk_declaration_is_selected.',
    'injected_recognized_defect_is_caught':
        'the tables cannot make a user declaration recognized, so a blocker '
        'for that case has never been watched firing. With '
        '--maot_force_recognized the state is injected: is the declaration '
        'then FORBIDDEN and uninstallable, and does the verdict flip?',
    'no_sdk_declaration_is_selected':
        'is the shipped selected set free of any dart: declaration? The '
        'recognized/intrinsic rule is only sound if the SDK population cannot '
        'be selected at all.',
    'injected_inlining_defect_is_caught':
        'with --maot_allow_inlining_mutable the inliner actually takes a '
        'mutable callee: does that caller then keep returning the release '
        'answer after an install, and does the verdict flip?',
    'injected_retention_defect_is_caught':
        'with --maot_disable_retention_roots every selected declaration is '
        'seen at materialization and then DROPPED: does the registry empty, '
        'does the program stop running, and does the verdict flip? Retention '
        'is the only thing seeding contributes to survival, so '
        '--maot_disable_seeding reaches the same outcome by the same route -- '
        'the two differ only in the disposition records seeding emits.',
    'injected_tfa_defect_is_caught':
        'with MAOT_ALLOW_CONSTANT_FOLDING=1 TFA folds a mutable result: does '
        'the caller keep the release answer after an install, and does the '
        'verdict flip?',
    'scale_measurements_recorded':
        'are the prevented-inline and devirtualization counts present for a '
        'representative Flutter application, not only the m4 fixture? No '
        'threshold is compared; absence is the only failure.',
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
    'H15': ('live', 'an optimizer class #68 names is deleted from the rule '
                    'table and the completeness check still passes'),
    'H16': ('live', 'a user declaration carrying both maot:mutable and '
                    'vm:recognized is treated as installable, so the compiler '
                    'may substitute inline code no dispatch cell mediates'),
    'H17': ('live', 'TFA folds a mutable result to a constant, so the caller '
                    'holds the release answer with no call at all'),
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

    # The first version of this condition checked only that whatever happened
    # to be in R.RULES had populated fields. An entire class could be deleted
    # and it still passed -- false-safe in the exact way that matters. The set
    # of classes #68 requires is now written down INDEPENDENTLY, in
    # R.REQUIRED_CLASSES, and the condition compares against it in both
    # directions. H15 deletes a class and requires this to go False.
    c['every_optimizer_class_has_a_rule'] = bool(
        bool(R.RULES)
        and set(R.RULES) == set(R.REQUIRED_CLASSES)
        and all(all(f in v and v[f] for f in R.REQUIRED_FIELDS)
                for v in R.RULES.values())
        and all(v['disposition'] in
                ('FORBIDDEN', 'SLOT_PRESERVING', 'DEPENDENCY_REQUIRED',
                 'UNMODELED_BLOCKING') for v in R.RULES.values()))

    # Blocker 2. The recognized/intrinsic class needs BOTH halves proven.
    #
    # First half: no SDK declaration can be selected. Asserted against the
    # shipped registry, not argued from how collectSelected is written.
    c['no_sdk_declaration_is_selected'] = bool(
        entries
        and not any(e.get('selected') and ':dart:' in k
                    for k, e in entries.items()))

    # Second half: the recognized population is exactly what the VM's own
    # tables name, and every row in them names an SDK library. Together with
    # the first half that closes the class -- a selected declaration cannot be
    # recognized, because recognized_kind is assigned nowhere else.
    #
    # This replaces an earlier claim that instance-member blocking covered the
    # class. That claim was wrong: dart:core's identical and a number of
    # top-level Developer and FFI functions are recognized AND static.
    rt = o.get('recognized_table') or {}
    c['recognized_population_is_sdk_only'] = bool(
        sorted(rt.get('blocks_found') or []) ==
            sorted(R.RECOGNIZED_TABLE_BLOCKS)
        and rt.get('libraries')
        and rt.get('non_sdk_libraries') == []
        and rt.get('pragma_can_assign_recognized_kind') is False)

    # And the blocker itself must be watched firing. The tables cannot produce
    # a recognized user declaration, so the state is injected.
    rec = o.get('injected_recognized_defect') or {}
    c['injected_recognized_defect_is_caught'] = bool(
        rec.get('baseline_forbidden_decisions', -1) == 0
        and rec.get('baseline_install') == 0
        and rec.get('defect_forbidden_decisions', 0) > 0
        and rec.get('defect_install') == -3
        and rec.get('defect_installable') is False
        and rec.get('verdict_under_defect') == 'NOT_ESTABLISHED')

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
    c['optimized_and_conservative_agree'] = bool(
        bool(cons.get('compared'))
        and cons.get('disagreements') == []
        and bool(cons.get('flags')))

    c['required_falsifications_detected'] = bool(
        o.get('falsifications_failed') == [])

    # --- injected optimizer defects (blocker 3) -------------------------
    # H10 and H12 were positive tests: they observed that the protection was
    # in place, not that removing it produces a defect the gate catches.
    # These two conditions read the DEFECT builds. Each requires three
    # things -- the protection was actually doing work in the shipped build,
    # the defect actually got injected, and the verdict flipped -- because
    # any one of them alone can pass vacuously.
    ind = o.get('injected_inlining_defect') or {}
    c['injected_inlining_defect_is_caught'] = bool(
        # Baseline: nothing was inlined and the replacement IS observed.
        ind.get('baseline_inline_admissions', -1) == 0
        and ind.get('baseline_call_after_install') == 'NEW-TINY'
        and ind.get('baseline_install') == 0
        # Defect: the inliner really took the callee. This -- not a refusal
        # count -- is what proves the callee was inlinable and the rule is
        # what stopped it. set_is_inlinable(false) makes the inliner skip the
        # callee before ShouldWeInline is ever asked, so in the shipped build
        # the refusal counter reads zero for the fixture; admissions under the
        # falsification flag is the precondition that actually discriminates.
        and ind.get('defect_inline_admissions', 0) > 0
        # The caller now holds a copy, and it shows: the call keeps returning
        # the release answer, cold and hot.
        and ind.get('defect_call_after_install') == 'OLD-TINY'
        and ind.get('defect_hot_call') == 'OLD-TINY'
        # And the system FAILS CLOSED rather than shipping a stale caller:
        # the admission records an escape and installation is refused.
        and ind.get('defect_escapes', 0) > 0
        and ind.get('defect_installable') is False
        and ind.get('defect_install') == -3
        and ind.get('verdict_under_defect') == 'NOT_ESTABLISHED')

    ret = o.get('injected_retention_defect') or {}
    # None-safe on purpose. The first version compared two .get() results
    # directly and raised TypeError when the key name was wrong, which is a
    # gate that crashes rather than a gate that reports -- and a crashing
    # gate says nothing at all. Missing counts mean NOT measured, which is
    # False, not an exception.
    _base_sel = ret.get('baseline_selected_entries')
    _def_sel = ret.get('defect_selected_entries')
    c['injected_retention_defect_is_caught'] = bool(
        # Baseline: the dead-at-release declaration is present, retained, and
        # patchable. Nothing dropped.
        ret.get('baseline_registry_entries', 0) > 0
        and ret.get('baseline_dead_declaration_present') is True
        and ret.get('baseline_dead_version_after_install') == 'PATCH_CODE:v2'
        and ret.get('baseline_dropped_at_materialization') == 0
        and ret.get('baseline_retained_at_materialization', 0) > 0
        and ret.get('baseline_returncode') == 0
        # Defect: every selected declaration was SEEN and then DROPPED for
        # want of a retention root. Seen-and-dropped, not absent, is what
        # distinguishes this from --maot_disable_seeding, which registers
        # nothing; the runtime dump alone cannot tell them apart.
        and ret.get('defect_seen_at_materialization', 0) > 0
        and ret.get('defect_retained_at_materialization', -1) == 0
        and ret.get('defect_dropped_at_materialization', 0) > 0
        # Seen-and-dropped, not absent: the declarations were registered by
        # the kernel loader and then lost at materialization for want of a
        # retention root. An earlier version of this condition also required
        # --maot_disable_seeding to show ZERO seen, on the assumption that the
        # two instruments failed at different points. They do not: binding and
        # registration happen at load, not at seeding, so both show 13 seen
        # and 13 dropped. What they actually differ by is the disposition
        # records seeding emits, which is asserted instead -- a claim the
        # measurement supports.
        and ret.get('no_seeding_seen_at_materialization')
            == ret.get('defect_seen_at_materialization')
        and ret.get('no_seeding_dropped_at_materialization')
            == ret.get('defect_dropped_at_materialization')
        and ret.get('defect_decisions', 0)
            > ret.get('no_seeding_decisions', 0)
        # Consequence: nothing is patchable and the program does not run.
        and ret.get('defect_dead_declaration_present') is False
        and ret.get('defect_reachable_declaration_present') is False
        and ret.get('defect_returncode') != 0
        and isinstance(_base_sel, int) and isinstance(_def_sel, int)
        and _def_sel < _base_sel
        and ret.get('defect_install') != 0
        and ret.get('verdict_under_defect') == 'NOT_ESTABLISHED')

    tfa = o.get('injected_tfa_defect') or {}
    c['injected_tfa_defect_is_caught'] = bool(
        tfa.get('baseline_call_after_install') == 'NEW-CONST'
        and tfa.get('baseline_constant_folding_decisions', -1) == 0
        # One layer removed (TFA suppression off): the VM backstop sees the
        # constant result, records it FORBIDDEN, and installation is refused.
        # Install refused ALONE does not discriminate -- a refused install
        # trivially leaves the caller on the release answer -- so the
        # discriminating observation is the backstop decision appearing.
        and tfa.get('one_layer_constant_folding_decisions', 0) > 0
        and tfa.get('one_layer_install') == -3
        and tfa.get('one_layer_verdict') == 'NOT_ESTABLISHED'
        # Both layers removed: nothing refuses, installation SUCCEEDS, and
        # every caller still returns the folded release answer. This is the
        # raw defect, and it is the one that actually shipped once.
        and tfa.get('both_layers_install') == 0
        and tfa.get('both_layers_call_after_install') == 'OLD-CONST'
        and tfa.get('both_layers_verdict') == 'NOT_ESTABLISHED')

    m = o.get('measurements') or {}
    c['measurements_recorded'] = bool(all(
        m.get(k) is not None for k in
        ('aot_elf_bytes', 'compile_seconds', 'direct_call_ns_mutable',
         'prevented_inlines', 'devirtualizations_recorded',
         'indirect_call_sites_total')))

    # Blocker 4. The m4 fixture is eight declarations; it cannot say what this
    # posture costs a real program. The scale lane compiles a representative
    # Flutter application and counts the same two quantities there. Absence is
    # the only failure -- no threshold is compared, because no threshold has
    # been agreed and inventing one here would be a fabricated contract.
    sc = o.get('scale_measurements') or {}
    c['scale_measurements_recorded'] = bool(
        sc.get('corpus')
        and all(sc.get(k) is not None for k in
                ('selected_declarations', 'prevented_inlines',
                 'devirtualizations_recorded', 'aot_elf_bytes',
                 'aot_elf_bytes_control', 'compile_seconds',
                 'compile_seconds_control'))
        and sc.get('selected_declarations', 0) > 0
        and sc.get('framework_declarations_in_corpus', 0) > 0)

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

    # A condition whose value is a non-empty list reads as "holds" in every
    # conjunction and prints as its own contents in the evidence -- which is
    # how optimized_and_conservative_agree shipped as
    # ['--inlining_depth_threshold=0'] instead of True. Non-boolean condition
    # values are now a hard error rather than a silent pass.
    non_bool = sorted(k for k, v in c.items() if not isinstance(v, bool))
    if non_bool:
        raise TypeError(
            'verdict conditions must be bool; these are not: '
            + ', '.join(f'{k}={c[k]!r}' for k in non_bool))

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
         'met': conditions['required_falsifications_detected']
                and conditions['injected_inlining_defect_is_caught']
                and conditions['injected_retention_defect_is_caught']
                and conditions['injected_tfa_defect_is_caught'],
         'evidence': f'{live_arm_count} live arms, of which three inject a '
                     f'real inlining, retention and TFA defect rather than '
                     f'observing that the protection is in place'},
        {'item': 'recognized/intrinsic replacement cannot erase mutability',
         'met': conditions['no_sdk_declaration_is_selected']
                and conditions['recognized_population_is_sdk_only']
                and conditions['injected_recognized_defect_is_caught']
                and conditions['every_optimizer_class_has_a_rule'],
         'evidence': 'the recognized tables name only SDK libraries and no '
                     'SDK declaration can be selected, so the class is empty '
                     'by construction; the blocker is still watched firing '
                     'against an injected recognized declaration'},
        {'item': 'the cost of the conservative posture is measured at '
                 'application scale, not only on the fixture',
         'met': conditions['measurements_recorded']
                and conditions['scale_measurements_recorded'],
         'evidence': 'prevented inlines and devirtualizations counted on a '
                     'representative Flutter application against a control'},
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
