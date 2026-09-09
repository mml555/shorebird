#!/usr/bin/env python3
"""List YAMLs carrying the permission keys that a RELEASE BUILD consumes.

Split out of the runner because a candidate is only a production policy if a
release or build script references it -- pattern-matching any YAML with the
right keys found four experiment probe fixtures and would have supported
"derivable" on them.

Prints one repo-relative path per line: the release-consumed candidates only.
The excluded fixtures are the collector's business to record.

usage: find_candidates.py <repo-root>
"""
import pathlib
import re
import sys

REPO = pathlib.Path(sys.argv[1])
KEYS = r'^\s*(extendable|can-be-overridden|can-be-used-as-type)\s*:'

scripts = ''
for g in ('selfhost/engine/route_b/build_*.sh',
          'selfhost/engine/route_b/release*.sh', 'scripts/*.sh'):
    for p in REPO.glob(g):
        try:
            scripts += p.read_text(errors='replace')
        except Exception:                                    # noqa: BLE001
            pass

for g in ('selfhost/*.yaml', 'selfhost/**/*.yaml', 'packages/**/*.yaml'):
    for p in sorted(REPO.glob(g)):
        if not p.is_file() or p.name.endswith('.patch'):
            continue
        try:
            t = p.read_text(errors='replace')
        except Exception:                                    # noqa: BLE001
            continue
        if re.search(KEYS, t, re.M) and p.name in scripts:
            print(p.relative_to(REPO))
