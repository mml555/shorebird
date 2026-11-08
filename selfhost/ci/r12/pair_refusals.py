#!/usr/bin/env python3
"""Pair each sealed refusal with the client request that produced it.

Emits one "client_path<TAB>gcs_path" line per distinct refusal.

The overlay is keyed by the client path, but the seal refuses the REWRITTEN
upstream path, and the two differ by more than a bucket prefix -- the artifact
proxy also remaps the engine hash. Deriving one from the other by string surgery
writes correct bytes to an address nothing requests. So the pairing is read out
of the log: a 302's Location names the gcs path its own uri maps to.
"""
import json, re, sys

rows = []
for line in sys.stdin:
    m = re.search(r'(\{"request".*\})\s*$', line)
    if not m:
        continue
    try:
        d = json.loads(m.group(1))
    except Exception:
        continue
    rows.append(d)

gcs_to_client = {}
for d in rows:
    loc = d.get('resp_headers', {}).get('Location', [None])[0]
    if d.get('status') == 302 and loc:
        gcs_to_client[loc] = d['request']['uri']

seen, out = set(), []
for d in rows:
    if d.get('status') != 502:
        continue
    gcs = d['request']['uri']
    if gcs in seen:
        continue
    seen.add(gcs)
    client = gcs_to_client.get(gcs)
    if client is None:
        # No redirect produced it: the client asked for this path directly.
        client = gcs[len('/gcs/'):] if gcs.startswith('/gcs/') else gcs
        if client.startswith('download.shorebird.dev/flutter_infra_release/'):
            client = client[len('download.shorebird.dev/'):]
        client = '/' + client.lstrip('/')
    out.append(f"{client}\t{gcs}")
print("\n".join(out))
