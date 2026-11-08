#!/usr/bin/env python3
"""Positive control for _check_manifest.py's SEMANTIC identity checks.

Every digest in a manifest can be individually correct while the manifest is
internally contradictory -- that is how a fresh AOT SHA came to sit on the
withdrawn subject's filename, kernel and recipe. So the checker must reject a
manifest whose hashes are right and whose IDENTITY is wrong, and this proves it
does by mutating a copy per arm. The banked manifest is never edited.

usage: falsify_manifest.py <G> <dart-tree> <gen_snapshot> <workdir>
"""
import copy
import json
import os
import subprocess
import sys

G, D, GS, W = sys.argv[1:5]
CHECK = os.path.join(G, 'lib', '_check_manifest.py')
BASE = json.load(open(os.path.join(G, 'instrumentation', 'MANIFEST.json')))
results = []


def run(label, mutate, expect_fragment):
    m = copy.deepcopy(BASE)
    mutate(m)
    path = os.path.join(W, 'manifest_control.json')
    json.dump(m, open(path, 'w'), indent=2)
    p = subprocess.run([sys.executable, CHECK, G, D, GS, W, path],
                       capture_output=True, text=True)
    out = (p.stdout + p.stderr).strip()
    if p.returncode == 0:
        results.append((label, 'FAIL', 'checker accepted it'))
    elif expect_fragment not in out:
        results.append((label, 'FAIL',
                        f'refused, but not for the stated reason: '
                        f'{out.splitlines()[0][:88]}'))
    else:
        results.append((label, 'pass', out.splitlines()[0][:88]))


def sub(m):
    return m['route2_witness']['subject']


# The baseline must be accepted, or every arm below is vacuous.
p = subprocess.run([sys.executable, CHECK, G, D, GS, W,
                    os.path.join(G, 'instrumentation', 'MANIFEST.json')],
                   capture_output=True, text=True)
results.append(('BASELINE the banked manifest is accepted',
                'pass' if p.returncode == 0 else 'FAIL',
                (p.stdout + p.stderr).strip().splitlines()[0][:88]))

# Right hash, wrong filename -- the exact defect this checker exists for.
run('subject.aot renamed to the withdrawn subject',
    lambda m: sub(m).__setitem__('aot', 'app_s6r.aot'),
    'subject.aot')
run('subject.input_kernel renamed to the pre-pass kernel',
    lambda m: sub(m).__setitem__('input_kernel', 'prepass3.dill'),
    'subject.input_kernel')
run('recipe left describing the withdrawn lane',
    lambda m: sub(m).__setitem__(
        'recipe', 'gen_snapshot --snapshot_kind=app-aot-elf '
                  '--patchable_static_calls --elf=app_s6r.aot prepass3.dill'),
    'subject.recipe')
run('recipe no longer names the kernel it claims',
    lambda m: sub(m).__setitem__(
        'recipe', 'gen_snapshot --snapshot_kind=app-aot-elf '
                  '--patchable_static_calls --elf=app_release.aot'),
    'does not name subject.input_kernel')
run('a withdrawn artifact reappears outside withdrawn_subjects',
    lambda m: m['route2_witness'].__setitem__('note', 'built from prepass3.dill'),
    'still appears outside withdrawn_subjects')
run('the withdrawn subjects are dropped from the record',
    lambda m: m['route2_witness'].__setitem__('withdrawn_subjects', []),
    'withdrawn subjects must stay recorded')
run('determinism build_b renamed',
    lambda m: m['route2_witness']['determinism']['build_b'].__setitem__(
        'aot', 'app_release.aot'),
    'determinism.build_b.aot')
run('determinism claims the two AOTs are byte-equal',
    lambda m: m['route2_witness']['determinism'].__setitem__(
        'aot_sha256_equal', True),
    'must not claim the two AOTs are byte-equal')
run('falsification arm count left stale',
    lambda m: m['reader_falsification'].__setitem__('arms', 28),
    'reader_falsification.arms')
run('one control dropped from the falsification record',
    lambda m: m['reader_falsification'].__setitem__(
        'controls', m['reader_falsification']['controls'][:1]),
    'must record both controls')

print(f'{"arm":54} {"result":6} detail')
print('-' * 104)
for label, verdict, detail in results:
    print(f'{label:54} {verdict:6} {detail}')
failed = [r for r in results if r[1] == 'FAIL']
print('-' * 104)
print(f'arms={len(results)} passed={len(results) - len(failed)} failed={len(failed)}')
print('SM1_G5_MANIFEST_SEMANTICS: '
      + ('ALL_SWAPS_REFUSED' if not failed else 'DEFECTS_PRESENT'))
sys.exit(1 if failed else 0)
