#!/usr/bin/env python3
"""Postcondition for the manifest-writing step of run_route2.sh.

Writing the manifest is not the same as writing a CORRECT manifest: a step that
succeeds can still record a digest that no longer matches the artifact it names.

It also checks the SEMANTIC IDENTITY of the canonical subject, not only its
digests. A manifest whose every hash is individually correct can still be
internally contradictory -- that is exactly how a new AOT SHA came to be
written onto the withdrawn subject's filename, kernel and recipe -- so the
filename, kernel filename, recipe, determinism build names and falsification
metadata are all required to describe the artifact actually produced.

SCOPE. This checks a LOAD-BEARING SUBSET, not every digest in the file:

  * delta_2.sha256                                  the incremental patch
  * built.instrumented_gen_snapshot_sha256_schema6  the producer binary
  * route2_witness.subject.aot_sha256               the canonical subject
  * route2_witness.subject.input_kernel_sha256      its input kernel
  * replay.per_file[*].built_sha256 and .equal      the replay claim
  * evidence/inlining_state.json                    is the run just performed,
                                                    and its accounting reconciles

Digests recorded for withdrawn or historical artifacts are deliberately not
checked: they name files this run no longer produces. Prints 'ok', or one line
per mismatch, and exits non-zero.
"""
import hashlib
import json
import pathlib
import sys

G, D, GS, W = sys.argv[1:5]
# A control can point this at a mutated COPY, so the banked manifest is never
# edited in place to test the checker.
MANIFEST = sys.argv[5] if len(sys.argv) > 5 else f'{G}/instrumentation/MANIFEST.json'


def sha(p):
    return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()


try:
    m = json.load(open(MANIFEST))
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
     m['route2_witness']['subject']['aot_sha256'], sha(f'{W}/app_release.aot')),
    ('route2_witness.subject.input_kernel_sha256',
     m['route2_witness']['subject']['input_kernel_sha256'],
     sha(f'{W}/release3.dill')),
]
for name, recorded, live in checks:
    if recorded != live:
        bad.append(f'{name}: recorded {recorded}, live {live}')

# ---- SEMANTIC IDENTITY OF THE CANONICAL SUBJECT -------------------------
subj = m['route2_witness'].get('subject', {})
EXPECT = {
    'aot': 'app_release.aot',
    'input_kernel': 'release3.dill',
    'recipe': 'gen_snapshot --snapshot_kind=app-aot-elf '
              '--patchable_static_calls --elf=app_release.aot release3.dill',
}
for field, want in EXPECT.items():
    if subj.get(field) != want:
        bad.append(f'subject.{field}: recorded {subj.get(field)!r}, '
                   f'expected {want!r}')
# The recipe must name the same two files the identity fields do -- a recipe
# left describing a withdrawn lane is the defect this exists to catch.
recipe = subj.get('recipe') or ''
for field in ('aot', 'input_kernel'):
    nm = subj.get(field)
    if nm and nm not in recipe:
        bad.append(f'subject.recipe does not name subject.{field} ({nm})')
for wd in ('app_s6.aot', 'app_s6r.aot', 'prepass3.dill'):
    if wd in json.dumps({k: v for k, v in m['route2_witness'].items()
                         if k != 'withdrawn_subjects'}):
        bad.append(f'withdrawn artifact {wd} still appears outside '
                   f'withdrawn_subjects')
if len(m['route2_witness'].get('withdrawn_subjects', [])) < 2:
    bad.append('both withdrawn subjects must stay recorded as historical')

det = m['route2_witness'].get('determinism', {})
for half, want in (('build_a', 'app_release.aot'),
                   ('build_b', 'app_release_b.aot')):
    if det.get(half, {}).get('aot') != want:
        bad.append(f'determinism.{half}.aot: recorded '
                   f'{det.get(half, {}).get("aot")!r}, expected {want!r}')
if det.get('aot_sha256_equal') is not False:
    bad.append('determinism must not claim the two AOTs are byte-equal')

# ---- FALSIFICATION METADATA MATCHES THE TRANSCRIPT ---------------------
import re
fals = pathlib.Path(f'{G}/evidence/reader_falsification.txt').read_text()
counts = re.findall(r'arms=(\d+) passed=(\d+) failed=(\d+)', fals)
rf = m.get('reader_falsification', {})
if not counts:
    bad.append('reader falsification transcript records no arm counts')
else:
    if rf.get('arms') != int(counts[0][0]):
        bad.append(f'reader_falsification.arms: recorded {rf.get("arms")}, '
                   f'transcript says {counts[0][0]}')
    if len(counts) >= 3 and len(rf.get('controls', [])) != 2:
        bad.append('reader_falsification must record both controls')

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
    fresh = json.load(open(f'{W}/app_release.json'))
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
