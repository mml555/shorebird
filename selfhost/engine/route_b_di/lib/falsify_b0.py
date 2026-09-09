#!/usr/bin/env python3
"""Falsify the B0 classifier.

VALIDATION_INPUT_UNDERIVED stops #61. A classifier that reported it regardless
of its input would stop the issue for no reason -- and one that reported
DERIVABLE regardless would send B1 at Route B on no evidence. Both directions
need negatives, so each arm names the input it changes and the result required.

usage: falsify_b0.py <derive_tool> <repo-root> <freeze-manifest> <workdir>
"""
import json
import pathlib
import shutil
import subprocess
import sys

TOOL = pathlib.Path(sys.argv[1])
REPO = pathlib.Path(sys.argv[2])
FREEZE = pathlib.Path(sys.argv[3])
W = pathlib.Path(sys.argv[4])
if W.exists():
    shutil.rmtree(W)
W.mkdir(parents=True)

# The real generated specification, and the real refusal log.
BASE_SPEC = """callable:
  - library: 'package:dynamic_modules/n_host.dart'
  - library: 'dart:core'
    member: 'print'
"""
BASE_ATTEMPT = """m_ok.dart:5:7: Error: Cannot extend, implement or mix-in class 'Base' in a dynamic module.
m_ok.dart:7:10: Error: Cannot override member 'Base.execute' in a dynamic module.
m_ok.dart:6:4: Error: Cannot invoke member 'override' from a dynamic module.
m_ok.dart:7:17: Error: Cannot use class 'String' as a type in a dynamic module.
m_ok.dart:10:2: Error: Cannot invoke member 'pragma.' from a dynamic module.
m_ok.dart:11:14: Error: Cannot use class 'Object' as a type in a dynamic module.
produced=no
"""
COMPLETE_SPEC = BASE_SPEC + """extendable:
  - library: 'package:dynamic_modules/n_host.dart'
    class: 'Base'
can-be-overridden:
  - library: 'package:dynamic_modules/n_host.dart'
    class: 'Base'
    member: 'execute'
can-be-used-as-type:
  - library: 'dart:core'
    class: 'Object'
"""


def run(spec, attempt, repo=REPO, tool=TOOL):
    sp, at = W / 'spec.yaml', W / 'attempt.log'
    out = W / 'b0.json'
    if out.exists():
        out.unlink()
    sp.write_text(spec)
    at.write_text(attempt)
    subprocess.run([sys.executable, str(tool), str(sp), str(at), str(repo),
                    str(FREEZE), str(out)], capture_output=True, text=True)
    if not out.exists():
        return None
    try:
        return json.load(open(out))
    except Exception:                                        # noqa: BLE001
        return None


ARMS = [
 ('complete-spec-and-module-produced',
  COMPLETE_SPEC, BASE_ATTEMPT.replace('produced=no', 'produced=yes'),
  lambda d: d['b0_result'] == 'COMPLETE_SPECIFICATION_DERIVABLE'
  and d['sections_missing'] == [],
  'All four sections present AND the release specification validated the '
  'release patch. B0 must say derivable, or it stops #61 for no reason.'),

 ('complete-spec-but-module-still-refused',
  COMPLETE_SPEC, BASE_ATTEMPT,
  lambda d: d['b0_result'] == 'VALIDATION_INPUT_UNDERIVED',
  'Sections present is not enough: if the specification still refuses the '
  'release patch it is not a usable validation input.'),

 ('one-section-missing',
  COMPLETE_SPEC.replace("can-be-used-as-type:\n  - library: 'dart:core'\n    class: 'Object'\n", ''),
  BASE_ATTEMPT.replace('produced=no', 'produced=yes'),
  lambda d: (d['b0_result'] == 'VALIDATION_INPUT_UNDERIVED'
             and d['sections_missing'] == ['can-be-used-as-type']),
  'A single missing section must be named, not absorbed.'),

 ('spec-unreadable',
  None, BASE_ATTEMPT,
  lambda d: d['b0_result'] == 'B0_EVIDENCE_MISSING',
  'No specification to inspect is not the same as no specification being '
  'derivable, and must not be reported as the latter.'),

 ('attempt-log-unreadable',
  BASE_SPEC, None,
  lambda d: d['b0_result'] == 'B0_EVIDENCE_MISSING',
  'Without the validation attempt there is no measurement, so the verdict is '
  'unknown rather than underived.'),

 ('the-module-is-never-a-source',
  COMPLETE_SPEC, BASE_ATTEMPT.replace('produced=no', 'produced=yes'),
  lambda d: (d['candidate_sources']['the_module_itself']['usable'] is False
             and 'the_module_itself' not in d['usable_sources']),
  'Even when everything else succeeds, reading permissions off the patch must '
  'never count as a source: it would permit whatever the patch does.'),
]

print('ROUTE-B-DI-1 / B0 -- classifier falsification')
print(f'  {len(ARMS)} arms.\n')
base = run(BASE_SPEC, BASE_ATTEMPT)
if base is None:
    raise SystemExit('  baseline produced nothing')
print(f'  baseline: {base["b0_result"]}  missing={base["sections_missing"]}\n')
failed = []
for name, spec, attempt, check, why in ARMS:
    if spec is None:
        d = run('', attempt or '')
        # An empty file reads as a spec with no sections, which is a different
        # thing from an unreadable one, so point at a path that does not exist.
        out = W / 'b0.json'
        if out.exists():
            out.unlink()
        subprocess.run([sys.executable, str(TOOL), str(W / 'nope.yaml'),
                        str(W / 'attempt.log'), str(REPO), str(FREEZE),
                        str(out)], capture_output=True, text=True)
        d = json.load(open(out)) if out.exists() else None
    elif attempt is None:
        out = W / 'b0.json'
        if out.exists():
            out.unlink()
        (W / 'spec.yaml').write_text(spec)
        subprocess.run([sys.executable, str(TOOL), str(W / 'spec.yaml'),
                        str(W / 'nolog.log'), str(REPO), str(FREEZE),
                        str(out)], capture_output=True, text=True)
        d = json.load(open(out)) if out.exists() else None
    else:
        d = run(spec, attempt)
    ok = d is not None and bool(check(d))
    if not ok:
        failed.append(name)
    print(f'  {"pass" if ok else "FAIL"}  {name:38} -> '
          f'{d["b0_result"] if d else "NO-OUTPUT"}')
    print(f'        {why}')

print('\n  CONTROL -- a classifier hard-coding the baseline must fail the arms')
weak = W / 'weak.py'
weak.write_text(
    'import json,sys\n'
    "json.dump({'b0_result': 'VALIDATION_INPUT_UNDERIVED',\n"
    "  'sections_missing': ['extendable'], 'usable_sources': [],\n"
    "  'candidate_sources': {'the_module_itself': {'usable': False}}},\n"
    "  open(sys.argv[5],'w'))\n")
survivors = []
for name, spec, attempt, check, _why in ARMS:
    if spec is None or attempt is None:
        continue
    d = run(spec, attempt, tool=weak)
    try:
        if d is not None and check(d):
            survivors.append(name)
    except Exception:                                        # noqa: BLE001
        pass
print(f'    arms the weakened classifier still satisfies: {len(survivors)} '
      f'{survivors}')
# It legitimately satisfies the two arms whose expected result IS the baseline.
expected_survivors = {'complete-spec-but-module-still-refused',
                      'one-section-missing', 'the-module-is-never-a-source'}
unexpected = [s for s in survivors if s not in expected_survivors]
if unexpected:
    failed.append(f'weakened classifier satisfied {unexpected}')
    print(f'    FAIL  unexpected survivors: {unexpected}')
else:
    print('    pass  it satisfies only arms whose expectation IS the baseline')

print(f'\n  arms={len(ARMS)} failed={len(failed)}')
if failed:
    print(f'  FAILURES: {failed}')
print(f'B0_FALSIFICATION: '
      f'{"DEFECTS_PRESENT" if failed else "EVERY_ARM_DISCRIMINATES"}')
sys.exit(1 if failed else 0)
