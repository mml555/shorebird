#!/usr/bin/env python3
"""Derive the PRODUCTION CONSUMER universe from the producer/release graph.

WHY THIS REPLACES FILENAME GLOBS. Discovery previously decided what counts as a
production consumer from three patterns -- route_b/build_*.sh,
route_b/release*.sh and scripts/*.sh. That covered 12 of Route B's 38 scripts
and, worse, `scripts/*.sh` matched 5 files at the repo root while the 58
producer scripts actually live under selfhost/scripts/. Every mint_, publish_,
package_, stage_ and qualify_ path was outside the universe -- including
qualify_dual_kernel_cell.sh, which does pass --dynamic-interface. A negative
existential ("no complete release-bound validation source is present in
the current inventory") cannot be
proven over a universe drawn by naming convention.

HOW THE UNIVERSE IS DRAWN NOW, in three recorded tiers:

  named        a path SUPPORTED_STATE.yaml itself names. Production by the
               record that defines the supported stack.
  reachable    transitively invoked by a named member. Production by
               reachability, not by what it is called.
  surface      every script or Dart entrypoint under the bound product
               directories. Not asserted to be production -- included because
               a policy consumed anywhere here could plausibly be, and the
               negative existential is stronger if it holds over the union.

The negative result is claimed over the UNION, which is why the tiers do not
have to be adjudicated to support it. They are recorded so that a future
POSITIVE can be: a complete policy consumed by a `named` member means
something different from one consumed by a `surface` member.

WHAT IS EXCLUDED, and why it is recorded rather than silently dropped: vendored
third-party checkouts. bin/cache holds a Flutter checkout whose own dynamic
interfaces are not this fork's release policy. The count is reported so the
exclusion is visible.

usage: consumer_universe.py <repo-root> <supported-state.yaml> <out.json>
"""
import hashlib
import json
import pathlib
import re
import sys

REPO = pathlib.Path(sys.argv[1])
SUPPORTED = pathlib.Path(sys.argv[2])
OUT = sys.argv[3]

# The product surfaces the supported stack binds. Taken from G8's own
# product_directories list plus selfhost/scripts, which that list reaches
# through `scripts` in the repo's own layout.
SURFACE_DIRS = ['packages', 'bin', 'scripts', 'selfhost/scripts',
                'selfhost/engine/route_b']
EXECUTABLE_SUFFIXES = {'.sh', '.dart', '.bash', '.py'}
VENDORED = ('bin/cache/', 'third_party/', '/.git/', 'node_modules/')


def is_vendored(rel):
    r = f'/{rel}'
    return any(v in r for v in VENDORED)


def read(p):
    try:
        return p.read_text(errors='replace')
    except Exception:                                        # noqa: BLE001
        return None


universe = {}
excluded_vendored = []


def add(rel, tier, how):
    if rel in universe:
        # A path can enter more than one way; keep the strongest tier.
        order = {'named': 3, 'reachable': 2, 'surface': 1}
        if order[tier] > order[universe[rel]['tier']]:
            universe[rel].update(tier=tier, how=how)
        return
    universe[rel] = {'tier': tier, 'how': how}


# ---- tier: named by SUPPORTED_STATE -----------------------------------
sup_text = read(SUPPORTED) or ''
named_paths = set(re.findall(r'[A-Za-z0-9_./-]+\.(?:sh|dart)', sup_text))
for cand in sorted(named_paths):
    # A name may be bare (verify_supported_state.sh) or repo-relative.
    hits = []
    p = REPO / cand
    if p.is_file():
        hits.append(cand)
    else:
        base = pathlib.Path(cand).name
        for q in REPO.rglob(base):
            if q.is_file():
                rel = str(q.relative_to(REPO))
                if is_vendored(rel):
                    excluded_vendored.append(rel)
                else:
                    hits.append(rel)
    for rel in hits:
        add(rel, 'named', f'named in SUPPORTED_STATE.yaml as {cand!r}')

# ---- tier: surface ----------------------------------------------------
for d in SURFACE_DIRS:
    root = REPO / d
    if not root.is_dir():
        continue
    for p in sorted(root.rglob('*')):
        if not p.is_file() or p.suffix not in EXECUTABLE_SUFFIXES:
            continue
        rel = str(p.relative_to(REPO))
        if is_vendored(rel):
            excluded_vendored.append(rel)
            continue
        add(rel, 'surface', f'under bound product directory {d!r}')

# ---- tier: reachable (transitive closure over invocations) ------------
# A member invokes another if it mentions its basename. Coarse on purpose:
# over-inclusion widens the universe, which can only make the negative
# existential stronger, while under-inclusion is what the ruling faulted.
by_base = {}
for rel in universe:
    by_base.setdefault(pathlib.Path(rel).name, []).append(rel)

changed = True
rounds = 0
while changed and rounds < 10:
    changed = False
    rounds += 1
    for rel, rec in list(universe.items()):
        if rec['tier'] not in ('named', 'reachable'):
            continue
        body = read(REPO / rel)
        if not body:
            continue
        for base, targets in by_base.items():
            if base == pathlib.Path(rel).name or base not in body:
                continue
            for t in targets:
                if universe[t]['tier'] == 'surface':
                    universe[t].update(
                        tier='reachable',
                        how=f'invoked by {rel} (tier '
                            f'{rec["tier"]})')
                    changed = True

tiers = {}
for rel, rec in universe.items():
    tiers.setdefault(rec['tier'], []).append(rel)

doc = {
    'schema': 'route-b-di-1/consumer-universe/1',
    'repo_root': str(REPO),
    'supported_state': str(SUPPORTED.relative_to(REPO))
    if SUPPORTED.is_relative_to(REPO) else str(SUPPORTED),
    'supported_state_sha256': hashlib.sha256(
        SUPPORTED.read_bytes()).hexdigest() if SUPPORTED.is_file() else None,
    'how_drawn': 'named by SUPPORTED_STATE, plus transitive reachability from '
                 'those, plus every script/Dart entrypoint under the bound '
                 'product directories. The negative existential is claimed '
                 'over the UNION, so the tiers need not be adjudicated to '
                 'support it.',
    'surface_directories': SURFACE_DIRS,
    'executable_suffixes': sorted(EXECUTABLE_SUFFIXES),
    'vendored_excluded_count': len(set(excluded_vendored)),
    'vendored_exclusion_reason':
        "bin/cache holds a vendored Flutter checkout and third_party/ vendored "
        "sources; their own dynamic interfaces are not this fork's release "
        'policy. Counted so the exclusion is visible rather than silent.',
    'closure_rounds': rounds,
    'counts': {k: len(v) for k, v in sorted(tiers.items())},
    'total': len(universe),
    'members': dict(sorted(universe.items())),
}
json.dump(doc, open(OUT, 'w'), indent=2)
print(f'  universe: {len(universe)} members '
      f'({", ".join(f"{k}={len(v)}" for k, v in sorted(tiers.items()))})')
print(f'  vendored excluded: {len(set(excluded_vendored))}')
print(f'  closure rounds: {rounds}')
