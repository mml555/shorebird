#!/usr/bin/env python3
"""Merge one validation attempt result into a JSON map. usage:
_merge_attempt.py <json> <path> <true|false>"""
import json
import sys

d = json.loads(sys.argv[1])
d[sys.argv[2]] = {'produced_module': sys.argv[3] == 'true'}
print(json.dumps(d))
