#!/usr/bin/env python3
"""Provenance manifest, derived from what the assembler actually consumed.

#58 requires a digest for every input. The input set here comes from the
extractor's ACCESS LOG -- the files it really opened, digested at read time --
not from a hand-maintained parallel list, which would be free to drift from the
rows. It is cross-checked against the registry: any file a row names but the
extractor never opened, or opened but no row names, is a finding.

NO SELF-HASHING. The manifest cannot contain its own digest, and it does not
digest RESULT.md, because both are outputs of this assembly. A manifest that
hashed itself would never converge -- that already happened once in G5, where a
final manifest included its own output and a second run never reproduced the
first. Outputs are listed by name with a note, inputs are digested.

usage: build_manifest.py <semantic-map-dir> <registry> <matrix.json> \
                         <verdict.json> <final-dir> <out.json>
"""
import collections
import datetime
import hashlib
import json
import pathlib
import sys

SM = pathlib.Path(sys.argv[1]).resolve()
REGISTRY = pathlib.Path(sys.argv[2]).resolve()
MATRIX = pathlib.Path(sys.argv[3]).resolve()
VERDICT = pathlib.Path(sys.argv[4]).resolve()
FINAL = pathlib.Path(sys.argv[5]).resolve()
OUT = sys.argv[6]

# Outputs of THIS assembly. Never digested here: they do not exist yet, or
# they are what this manifest describes.
OUTPUTS = {'evidence/final_matrix.json', 'evidence/final_verdict.json',
           'evidence/provenance_manifest.json', 'evidence/final_assembly.txt',
           'RESULT.md'}


def sha(p):
    return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()


matrix = json.loads(MATRIX.read_bytes())
verdict = json.loads(VERDICT.read_bytes())
reg = json.loads(REGISTRY.read_bytes())

# ---- the consumed evidence, from the access log -------------------------
consumed = collections.OrderedDict()
for rel, rec in matrix['access_log'].items():
    consumed[rel] = collections.OrderedDict([
        ('sha256', rec['sha256']), ('bytes', rec['bytes']),
        ('read', rec['read']),
        ('rows', sorted(name for name, r in matrix['matrix'].items()
                        if rel in r.get('evidence_files', []))),
    ])

declared = sorted({s['file'] for row in reg['rows']
                   for s in row['probes'].values()})
opened = sorted(consumed)
findings = []
for f in declared:
    if f not in consumed:
        findings.append(f'declared by a row but never opened: {f}')
for f in opened:
    if f not in declared and not consumed[f]['rows']:
        findings.append(f'opened but no row declares it: {f}')
for f, rec in consumed.items():
    if not rec['read']:
        findings.append(f'unreadable: {f}')
    elif not rec['rows']:
        findings.append(f'digested but attributed to no row: {f}')

# ---- the tools that produced the evidence and the assembly -------------
# Derived: the gate directory comes from each consumed path, so a new gate
# contributes its scripts without this list being edited.
gates = sorted({rel.split('/', 1)[0] for rel in consumed})
producers = collections.OrderedDict()
for g in gates:
    for script in sorted((SM / g).glob('*.sh')):
        producers[f'{g}/{script.name}'] = sha(script)
    for script in sorted((SM / g / 'lib').glob('*.py')) if (SM / g / 'lib').is_dir() else []:
        producers[f'{g}/lib/{script.name}'] = sha(script)

assembler = collections.OrderedDict()
assembler['final/evidence_registry.json'] = sha(REGISTRY)
for script in sorted((FINAL / 'lib').glob('*.py')):
    assembler[f'final/lib/{script.name}'] = sha(script)
for script in sorted(FINAL.glob('*.sh')):
    assembler[f'final/{script.name}'] = sha(script)

doc = collections.OrderedDict([
    ('schema', 'semantic-map-1/final-provenance/1'),
    ('gate', 'SM1-FINAL'), ('issue', 58), ('tracker', 48),
    ('generated', datetime.datetime.now(datetime.timezone.utc)
     .strftime('%Y-%m-%dT%H:%M:%SZ')),
    ('input_set_derived_from',
     'the extractor access log, cross-checked against the registry'),
    ('self_hashing',
     'none: this manifest, RESULT.md, the matrix and the verdict are OUTPUTS '
     'of this assembly and are listed by name only. A manifest that digested '
     'itself would never converge -- G5 hit exactly that and a second run '
     'never reproduced the first.'),
    ('outputs_not_digested', sorted(OUTPUTS)),
    ('verdict', verdict['verdict']),
    ('matrix_rows', len(matrix['matrix'])),
    ('consumed_evidence', consumed),
    ('consumed_count', len(consumed)),
    ('producing_scripts', producers),
    ('assembler', assembler),
    ('coverage', collections.OrderedDict([
        ('declared_by_rows', len(declared)),
        ('opened_by_extractor', len(opened)),
        ('equal', declared == opened),
    ])),
    ('findings', findings),
])
json.dump(doc, open(OUT, 'w'), indent=2)

w = sys.stdout.write
w(f'  consumed evidence files : {len(consumed)}\n')
w(f'  declared by rows        : {len(declared)}\n')
w(f'  sets equal              : {declared == opened}\n')
w(f'  producing scripts       : {len(producers)}\n')
w(f'  assembler components    : {len(assembler)}\n')
w(f'  findings                : {findings if findings else "none"}\n')
missing = [f for f, r in consumed.items() if not r['sha256']]
w(f'  inputs without a digest : {missing if missing else "none"}\n')
sys.exit(1 if findings or missing else 0)
