#!/usr/bin/env python3
"""MAOT-3 (#67) -- derive the verdicts from the evidence.

TWO VERDICTS, DELIBERATELY SEPARATE.

  arm64_aot_direct_static_vertical_slice
      what the mechanism demonstrably does, on this architecture, for this
      call form. It is a narrow, architecture-scoped technical claim.

  issue_67_closure
      whether the ISSUE may close. It requires the slice AND that every
      acceptance item is met. An unmet acceptance item is a blocking finding,
      so the record cannot say "findings: []" while the prose says an item is
      outstanding -- which is exactly what the first version of this lane did.

Collapsing the two lets a true technical result carry an untrue milestone
claim. The outcome strings appear here because the module has to render one;
neither is reachable unconditionally.
"""

# The lowering this milestone implements lives in
# flow_graph_compiler_arm64.cc. Nothing here is architecture-independent, and
# the verdict name says so rather than leaving a reader to assume otherwise.
TARGET_ARCH = 'arm64'

# What #67 may legitimately say about #64's rows.
#
# EB-01 and EB-02 are NOT "direct top-level" and "static direct". Each row
# requires the `direct`, `tearoff_pre`, `tearoff_post` and `dynamic` dispatch
# modes across JIT and AOT and cold and hot. #67 exercises exactly one cell of
# that space, so promoting either row would be an overclaim by a factor of
# sixteen. The linkage below records the cell and nothing more.
T0_ROW_LINKAGE = {
    'EB-01': {
        'row_title': 'top-level function body',
        'covered_by_issue_67': {
            'dispatch': ['direct'],
            'compilation': ['aot'],
            'heat': ['cold', 'hot'],
            'target_arch': [TARGET_ARCH],
        },
        'not_covered': ['tearoff_pre', 'tearoff_post', 'dynamic', 'jit'],
        'row_result_after_67': 'UNMODELED',
        'why': 'a row is proven when every mode it names is proven; #67 '
               'proves one dispatch mode on one architecture in one '
               'compilation mode. #69 and #70 own the rest.',
    },
    'EB-02': {
        'row_title': 'static method body',
        'covered_by_issue_67': {
            'dispatch': ['direct'],
            'compilation': ['aot'],
            'heat': ['cold', 'hot'],
            'target_arch': [TARGET_ARCH],
        },
        'not_covered': ['tearoff_pre', 'tearoff_post', 'dynamic', 'jit'],
        'row_result_after_67': 'UNMODELED',
        'why': 'same; the static arm is proven for direct calls only.',
    },
}

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
        'does the record carry, structurally, the target DeclarationId, the '
        'REPLACEMENT DeclarationId, the release namespace, the ABI, and '
        'kind+version before and after -- rather than a Function-name '
        'diagnostic?',
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
    'call_latency_measured_numerically':
        'are direct AND static call latencies real numbers from a running '
        'program, each with a never-inlined non-mutable control? Prose saying '
        'a thing was not measured is not a measurement.',
    'size_measurements_recorded':
        'are the code-size and registry measurements present? No threshold is '
        'compared; absence is the only failure.',
    'build_provenance_bound':
        'were the binaries that produced this evidence built from the exact '
        'MAOT source bytes the record names?',
    'target_architecture_recorded':
        'does the record say which architecture the lowering was proven on?',
    'cold_and_hot_observed':
        'does a heavily-executed call site observe the replacement too, '
        'measured after a million iterations rather than inferred from the '
        'benchmark running a lot?',
    't0_linkage_exact_and_unpromoted':
        'does the record link exactly the demonstrated modes -- direct, AOT, '
        'cold+hot, arm64 -- while leaving both whole rows UNMODELED?',
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
    'G16': ('live', 'a measurement condition is satisfied by a non-numeric '
                    'placeholder, or by only one of the two call forms'),
    'G17': ('live', 'the binaries were built from different source bytes than '
                    'the record names'),
    'G18': ('live', 'a whole #64 row is promoted from evidence covering one of '
                    'its dispatch modes'),
    'G19': ('live', 'the acceptance ledger cannot report an unmet item, so '
                    'issue closure rests on prose rather than on a check'),
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
    # Identity is structural: the #65 DeclarationId of the target AND of the
    # replacement, the release namespace, the ABI, and kind+version on both
    # sides. A Function-name diagnostic is a spelling, and #66 spent an arm
    # proving two declarations can share one.
    before = {e['declaration_id']: e
              for e in (o.get('registry_before') or {}).get('entries', [])}
    expected_impl = {
        '::fn:work': '::fn:workNew2',
        '::cls:StaticTarget::method:work': '::fn:staticNew2',
    }
    impl_ids_ok = True
    for suffix, impl_suffix in expected_impl.items():
        e = entry(suffix)
        if e is None:
            impl_ids_ok = False
            continue
        b = next((v for k, v in before.items() if k.endswith(suffix)), None)
        impl_ids_ok = impl_ids_ok and (
            str(e.get('current_implementation_id', '')).endswith(impl_suffix)
            and not e.get(
                'current_implementation_is_the_declaration_itself', True)
            and str(e['release'].get('implementation_id', '')).endswith(suffix)
            and b is not None
            and b.get('current_implementation_is_the_declaration_itself')
            is True
            and b['current']['kind'] == 'AOT' and b['current']['version'] == 1
            and e.get('abi') is not None)
    conditions['identity_visible_in_evidence'] = (
        bool(entries)
        and all('declaration_id' in e for e in entries.values())
        and reg.get('namespace_identity') == o.get('expected_namespace')
        and calls.get('top.version.0') == 'AOT:v1'
        and calls.get('top.version.2') == 'PATCH_CODE:v3'
        and impl_ids_ok)
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

    # A number, from a running program, for BOTH call forms, each against a
    # never-inlined control. The first version of this condition tested only
    # that a field was non-null -- and the field held a sentence explaining
    # that the measurement had not been taken.
    def numeric(x):
        return isinstance(x, (int, float)) and not isinstance(x, bool)

    # A control that measures as zero is a control the optimizer removed, and
    # an overhead computed against it would be meaningless. Requiring every
    # arm to be positive is what makes the comparison mean something.

    latency_fields = ('direct_call_ns_mutable', 'direct_call_ns_control',
                      'static_call_ns_mutable', 'static_call_ns_control')
    conditions['call_latency_measured_numerically'] = (
        all(numeric(m.get(f)) for f in latency_fields)
        and all((m.get(f) or 0) > 0 for f in latency_fields)
        and numeric(m.get('benchmark_iterations'))
        and (m.get('benchmark_iterations') or 0) >= 100000)
    conditions['size_measurements_recorded'] = (
        m.get('aot_elf_delta_bytes') is not None
        and m.get('registry_bytes') is not None
        and m.get('indirect_call_sites_total') is not None)

    # Same guard #66 learned it needed: the binaries have to have been built
    # from the source bytes this record names. mtimes are useless on a shared
    # rig, where switching branches rewrites every one of them.
    conditions['build_provenance_bound'] = (
        o.get('build_digest_matches') is True
        and bool((o.get('build_digest') or {}).get('fork_commit')))
    conditions['target_architecture_recorded'] = (
        o.get('target_arch') == TARGET_ARCH)

    # Hot as a measurement, not an inference. The benchmark loops run a call
    # site two million times but never look at what it returns; these loops
    # return what the last of a million calls observed.
    conditions['cold_and_hot_observed'] = (
        calls.get('top.call.2') == 'NEW2'
        and calls.get('static.call.2') == 'NEW2-STATIC'
        and calls.get('hot.top.value') == 'NEW2'
        and calls.get('hot.static.value') == 'NEW2-STATIC'
        and (calls.get('hot.iterations') or 0) >= 100000)

    # The corrected #67 criterion: exact linkage of what was demonstrated,
    # with the whole rows left alone. Both halves are required -- linkage that
    # claimed more than was shown would be the overclaim the criterion was
    # corrected to avoid, and a row quietly promoted would be the same thing
    # by another route.
    demonstrated = {
        'dispatch': ['direct'],
        'compilation': ['aot'],
        'heat': ['cold', 'hot'],
        'target_arch': [TARGET_ARCH],
    }
    conditions['t0_linkage_exact_and_unpromoted'] = (
        bool(T0_ROW_LINKAGE)
        and all(x['covered_by_issue_67'] == demonstrated
                and x['row_result_after_67'] == 'UNMODELED'
                and x['not_covered']
                for x in T0_ROW_LINKAGE.values())
        and o.get('t0_rows_promoted') in (None, [])
        # and the linkage may only claim modes the run actually produced
        and conditions['cold_and_hot_observed']
        and conditions['call_sites_traverse_the_mechanism']
        and o.get('target_arch') == TARGET_ARCH)

    # ACCEPTANCE_ITEM_NOT_MET blocks CLOSURE, not the slice: it says the
    # milestone is incomplete, not that the mechanism failed to work.
    blocking = [f for f in findings if f.get('severity') == 'blocking']
    slice_blocking = [f for f in blocking
                      if f.get('code') != 'ACCEPTANCE_ITEM_NOT_MET']
    slice_ok = all(conditions.values()) and not slice_blocking

    # Issue closure is a STRICTLY stronger claim: the slice, plus every
    # acceptance item met. Unmet items arrive as blocking findings, so this
    # cannot silently agree with the slice verdict.
    unmet = sorted(o.get('acceptance_items_unmet') or [])
    closure_ok = slice_ok and not unmet

    return {
        'arm64_aot_direct_static_vertical_slice':
            'ESTABLISHED' if slice_ok else 'NOT_ESTABLISHED',
        'issue_67_closure':
            'READY' if closure_ok else 'NOT_READY',
        'target_arch': TARGET_ARCH,
        'acceptance_items_unmet': unmet,
        't0_row_linkage': T0_ROW_LINKAGE,
        'conditions': conditions,
        'conditions_failed': sorted(k for k, v in conditions.items() if not v),
        'condition_meanings': CONDITIONS,
        'blocking_findings': sorted({f['code'] for f in blocking}),
        'slice_blocking_findings': sorted({f['code'] for f in slice_blocking}),
        'verdict_rule': (
            'arm64_aot_direct_static_vertical_slice == ESTABLISHED iff every '
            'condition above holds AND no blocking finding was raised. '
            'issue_67_closure == READY iff that AND no acceptance item is '
            'unmet. Both are conjunctions; no count, ratio or threshold is '
            'compared anywhere in this module, and no outcome string is '
            'reachable unconditionally. The two are separate because a true '
            'technical result must not be able to carry an untrue milestone '
            'claim.'),
        'not_claimed': [
            f'Proven on {TARGET_ARCH} only. The lowering is in '
            f'flow_graph_compiler_arm64.cc and no other architecture has one.',
            'No #64 row is promoted. #67 covers the `direct` dispatch mode of '
            'EB-01 and EB-02 under AOT; each row also requires tearoff_pre, '
            'tearoff_post and dynamic, across JIT and AOT. See '
            't0_row_linkage.',
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
    'verdict': 'the gate exit code, the slice claim, and separately '
               'whether #67 may be closed',
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
