#!/usr/bin/env python3
"""Check the B0 discovery record's properties, not a remembered count.

The assertion this replaces expected exactly 4 excluded fixtures -- a number
produced by a regex compiled WITHOUT re.MULTILINE, so `^` matched only at the
start of a file. With the flag the real count is 27, and hard-coding either
number asserts a coincidence rather than a property.

usage: _check_discovery.py <b0_sources.json> <consumed|nonvacuous|clean>
"""
import json
import sys

try:
    doc = json.load(open(sys.argv[1]))
except Exception as ex:                                      # noqa: BLE001
    print(f'unreadable:{type(ex).__name__}')
    raise SystemExit(1)
d = doc['discovery']
mode = sys.argv[2]

if mode == 'consumed':
    print(len(d['referenced_by_a_release_build']))
elif mode == 'nonvacuous':
    # The exclusion must actually exclude something, or "nothing was counted
    # as policy" would be true because nothing was examined.
    print(len(d['excluded_as_experiment_fixtures']) > 0)
elif mode == 'clean':
    # No excluded path may appear as a source whose role could be complete:
    # excluded means not release-consumed, and the role rule requires
    # consumption. Checked here so the two records cannot disagree.
    excluded = set(d['excluded_as_experiment_fixtures'])
    bad = [k for k, v in doc['sources'].items()
           if v.get('spec_path') in excluded and v.get('release_consumed')]
    print(not bad)
else:
    print(f'unknown mode {mode!r}')
    raise SystemExit(1)
