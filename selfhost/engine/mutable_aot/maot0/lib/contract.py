#!/usr/bin/env python3
"""MAOT-0 (#63) -- the authoritative vocabulary and the derivation rules.

ONE definition, imported by every consumer. #62's closure discipline item 7
is "a definition/constraint must propagate to every consumer that can make
the relevant decision", and the way that fails in practice is a second copy
of an enum drifting from the first. So the enums, the ordering, the row-state
function and the aggregate function live here and nowhere else.

Nothing in this file reads a file or prints. It is pure derivation, so the
gate, the falsifier and the lock all compute identical answers from identical
inputs.
"""

# ------------------------------------------------------------------ states

# Axis maturity, ordered. A row is only as mature as its weakest applicable
# axis, so this ordering is load-bearing rather than cosmetic.
AXIS_STATES = ('UNMODELED', 'DESIGNED', 'IMPLEMENTED', 'PROVEN')
AXIS_ORDER = {s: i for i, s in enumerate(AXIS_STATES)}

# NOT_APPLICABLE is deliberately NOT in the ordering. It is not a maturity
# level, it is a claim that the axis does not exist for this row -- and such a
# claim must carry a justification, because "not applicable" is the cheapest
# way to make a hard row look finished.
AXIS_NOT_APPLICABLE = 'NOT_APPLICABLE'
ALL_AXIS_VALUES = AXIS_STATES + (AXIS_NOT_APPLICABLE,)

ROW_STATES = AXIS_STATES  # a row reports on the same scale as its axes

# The four semantics #63 requires be kept apart. Collapsing any two is the
# specific error the issue calls out: an engine that can REPRESENT the new
# code is not thereby an engine that MIGRATES the old state.
AXES = (
    'code_representability',
    'dispatch_correctness',
    'live_state_compatibility',
    'semantic_migration',
)

AXIS_MEANING = {
    'code_representability':
        'Can the patched program shape/code exist and execute in the running '
        'process under the fixed native binary?',
    'dispatch_correctness':
        'Does every supported invocation path observe the current '
        'implementation after installation? (#62 I2, no bypass.)',
    'live_state_compatibility':
        'What happens to state that already exists -- frames, heap objects, '
        'closures, continuations, caches, canonical constants?',
    'semantic_migration':
        'When the transformation of existing state is not uniquely '
        'determined by the code change, what explicit developer-authored '
        'migration is required, and how is it executed?',
}

COEXISTENCE = (
    'not_applicable',
    'no_old_state_possible',
    'old_state_may_coexist',
    'old_state_must_migrate',
    'undecided',
)

MIGRATION = (
    'none_required',
    'automatic_well_defined',
    'developer_migration_required',
    'undecided',
)

SUBSYSTEMS = (
    'cfe_kernel',
    'aot_compiler',
    'optimizer',
    'vm_runtime',
    'patch_toolchain',
    'flutter_framework',
)

GROUPS = (
    'existing_body',
    'declaration_change',
    'type_shape',
    'runtime_state',
    'flutter_dart',
    'identity',
    'blanket',
)

# Universe tiers, and how the matrix is allowed to cover each. `per_row` means
# every entry in the tier must be named by some row's `covers`. `blanket`
# means one row may claim the whole tier at once -- allowed only where the
# rule genuinely is one rule (every expression node is "a body changed"), and
# the blanket is recorded in the matrix so it is reviewable rather than
# implied by an absence.
TIER_COVERAGE = {
    'declaration': 'per_row',
    'type': 'per_row',
    'constant': 'per_row',
    'identity': 'per_row',
    'runtime_state': 'per_row',
    'program_structure': 'blanket',
    'structural_base': 'blanket',
    'body_content': 'blanket',
    'infrastructure': 'blanket',
}

# ------------------------------------------------------------- derivations


def row_axis_values(row):
    """The axis map for a row, with every axis present.

    A missing axis is returned as UNMODELED rather than skipped: an absent
    axis must never read as a satisfied one.
    """
    declared = row.get('axes') or {}
    return {a: declared.get(a, 'UNMODELED') for a in AXES}


def derive_row_state(row):
    """A row is as mature as its weakest APPLICABLE axis.

    Never stored in the matrix. #62's closure discipline item 6 asks which
    decision consumes a value; a stored row state would be a second answer
    that no longer has to agree with the axes it summarises.
    """
    values = row_axis_values(row)
    applicable = [v for v in values.values() if v != AXIS_NOT_APPLICABLE]
    if not applicable:
        # Every axis waved away. That is not a proven row, it is an unmodeled
        # one with four justifications attached.
        return 'UNMODELED'
    return min(applicable, key=lambda s: AXIS_ORDER.get(s, -1))


def row_is_provable(row):
    """Whether a row's own fields let it claim PROVEN at all.

    Separate from derive_row_state so the gate can distinguish "the axes say
    PROVEN but the row has no evidence" (a defect) from "the axes do not say
    PROVEN" (ordinary, expected work remaining).
    """
    reasons = []
    if not row.get('gate_id'):
        reasons.append('no gate_id: a PROVEN row must name an executable gate')
    ev = row.get('evidence')
    if not ev:
        reasons.append('no evidence reference')
    else:
        if not isinstance(ev, dict):
            reasons.append('evidence is not a record')
        else:
            if not ev.get('path'):
                reasons.append('evidence has no path')
            if not ev.get('sha256'):
                reasons.append('evidence has no sha256')
    return (not reasons), reasons


def in_scope_rows(matrix):
    return [r for r in matrix.get('rows', []) if r.get('in_scope', True)]


def row_lock_projection(row):
    """The part of a row whose change must be an explicit, reviewed act.

    Deliberately NOT the whole row. Locking the full text would churn the
    lock on every wording fix, and a lock that is routinely regenerated stops
    being read -- at which point it detects nothing. What is projected here
    is exactly what can promote a row: its axis states, its scope, its gate,
    and its evidence binding.
    """
    return {
        'id': row.get('id'),
        'axes': row_axis_values(row),
        'in_scope': row.get('in_scope', True),
        'gate_id': row.get('gate_id'),
        'evidence': row.get('evidence'),
        'derived_state': derive_row_state(row),
    }


def derive_aggregate(matrix, findings):
    """The universal-support verdict. Computed, never stored, fail closed.

    #62 I7 and #63 both forbid a percentage threshold, so the verdict is a
    conjunction over EVERY in-scope row plus the structural findings. Counts
    are reported for diagnosis only and no comparison is made against them.
    """
    rows = in_scope_rows(matrix)
    unproven = []
    for r in rows:
        state = derive_row_state(r)
        ok, _ = row_is_provable(r)
        if state != 'PROVEN' or not ok:
            unproven.append(r['id'])

    blocking = [f for f in findings if f.get('severity') == 'blocking']

    counts = {s: 0 for s in ROW_STATES}
    for r in rows:
        counts[derive_row_state(r)] += 1

    claim = 'PROVEN' if (not unproven and not blocking and rows) else 'NOT_PROVEN'

    return {
        'universal_dart_patchability': claim,
        'in_scope_rows': len(rows),
        'rows_not_proven': unproven,
        'blocking_findings': [f['code'] for f in blocking],
        'row_state_counts': counts,
        'diagnostic_only': (
            'row_state_counts and any percentage a reader computes from it '
            'are DIAGNOSTIC. The verdict above is a conjunction over every '
            'in-scope row; no threshold is compared anywhere in this file.'),
        'verdict_rule': (
            'universal_dart_patchability == PROVEN iff there is at least one '
            'in-scope row AND every in-scope row derives PROVEN from its '
            'applicable axes AND carries a gate_id and a digested evidence '
            'reference AND no blocking structural finding was raised.'),
    }
