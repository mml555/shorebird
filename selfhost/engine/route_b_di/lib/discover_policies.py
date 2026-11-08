#!/usr/bin/env python3
"""Discover every candidate module-validation policy, and who consumes it.

Three ways a policy can reach a producer, and the previous version looked for
only the first:

  committed    a file carrying the permission keys. ANY extension -- a policy
               is not required to be named *.yaml, and searching only YAML
               would miss one written as .yml, .txt, or with no suffix.
  emitted      generated at build time: a producer that writes the permission
               keys itself, through a heredoc or a string literal. Such a
               policy has no committed file to find.
  argument     whatever a producer actually passes to --validate or
               --dynamic-interface, including a computed or temporary path. If
               a producer passes something, that something is a candidate
               however it was produced.

CONSUMPTION IS DECIDED OVER THE DERIVED UNIVERSE, not filename patterns. A
committed policy counts as consumed if any universe member references it or
passes it as an argument. The universe is the union of tiers from
consumer_universe.py, so the negative existential does not depend on where the
production boundary is drawn.

usage: discover_policies.py <repo-root> <universe.json> <out.json>
"""
import hashlib
import json
import pathlib
import re
import sys

REPO = pathlib.Path(sys.argv[1])
UNIVERSE = json.loads(pathlib.Path(sys.argv[2]).read_text())
OUT = sys.argv[3]

SECTIONS = ['callable', 'extendable', 'can-be-overridden',
            'can-be-used-as-type']
PERMISSION_KEYS = r'^\s*(extendable|can-be-overridden|can-be-used-as-type)\s*:'
# Inside a heredoc or string the keys are usually still line-anchored, but a
# generator may emit them with a writeln, so accept a quoted form too.
EMIT_KEYS = (r'(?:^\s*|["\'])(extendable|can-be-overridden|'
             r'can-be-used-as-type)\s*:')
ARG_SITES = r'--(?:validate|dynamic-interface)[=\s]+([^\s;)"\']+)'
VENDORED = ('bin/cache/', 'third_party/', '/.git/', 'node_modules/')
TEXT_SUFFIXES = {'.yaml', '.yml', '.txt', '.json', '.cfg', '.conf', '.di',
                 '.policy', '.interface', ''}


def is_vendored(rel):
    r = f'/{rel}'
    return any(v in r for v in VENDORED)


def read(p):
    try:
        return p.read_text(errors='replace')
    except Exception:                                        # noqa: BLE001
        return None


def sha(p):
    try:
        return hashlib.sha256(p.read_bytes()).hexdigest()
    except Exception:                                        # noqa: BLE001
        return None


def sections_in(text):
    return {s: bool(re.search(rf'^{re.escape(s)}:', text, re.M))
            for s in SECTIONS}


members = UNIVERSE['members']
member_text = {}
for rel in members:
    t = read(REPO / rel)
    if t:
        member_text[rel] = t

# ---- argument sites --------------------------------------------------
arg_sites = []
for rel, t in member_text.items():
    for m in re.finditer(ARG_SITES, t):
        arg_sites.append({'consumer': rel, 'tier': members[rel]['tier'],
                          'argument': m.group(1)})

# ---- emitted policies ------------------------------------------------
emitted = []
for rel, t in member_text.items():
    keys = sorted(set(re.findall(EMIT_KEYS, t)))
    if keys:
        emitted.append({'consumer': rel, 'tier': members[rel]['tier'],
                        'permission_keys_emitted': keys,
                        'all_four': sorted(set(keys) | {'callable'})
                        == sorted(SECTIONS)})

# ---- committed policy files, any extension --------------------------
committed = []
scanned = 0
for p in sorted(REPO.rglob('*')):
    if not p.is_file():
        continue
    rel = str(p.relative_to(REPO))
    if is_vendored(rel):
        continue
    if p.suffix.lower() not in TEXT_SUFFIXES:
        continue
    if p.stat().st_size > 2_000_000:
        continue
    scanned += 1
    t = read(p)
    if not t or not re.search(PERMISSION_KEYS, t, re.M):
        continue
    base = p.name
    referenced_by = sorted(
        r for r, txt in member_text.items() if base in txt and r != rel)
    arg_targets = sorted(
        a['consumer'] for a in arg_sites
        if base in a['argument'] or rel in a['argument'])
    consumers = sorted(set(referenced_by) | set(arg_targets))
    committed.append({
        'path': rel,
        'sha256': sha(p),
        'sections': sections_in(t),
        'referenced_by': consumers,
        'consumer_tiers': sorted({members[c]['tier'] for c in consumers}),
        'release_consumed': bool(consumers),
    })

consumed = [c for c in committed if c['release_consumed']]
unconsumed = [c for c in committed if not c['release_consumed']]
complete_committed = [c for c in committed
                      if all(c['sections'].values())]

doc = {
    'schema': 'route-b-di-1/policy-discovery/2',
    'universe_total': UNIVERSE['total'],
    'universe_counts': UNIVERSE['counts'],
    'text_files_scanned': scanned,
    'suffixes_scanned': sorted(TEXT_SUFFIXES),
    'patterns': {'committed': PERMISSION_KEYS, 'emitted': EMIT_KEYS,
                 'argument_sites': ARG_SITES},
    'committed_policies': committed,
    'committed_consumed': [c['path'] for c in consumed],
    'committed_unconsumed': [c['path'] for c in unconsumed],
    'committed_carrying_all_four_sections': [c['path']
                                             for c in complete_committed],
    'emitted_policies': emitted,
    'argument_sites': arg_sites,
    'negative_existential': {
        'claim': 'no committed policy carrying all four sections is consumed '
                 'by any member of the universe, and no universe member emits '
                 'all four',
        'committed_complete_and_consumed': [
            c['path'] for c in complete_committed if c['release_consumed']],
        'emitting_all_four': [e['consumer'] for e in emitted if e['all_four']],
    },
}
json.dump(doc, open(OUT, 'w'), indent=2)

print(f'  universe members read      : {len(member_text)}')
print(f'  text files scanned         : {scanned}')
print(f'  committed policies found   : {len(committed)} '
      f'({len(consumed)} consumed, {len(unconsumed)} not)')
print(f'  carrying all four sections : '
      f'{[c["path"] for c in complete_committed] or "none"}')
print(f'  producers EMITTING keys    : '
      f'{[e["consumer"] for e in emitted] or "none"}')
print(f'  --validate/--dynamic-interface argument sites: {len(arg_sites)}')
for a in arg_sites[:8]:
    print(f'      {a["tier"]:9} {a["consumer"]} -> {a["argument"]}')
ne = doc['negative_existential']
print(f'  complete AND consumed      : '
      f'{ne["committed_complete_and_consumed"] or "none"}')
print(f'  emitting all four          : {ne["emitting_all_four"] or "none"}')
