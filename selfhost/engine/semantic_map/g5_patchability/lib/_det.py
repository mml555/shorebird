#!/usr/bin/env python3
"""Compare two reader outputs. Prints four tokens for run_route2.sh to assert.

Each token is either the expected word or 'x', so the caller asserts a value
rather than interpreting prose.
"""
import json, sys

a, b = (json.load(open(p)) for p in sys.argv[1:3])
da, db = a['diagnostics'], b['diagnostics']
print('note' if da['note_section_sha256'] == db['note_section_sha256'] else 'x',
      'recs' if da['records'] == db['records'] else 'x',
      'states' if a['states'] == b['states'] else 'x',
      # The weaker claim must not be quietly upgraded: if these ever became
      # equal the transcript would be asserting something it has not shown.
      'aotdiff' if da['aot_sha256'] != db['aot_sha256'] else 'x')
