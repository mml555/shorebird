#!/usr/bin/env python3
"""Does the declared product surface cover #57's minimum?

A helper file rather than an inline one-liner: a Python set literal on a zsh
command line is brace-expanded, which silently produced an empty answer and an
assertion that failed for a shell reason rather than a real one.
"""
import json
import sys

REQUIRED = ('packages', 'bin', 'selfhost/engine/route_b',
            'selfhost/compatibility.yaml')
paths = set(json.load(open(sys.argv[1]))['product_directories']['paths'])
print(all(r in paths for r in REQUIRED))
