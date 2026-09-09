#!/usr/bin/env python3
"""Generate the SOURCE evidence record for the dynamic-interface mechanism.

WHY THIS EXISTS. FINAL published five source-level routing facts -- that
dart2bytecode already has --validate, that it assigns
dynamicInterfaceSpecificationUri, that validation is conditional on that URI,
and that Route B's two build scripts omit the flag -- as hard-coded note and
routing PROSE. The facts were correct, and that is not the point: a material
routing conclusion sitting outside the extracted, digested evidence graph
violates #58's central rule. Prose cannot be falsified by Family A, cannot be
digested by the provenance manifest, and cannot degrade to NOT_ESTABLISHED
when its evidence disappears.

So the facts are produced here, into a record the extractor consumes like any
other evidence.

IT READS THE FROZEN SOURCE, NOT THE WORKING COPY. Every Dart file is read as
`git show <effective_tree>:<path>`, so the facts are about the tree that
actually built the cell -- the one now published durably -- and each carries
its git blob id as well as a content digest. A working-copy read would make
these facts about whatever happens to be checked out.

Route B's scripts are read from the repository working tree, because they are
this repo's own product surface and #58 must not change them.

usage: probe_source_facts.py <dart-git-dir> <repo-root> <freeze-manifest> <out>
"""
import datetime
import hashlib
import json
import pathlib
import re
import subprocess
import sys

DART = pathlib.Path(sys.argv[1])
REPO = pathlib.Path(sys.argv[2])
FREEZE = pathlib.Path(sys.argv[3])
OUT = sys.argv[4]

notes = []


def frozen_blob(tree, rel):
    """Content of one path in a frozen tree, plus its git blob id."""
    try:
        raw = subprocess.run(['git', '-C', str(DART), 'show', f'{tree}:{rel}'],
                             capture_output=True, check=True).stdout
        bid = subprocess.run(['git', '-C', str(DART), 'rev-parse',
                              f'{tree}:{rel}'],
                             capture_output=True, text=True,
                             check=True).stdout.strip()
        return raw, bid
    except Exception as ex:                                  # noqa: BLE001
        notes.append(f'{tree[:12]}:{rel} unreadable -- {type(ex).__name__}')
        return None, None


def local_file(rel):
    try:
        return (REPO / rel).read_bytes()
    except Exception as ex:                                  # noqa: BLE001
        notes.append(f'{rel} unreadable -- {type(ex).__name__}')
        return None


try:
    fz = json.loads(FREEZE.read_bytes())['producing_source']['dart']
    REV, EFF, BASE = fz['revision'], fz['effective_tree'], fz['deps_pinned_base']
except Exception as ex:                                      # noqa: BLE001
    print(f'freeze manifest unreadable: {type(ex).__name__}')
    raise SystemExit(1)

D2B = 'pkg/dart2bytecode/lib/dart2bytecode.dart'
KT = 'pkg/front_end/lib/src/kernel/kernel_target.dart'
RB4A = 'selfhost/engine/route_b/build_4a_payload.sh'
RB4B = 'selfhost/engine/route_b/build_4b_artifact.sh'

files = {}


def record(key, raw, blob_id, origin):
    if raw is None:
        files[key] = {'read': False, 'origin': origin}
        return None
    files[key] = {'read': True, 'origin': origin,
                  'sha256': hashlib.sha256(raw).hexdigest(),
                  'git_blob': blob_id, 'bytes': len(raw)}
    return raw.decode('utf-8', 'replace')


d2b_eff = record(f'effective_tree:{D2B}', *frozen_blob(EFF, D2B),
                 origin=f'git show {EFF[:12]}:{D2B}')
kt_eff = record(f'effective_tree:{KT}', *frozen_blob(EFF, KT),
                origin=f'git show {EFF[:12]}:{KT}')
d2b_base = record(f'deps_pinned_base:{D2B}', *frozen_blob(BASE, D2B),
                  origin=f'git show {BASE[:12]}:{D2B}')
rb4a = record(f'worktree:{RB4A}', local_file(RB4A), None,
              origin='repository working tree')
rb4b = record(f'worktree:{RB4B}', local_file(RB4B), None,
              origin='repository working tree')

facts = {}


def fact(fid, body, where, pattern, expect, means, flags=re.MULTILINE):
    """Record one fact. Unreadable source -> value None, never a default."""
    if body is None:
        facts[fid] = {'value': None, 'where': where, 'pattern': pattern,
                      'matches': None, 'expect_present': expect,
                      'means': means,
                      'unresolved': 'source unreadable'}
        return
    ms = list(re.finditer(pattern, body, flags))
    line = body[:ms[0].start()].count('\n') + 1 if ms else None
    facts[fid] = {'value': (len(ms) > 0) == expect,
                  'where': where, 'pattern': pattern,
                  'matches': len(ms),
                  'first_line': line,
                  'expect_present': expect, 'means': means}


fact('D2B_REGISTERS_VALIDATE_OPTION', d2b_eff, f'effective_tree:{D2B}',
     r"\.\.addOption\(\s*\n?\s*'validate',", True,
     "dart2bytecode registers a --validate option. SL1-G6C's premise that it "
     'has no such option does not hold against this tree.')
fact('D2B_ASSIGNS_DYNAMIC_INTERFACE_URI', d2b_eff, f'effective_tree:{D2B}',
     r'\.\.dynamicInterfaceSpecificationUri\s*=\s*'
     r'dynamicInterfaceSpecificationUri', True,
     'the option reaches the CFE options object. This is a SOURCE fact and is '
     'not evidence that validation then rejects anything.')
fact('VALIDATION_IS_CONDITIONAL_ON_URI', kt_eff, f'effective_tree:{KT}',
     r'Future<void> validateDynamicModule\(\) async \{\s*\n'
     r'\s*final Uri\? dynamicInterfaceSpecificationUri =\s*\n'
     r'\s*_options\.dynamicInterfaceSpecificationUri;\s*\n'
     r'\s*if \(dynamicInterfaceSpecificationUri != null\) \{', True,
     'validateDynamicModule early-returns unless the URI is set, so without '
     'the flag no validation runs. This is what SL1 got right.')
fact('OPTION_PREDATES_THE_FORK', d2b_base, f'deps_pinned_base:{D2B}',
     r"\.\.addOption\(\s*\n?\s*'validate',", True,
     'the option is present in the DEPS-pinned upstream base, so it is '
     'upstream and not something this fork added.')
fact('ROUTE_B_4A_OMITS_VALIDATE', rb4a, f'worktree:{RB4A}',
     r'dart2bytecode\.dart(?:(?!\n\n)[\s\S])*?--validate', False,
     "Route B's payload build invokes dart2bytecode without --validate.")
fact('ROUTE_B_4B_OMITS_VALIDATE', rb4b, f'worktree:{RB4B}',
     r'dart2bytecode\.dart(?:(?!\n\n)[\s\S])*?--validate', False,
     "Route B's artifact build invokes dart2bytecode without --validate.")
# The omission checks must not pass merely because the invocation is absent.
fact('ROUTE_B_4A_INVOKES_DART2BYTECODE', rb4a, f'worktree:{RB4A}',
     r'dart2bytecode\.dart', True,
     'the invocation exists, so its lack of --validate is an omission rather '
     'than an absent call site.')
fact('ROUTE_B_4B_INVOKES_DART2BYTECODE', rb4b, f'worktree:{RB4B}',
     r'dart2bytecode\.dart', True,
     'the invocation exists, so its lack of --validate is an omission rather '
     'than an absent call site.')

resolved = [k for k, v in facts.items() if v['value'] is True]
refuted = [k for k, v in facts.items() if v['value'] is False]
unresolved = [k for k, v in facts.items() if v['value'] is None]

doc = {
    'schema': 'semantic-map-1/final-source-facts/1',
    'gate': 'SM1-FINAL', 'issue': 58,
    'generated': datetime.datetime.now(datetime.timezone.utc)
                 .strftime('%Y-%m-%dT%H:%M:%SZ'),
    'why': 'Source-level routing facts, produced as evidence rather than '
           'written as prose, so the provenance manifest digests them, '
           "Family A can falsify them, and losing them degrades the row to "
           'NOT_ESTABLISHED instead of leaving a claim standing.',
    'source_identity': {'dart_revision': REV, 'effective_tree': EFF,
                        'deps_pinned_base': BASE,
                        'dart_git_dir': str(DART)},
    'reads_frozen_tree_not_worktree': True,
    'files': files,
    'facts': facts,
    'summary': {'resolved': resolved, 'refuted': refuted,
                'unresolved': unresolved},
    'notes': notes,
    'does_not_claim':
        'That passing --validate makes the DYNAMIC_INTERFACE_POLICY negatives '
        'fail closed. Every fact here is about source text; none is a '
        'behavioural result.',
}
json.dump(doc, open(OUT, 'w'), indent=2)

w = sys.stdout.write
for k, v in facts.items():
    state = {True: 'holds', False: 'REFUTED', None: 'UNRESOLVED'}[v['value']]
    loc = f"{v['where']}:{v['first_line']}" if v.get('first_line') else v['where']
    w(f'  {state:10} {k}\n             {loc}  ({v["matches"]} match(es), '
      f'expect_present={v["expect_present"]})\n')
w(f'\n  resolved={len(resolved)} refuted={len(refuted)} '
  f'unresolved={len(unresolved)}\n')
if notes:
    w(f'  notes: {notes}\n')
sys.exit(0 if not unresolved and not refuted else 1)
