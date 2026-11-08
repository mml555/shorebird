#!/usr/bin/env python3
"""Record a digest for every mandatory artifact, after the gates regenerate.

This is per-run provenance, not a frozen expectation. The transcripts carry
generated-at timestamps, so a committed digest would fail on every legitimate
rebuild -- but without any recorded digest there is no generic integrity check,
and a present-but-corrupted artifact is undetectable for most files.

usage: snapshot_digests.py <semantic-map-dir> <inventory.json> <out.json>
"""
import hashlib
import json
import pathlib
import sys

SM, INV, OUT = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
inv = json.load(open(INV))
artifacts, missing = {}, []
for gate, spec in inv['gates'].items():
    for rel in spec['artifacts']:
        key = f'{gate}/{rel}'
        p = SM / key
        if p.exists():
            artifacts[key] = hashlib.sha256(p.read_bytes()).hexdigest()
        else:
            missing.append(key)
json.dump({'schema': 'semantic-map-1/g8-artifact-digests/1',
           'why': 'this run\'s provenance; see the module docstring',
           'artifacts': artifacts, 'missing': missing},
          open(OUT, 'w'), indent=2)
print(f'  {len(artifacts)} mandatory artifacts digested'
      + (f', {len(missing)} MISSING: {missing}' if missing else ''))
sys.exit(1 if missing else 0)
