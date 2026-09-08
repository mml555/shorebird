#!/usr/bin/env python3
"""Derive the DEMONSTRATED-PATCHABLE set from real runs of the shipping path.

This is the independent half of the subset check. It applies each patch
container to the canonical release with dartaotruntime and reads the program's
own before/after output, so nothing here consults the predictor. The output
records attach success and the direct C++ invoke for context, and the scorer
ignores both.

CALL-SITE MAP. Which printed field belongs to which declaration is a fact about
the probe source, not an inference: _state() in probe/callsite_target.dart
prints one field per call shape, and Base.work is reached by three of them
while `other` is a DIFFERENT declaration (Other.work).

DECLARATION IDENTITY comes from the G1 projection, never synthesized here: the
subset check joins prediction to demonstration by declaration_id, so a locally
invented id would silently make every declaration look undemonstrated.

CALL-SITE COMPLETENESS IS DERIVED, NOT TRUSTED. An under-observed demonstration
would inflate the subset check: if only Base.work's devirtualizable site were
observed, the declaration would look demonstrated. So the printed field list is
parsed out of the probe's own _state() and every field must be either mapped to
a declaration or explicitly excluded with a reason. Each emitted row carries
sites_expected, and the scorer refuses a row whose observed sites do not match
it.

usage: collect_demonstration.py <dartaotruntime> <aot> <g1.json> <probe.dart> \
           <out.json> <target>=<patch.sbrb> [...]
"""
import json
import pathlib
import re
import subprocess
import sys

RUNTIME, AOT, G1, PROBE, OUT = sys.argv[1:6]
SPECS = sys.argv[6:]
LIB = 'package:dynamic_modules/callsite_target.dart'

g1 = json.load(open(G1))
BY_IDENTITY = {(r['library'], r.get('owner'), r['kind'], r['name']):
               r['declaration_id'] for r in g1['rows']}

# target -> (owner, kind, name, [printed fields that are ordinary call sites])
TARGETS = {
    'alpha': (None, 'method', 'alpha', ['alpha']),
    'beta': (None, 'method', 'beta', ['beta']),
    'Base.work': ('Base', 'method', 'work', ['virtual', 'direct', 'inlined']),
    'smallTarget': (None, 'method', 'smallTarget', ['small', 'callsSmall']),
    'tearOffTarget': (None, 'method', 'tearOffTarget', ['tearOff']),
}


# Printed fields the probe emits but that belong to no patch target here.
UNMAPPED = {
    'other': 'Other.work -- a DIFFERENT declaration, the untargeted control',
}


def fields(line):
    return dict(re.findall(r'(\w+)=(\S+)', line))


def printed_fields(path):
    """The field names _state() actually prints, from the probe source."""
    src = pathlib.Path(path).read_text()
    start = src.index('void _state(')
    body = src[start:src.index('\n\n', start)]
    return set(re.findall(r"(\w+)=\$\{", body)) | set(
        re.findall(r"(\w+)=\$(?!\{)", body))


PRINTED = printed_fields(PROBE)
mapped = {f for _, _, _, sites in TARGETS.values() for f in sites}
missing = PRINTED - mapped - set(UNMAPPED)
if missing:
    sys.exit(f'collect_demonstration: the probe prints {sorted(missing)}, '
             f'which no target maps and nothing excludes. An unmapped call '
             f'site would let a stale site go unobserved.')
stray = mapped - PRINTED
if stray:
    sys.exit(f'collect_demonstration: mapped fields {sorted(stray)} are not '
             f'printed by the probe')


rows = []
for spec in SPECS:
    target, _, patch = spec.partition('=')
    if target not in TARGETS:
        sys.exit(f'collect_demonstration: no call-site map for {target!r}')
    owner, kind, name, sites = TARGETS[target]
    p = subprocess.run([RUNTIME, AOT, patch], capture_output=True, text=True)
    out = p.stdout + p.stderr
    if p.returncode != 0:
        sys.exit(f'collect_demonstration: the patched run failed for {target}:\n'
                 f'{out.strip()[-400:]}')
    before = after = None
    invoke = None
    attach = False
    for line in out.splitlines():
        if line.startswith('before '):
            before = fields(line)
        elif line.startswith('after '):
            after = fields(line)
        elif 'C++ invoke of target returned:' in line:
            invoke = line.rsplit(':', 1)[1].strip()
        elif 'IsInterpreted=1 HasBytecode=1' in line:
            attach = True
    if before is None or after is None:
        sys.exit(f'collect_demonstration: {target} produced no before/after '
                 f'state; refusing to guess')
    call_sites = [{
        'name': f,
        'ordinary': True,
        'before': before.get(f),
        'after': after.get(f),
        'moved': (f in before and f in after and before[f] != after[f]),
    } for f in sites]
    did = BY_IDENTITY.get((LIB, owner, kind, name))
    if did is None:
        sys.exit(f'collect_demonstration: {target} is not in the G1 projection '
                 f'as ({LIB}, {owner}, {kind}, {name}); refusing to invent an '
                 f'identity the subset check would then fail to join')
    rows.append({
        'key': f'{LIB}#{owner or ""}#{kind}#{name}',
        'declaration_id': did,
        'target': target,
        'patch': patch,
        'call_sites': call_sites,
        # Declared from the source-derived map, so the scorer can refuse a row
        # whose observed sites were reduced after the fact.
        'sites_expected': len(sites),
        # Context only. The scorer ignores both, by design.
        'attach_ok': attach,
        'direct_invoke': invoke,
    })

json.dump({
    'schema': 'semantic-map-1/g5-demonstration/1',
    'aot': AOT,
    'runtime': RUNTIME,
    'derived_from_predictor': False,
    'call_site_map': {t: v[3] for t, v in TARGETS.items()},
    'call_site_map_source': PROBE,
    'printed_fields': sorted(PRINTED),
    'excluded_printed_fields': UNMAPPED,
    'how': 'each patch applied with dartaotruntime; moved/stale read from the '
           "program's own before/after output",
    'rows': rows,
}, open(OUT, 'w'), indent=2)

for r in rows:
    moved = [s['name'] for s in r['call_sites'] if s['moved']]
    stale = [s['name'] for s in r['call_sites'] if not s['moved']]
    verdict = 'demonstrated' if moved and not stale else 'NOT demonstrated'
    print(f"  {r['target']:16} {verdict:16} moved={moved} stale={stale} "
          f"(invoke={r['direct_invoke']})")
