#!/usr/bin/env python3
"""MAOT-5 (#69) -- the exact #64 cells this issue may claim.

Derived from the T0 row fixtures, never transcribed. #69's amended
acceptance forbids promoting a whole row unless every mode that row's
fixture declares is actually covered, so the gate needs the declared set as
DATA, computed from the same files T0 publishes.

The central fact this module exists to make unmissable: no row in #69's
territory can reach whole-row PROVEN, because every one of them declares
`jit` cells and Mutable-AOT has no JIT mechanism at all. The dispatch-cell
lowering lives only in flow_graph_compiler_arm64.cc and is gated on
FLAG_precompiled_mode, so a `jit` cell is not "not yet done" -- it is
unreachable by construction, and saying so is the point of the amendment.
"""
import glob
import json
import os

# Dispatch forms #69 owns, per its "Dispatch forms to own" list.
#
# `dynamic` is included as the megamorphic/switchable-call case. The issue
# says "megamorphic/interface calls where applicable" rather than naming
# `dynamic`, so this is an INTERPRETATION and is flagged as one -- but
# EB-03 declares `dynamic` as a mode distinct from `interface`, so covering
# EB-03 at all requires owning it.
OWNED_DISPATCH = frozenset({
    'virtual', 'interface', 'super', 'dynamic', 'tearoff_pre', 'tearoff_post',
})

# Owned by #67/#68 and already demonstrated for aot/cold+hot on arm64.
PRIOR_DISPATCH = frozenset({'direct'})

# Unreachable by construction, not merely undone. See the module docstring.
UNREACHABLE_OPTIMIZER_MODES = frozenset({'jit'})

TARGET_ARCH = 'arm64'


def row_cells(path):
    """Every (dispatch, optimizer_mode, heat) cell a T0 row fixture declares."""
    d = json.load(open(path))
    cells = set()
    for phase in ('pre_observation', 'post_observation'):
        for o in d.get(phase) or []:
            cells.add((o.get('dispatch'), o.get('optimizer_mode'),
                       o.get('heat_mode')))
    return d, cells


def inventory(t0_rows_dir):
    """Per-row cell accounting for #69.

    reachable    -- cells #69 may claim if it proves them
    prior        -- cells #67/#68 already own
    unreachable  -- cells no MAOT mechanism can ever reach
    """
    out = {}
    for path in sorted(glob.glob(os.path.join(t0_rows_dir, '*.json'))):
        d, cells = row_cells(path)
        if not cells:
            continue
        if not (OWNED_DISPATCH & {c[0] for c in cells}):
            continue
        unreachable = {c for c in cells
                       if c[1] in UNREACHABLE_OPTIMIZER_MODES}
        reachable = {c for c in cells - unreachable
                     if c[0] in OWNED_DISPATCH}
        prior = {c for c in cells - unreachable if c[0] in PRIOR_DISPATCH}
        out[d['row_id']] = {
            'declared_cells': sorted(cells),
            'reachable_by_69': sorted(reachable),
            'owned_by_67_68': sorted(prior),
            'unreachable_cells': sorted(unreachable),
            'row_result_now': d['result'],
            # The amended criterion, computed rather than asserted.
            'whole_row_promotable': len(unreachable) == 0,
            'why_not_promotable': (
                None if not unreachable else
                f'{len(unreachable)} of {len(cells)} declared cells are '
                f'{sorted(UNREACHABLE_OPTIMIZER_MODES)} cells, which no '
                f'Mutable-AOT mechanism can reach'),
        }
    return out


def summary(inv):
    tot = lambda k: sum(len(v[k]) for v in inv.values())  # noqa: E731
    return {
        'rows': len(inv),
        'declared_cells': tot('declared_cells'),
        'reachable_by_69': tot('reachable_by_69'),
        'owned_by_67_68': tot('owned_by_67_68'),
        'unreachable_cells': tot('unreachable_cells'),
        'rows_whole_row_promotable': sorted(
            r for r, v in inv.items() if v['whole_row_promotable']),
        'target_arch': TARGET_ARCH,
    }


if __name__ == '__main__':
    import sys
    here = os.path.dirname(os.path.abspath(__file__))
    rows = os.path.join(here, '..', '..', 't0', 'evidence', 'rows')
    inv = inventory(rows)
    rec = {'schema': 'maot.m5.cellmap/1', 'issue': 69,
           'summary': summary(inv), 'rows': inv}
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        here, '..', 'evidence', 'm5_cell_map.json')
    with open(out, 'w') as fh:
        json.dump(rec, fh, indent=2, sort_keys=True)
    print(json.dumps(rec['summary'], indent=2, sort_keys=True))
