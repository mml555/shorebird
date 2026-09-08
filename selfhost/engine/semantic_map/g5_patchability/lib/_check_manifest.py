#!/usr/bin/env python3
"""Postcondition for the manifest-writing step of run_route2.sh.

Writing the manifest is not the same as writing a CORRECT manifest: a step that
succeeds can still record a digest that no longer matches the artifact it names.
This re-reads the banked manifest and compares each recorded digest against the
live file. Prints 'ok', or one line per mismatch, and exits non-zero.
"""
import hashlib
import json
import pathlib
import sys

G, D, GS, W = sys.argv[1:5]


def sha(p):
    return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()


try:
    m = json.load(open(f'{G}/instrumentation/MANIFEST.json'))
except Exception as ex:                                  # noqa: BLE001
    print(f'manifest does not parse: {ex}')
    sys.exit(1)

bad = []
checks = [
    ('delta_2.sha256', m['delta_2']['sha256'],
     sha(f'{G}/instrumentation/0002-g5-inlining-relation.patch')),
    ('built.instrumented_gen_snapshot_sha256_schema6',
     m['built']['instrumented_gen_snapshot_sha256_schema6'], sha(GS)),
    ('route2_witness.subject.aot_sha256',
     m['route2_witness']['subject']['aot_sha256'], sha(f'{W}/app_s6r.aot')),
    ('route2_witness.subject.input_kernel_sha256',
     m['route2_witness']['subject']['input_kernel_sha256'],
     sha(f'{W}/prepass3.dill')),
]
for name, recorded, live in checks:
    if recorded != live:
        bad.append(f'{name}: recorded {recorded}, live {live}')

for f, v in m['replay']['per_file'].items():
    live = sha(f'{D}/{f}')
    if v['built_sha256'] != live:
        bad.append(f'replay.per_file[{f}].built_sha256: recorded '
                   f'{v["built_sha256"]}, live {live}')
    if not v['equal']:
        bad.append(f'replay.per_file[{f}] is not marked equal')
if not m['replay']['all_files_equal']:
    bad.append('replay.all_files_equal is false')

# The banked reader state must be the run just performed, not a stale copy.
try:
    banked = json.load(open(f'{G}/evidence/inlining_state.json'))
    fresh = json.load(open(f'{W}/s6r.json'))
except Exception as ex:                                  # noqa: BLE001
    bad.append(f'reader state unreadable: {ex}')
else:
    if banked != fresh:
        bad.append('evidence/inlining_state.json differs from the run that '
                   'just produced it')
    a = banked.get('accounting', {})
    if a.get('accounted') != a.get('total_g1_rows'):
        bad.append(f'banked accounting does not reconcile: {a}')

print('ok' if not bad else '\n'.join(bad))
sys.exit(1 if bad else 0)
