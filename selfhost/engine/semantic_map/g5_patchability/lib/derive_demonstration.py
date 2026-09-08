#!/usr/bin/env python3
"""Derive the demonstrated set WITHOUT a hand-written call-site map.

collect_demonstration.py needs a map from printed field to declaration, parsed
out of the probe's _state(). A real application has no _state(), so that method
does not generalise -- and hand-writing a map for Wonderous would put the
demonstration's completeness back on prose, which the scorer refuses.

THE DERIVATION. Each patch container carries ONE target, so within a run any
observed change is attributable to that target. That is enough:

    moved  = observable fields whose value changed after the patch
    V_old  = the pre-patch values of those fields
    stale  = fields whose post-patch value is still one of V_old
    demonstrated = moved is non-empty AND stale is empty

No field needs to be named in advance. `stale` is the load-bearing half: a
field still showing a value that the patch demonstrably moved elsewhere is a
call site that did not observe the patch.

DIRECTION OF ERROR. If an unrelated declaration coincidentally shares V_old,
its field is misread as a stale site of this target. That OVER-reports
staleness, which withdraws a demonstration rather than manufacturing one.

WHAT THIS DOES NOT ESTABLISH. Only call sites actually exercised during the run
are observed. A site that never ran is not evidence of anything, and this tool
reports the exercised-field count so that limit stays visible rather than
implied.

usage: derive_demonstration.py <dartaotruntime> <aot> <g1.json> <out.json> \
           <library>#<owner>#<kind>#<name>=<patch.sbrb> [...]
"""
import json
import re
import subprocess
import sys

RUNTIME, AOT, G1, OUT = sys.argv[1:5]
SPECS = sys.argv[5:]

g1 = json.load(open(G1))
BY_KEY = {f"{r['library']}#{r.get('owner') or ''}#{r['kind']}#{r['name']}":
          r['declaration_id'] for r in g1['rows']}


def fields(line):
    return dict(re.findall(r'(\w+)=(\S+)', line))


rows = []
for spec in SPECS:
    key, _, patch = spec.rpartition('=')
    did = BY_KEY.get(key)
    if did is None:
        sys.exit(f'derive_demonstration: {key!r} is not in the G1 projection')
    p = subprocess.run([RUNTIME, AOT, patch], capture_output=True, text=True)
    out = p.stdout + p.stderr
    if p.returncode != 0:
        sys.exit(f'derive_demonstration: the patched run failed for {key}:\n'
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
        sys.exit(f'derive_demonstration: {key} produced no before/after state')

    observed = sorted(set(before) & set(after))
    moved = [f for f in observed if before[f] != after[f]]
    v_old = {before[f] for f in moved}
    stale = [f for f in observed if f not in moved and after[f] in v_old]

    rows.append({
        'key': key,
        'declaration_id': did,
        'patch': patch,
        'target': key,
        'derivation': 'single-target diff; no call-site map',
        'observed_fields': observed,
        'moved_values': sorted(v_old),
        # THE FULL OBSERVED STATE, so the scorer can RECOMPUTE the derivation
        # instead of trusting it. Without this, deleting a stale site and
        # lowering the expected count is self-consistent and undetectable.
        'state_before': {f: before[f] for f in observed},
        'state_after': {f: after[f] for f in observed},
        'call_sites': [{'name': f, 'ordinary': True, 'before': before[f],
                        'after': after[f], 'moved': f in moved}
                       for f in moved + stale],
        'sites_expected': len(moved) + len(stale),
        # Context only; the scorer ignores both.
        'attach_ok': attach,
        'direct_invoke': invoke,
    })

json.dump({
    'schema': 'semantic-map-1/g5-demonstration/2',
    'aot': AOT,
    'runtime': RUNTIME,
    'derived_from_predictor': False,
    'how': 'single-target diff of the program\'s own observable state; a field '
           'still showing a value the patch moved elsewhere is a stale site',
    'call_site_map': {r['key']: [s['name'] for s in r['call_sites']]
                      for r in rows},
    'printed_fields': sorted({f for r in rows for f in r['observed_fields']}),
    'excluded_printed_fields': {},
    'exercised_fields_only': True,
    'rows': rows,
}, open(OUT, 'w'), indent=2)

for r in rows:
    moved = [s['name'] for s in r['call_sites'] if s['moved']]
    stale = [s['name'] for s in r['call_sites'] if not s['moved']]
    verdict = 'demonstrated' if moved and not stale else 'NOT demonstrated'
    print(f"  {r['key'].split('#')[-1]:16} {verdict:16} "
          f"moved={moved} stale={stale} observed={len(r['observed_fields'])}")
