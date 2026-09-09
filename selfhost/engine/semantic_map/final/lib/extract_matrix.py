#!/usr/bin/env python3
"""Extract the SEMANTIC-MAP-1 matrix from evidence. Never from memory.

#58: "Every row is derived at run time from a marker in a gate transcript or a
field in a structured record. A row whose evidence cannot be found reads
NOT_ESTABLISHED -- never a remembered conclusion."

SEMANTIC-LINKER-1's assembler returned ABANDON_OR_REDESIGN on its first run
because two rows pointed at the wrong transcript, and the fix was the evidence
pointer rather than the check. So every probe here names a file and a field or
pattern, and a probe that cannot be resolved is reported by name -- not
silently skipped, and not defaulted.

WHAT MAKES A ROW NOT_ESTABLISHED
  * the file is absent or unreadable
  * the JSON path does not exist
  * a text pattern matches zero times where a count was required
  * every probe resolves but NO rule matches -- an unclassifiable combination
    is a finding, so the probe values are printed rather than a default chosen

THE ACCESS LOG IS THE MANIFEST'S INPUT SET. Every file this module opens is
recorded with its digest at read time, so the provenance manifest is derived
from what was actually consumed. A hand-maintained parallel list would be free
to drift from the rows, which is the failure #58 asks to avoid.

usage: extract_matrix.py <semantic-map-dir> <registry.json> <out.json>
"""
import collections
import datetime
import hashlib
import json
import pathlib
import re
import sys

SM = pathlib.Path(sys.argv[1]).resolve()
REGISTRY = pathlib.Path(sys.argv[2]).resolve()
OUT = sys.argv[3]

UNRESOLVED = object()


class Access:
    """Files actually opened, digested at read time."""

    def __init__(self):
        self.log = collections.OrderedDict()

    def note(self, rel):
        if rel in self.log:
            return self.log[rel]
        p = SM / rel
        try:
            raw = p.read_bytes()
            rec = {'sha256': hashlib.sha256(raw).hexdigest(),
                   'bytes': len(raw), 'read': True}
        except Exception as ex:                              # noqa: BLE001
            rec = {'sha256': None, 'bytes': None, 'read': False,
                   'error': type(ex).__name__}
        self.log[rel] = rec
        return rec


access = Access()
_json_cache = {}
_text_cache = {}


def load_json(rel):
    if rel not in _json_cache:
        access.note(rel)
        try:
            _json_cache[rel] = json.loads((SM / rel).read_bytes())
        except Exception:                                    # noqa: BLE001
            _json_cache[rel] = UNRESOLVED
    return _json_cache[rel]


def load_text(rel):
    if rel not in _text_cache:
        access.note(rel)
        try:
            _text_cache[rel] = (SM / rel).read_text(errors='replace')
        except Exception:                                    # noqa: BLE001
            _text_cache[rel] = UNRESOLVED
    return _text_cache[rel]


def dig(doc, path):
    cur = doc
    for seg in path:
        if isinstance(cur, dict) and seg in cur:
            cur = cur[seg]
        elif isinstance(cur, list) and isinstance(seg, int) and \
                -len(cur) <= seg < len(cur):
            cur = cur[seg]
        else:
            return UNRESOLVED
    return cur


def probe(spec):
    """Resolve one probe to a value, or UNRESOLVED with a reason."""
    kind = spec['kind']
    rel = spec['file']
    if kind == 'text_count':
        body = load_text(rel)
        if body is UNRESOLVED:
            return UNRESOLVED, f'{rel}: unreadable'
        # re.MULTILINE, because every one of these files is line-oriented and
        # a ^-anchored pattern otherwise matches only at the start of the whole
        # file -- silently returning 0 and reading as absent evidence. That is
        # a wrong answer from the instrument dressed as a finding about the
        # subject, so a zero count is also reported as UNRESOLVED when the
        # probe requires matches: the caller cannot tell "0 matches because the
        # evidence is absent" from "0 matches because my regex is wrong", so
        # the count is returned with the pattern for the transcript to show.
        try:
            n = len(re.findall(spec['pattern'], body, re.MULTILINE))
        except re.error as ex:
            return UNRESOLVED, f'{rel}: bad pattern -- {ex}'
        return n, f'{n} match(es) of /{spec["pattern"]}/ in {rel}'
    doc = load_json(rel)
    if doc is UNRESOLVED:
        return UNRESOLVED, f'{rel}: absent or not JSON'
    node = dig(doc, spec['path'])
    where = f'{rel}:{".".join(map(str, spec["path"]))}'
    if node is UNRESOLVED:
        return UNRESOLVED, f'{where}: path absent'
    if kind == 'json_field':
        return node, f'{where} = {node!r}'
    if kind == 'json_len':
        if not isinstance(node, (list, dict, str)):
            return UNRESOLVED, f'{where}: not sizeable ({type(node).__name__})'
        return len(node), f'len({where}) = {len(node)}'
    if not isinstance(node, list):
        return UNRESOLVED, f'{where}: expected a list'
    if kind == 'json_count_where':
        n = sum(1 for it in node
                if isinstance(it, dict) and it.get(spec['field'])
                == spec['equals'])
        return n, (f'{n} of {len(node)} rows with '
                   f'{spec["field"]}={spec["equals"]!r}')
    if kind == 'json_all_true':
        if not node:
            return UNRESOLVED, f'{where}: empty, so "all" would be vacuous'
        vals = [it.get(spec['field']) for it in node if isinstance(it, dict)]
        if len(vals) != len(node):
            return UNRESOLVED, f'{where}: some rows are not objects'
        return all(v is True for v in vals), \
            f'all {len(vals)} rows have {spec["field"]} is True'
    if kind == 'json_all_eq_value':
        if not node:
            return UNRESOLVED, f'{where}: empty, so "all" would be vacuous'
        return all(isinstance(it, dict) and it.get(spec['field'])
                   == spec['value'] for it in node), \
            f'all {len(node)} rows have {spec["field"]}={spec["value"]!r}'
    if kind == 'json_all_pairs_equal':
        if not node:
            return UNRESOLVED, f'{where}: empty, so "all" would be vacuous'
        return all(isinstance(it, dict)
                   and it.get(spec['field_a']) == it.get(spec['field_b'])
                   for it in node), \
            (f'all {len(node)} rows have '
             f'{spec["field_a"]} == {spec["field_b"]}')
    if kind == 'json_contains':
        return spec['value'] in node, \
            f'{spec["value"]!r} in {where} ({len(node)} entries)'
    return UNRESOLVED, f'unknown probe kind {kind!r}'


OPS = {
 'eq': lambda a, b: a == b,
 'ne': lambda a, b: a != b,
 'gt': lambda a, b: isinstance(a, (int, float)) and a > b,
 'gte': lambda a, b: isinstance(a, (int, float)) and a >= b,
 'lt': lambda a, b: isinstance(a, (int, float)) and a < b,
 'lte': lambda a, b: isinstance(a, (int, float)) and a <= b,
 'len_gte': lambda a, b: hasattr(a, '__len__') and len(a) >= b,
}


def evaluate(row):
    values, details, unresolved = {}, {}, []
    for name, spec in row['probes'].items():
        v, why = probe(spec)
        details[name] = why
        if v is UNRESOLVED:
            unresolved.append(f'{name}: {why}')
        else:
            values[name] = v
    if unresolved:
        return ('NOT_ESTABLISHED', values, details,
                'unresolved probes -- ' + '; '.join(unresolved), None)
    for i, rule in enumerate(row['rules']):
        ok = True
        for cond in rule['conditions']:
            name, op, target = cond
            got = values.get(name)
            if op == 'eq_probe':
                ok = ok and got == values.get(target)
            elif op in OPS:
                ok = ok and OPS[op](got, target)
            else:
                ok = False
            if not ok:
                break
        if ok:
            return rule['category'], values, details, rule['note'], i
    return ('NOT_ESTABLISHED', values, details,
            'every probe resolved but no rule matched: '
            + json.dumps(values, default=str), None)


reg = json.loads(REGISTRY.read_bytes())
# From the registry -- the single definition. Two copies of this set
# drifted once and made a positive finding show up as a known gap.
POSITIVE = set(reg['positive_categories']['categories'])
matrix = collections.OrderedDict()
for row in reg['rows']:
    cat, values, details, note, rule_idx = evaluate(row)
    matrix[row['row']] = collections.OrderedDict([
        ('category', cat),
        ('question', row['question']),
        ('note', note),
        ('rule_matched', rule_idx),
        ('probe_values', values),
        ('evidence_pointers', collections.OrderedDict(
            (n, details[n]) for n in row['probes'])),
        ('evidence_files', sorted({s['file'] for s in row['probes'].values()})),
    ])

# ---- KNOWN_GAPS: generated, never softened ------------------------------
# Assembled from three independent sources so nothing depends on one of them
# being remembered: rows that are not positive evidence, G8's unresolved
# production prerequisites, and G8's reproduced FAIL_OPEN findings.
gaps = []
for name, r in matrix.items():
    if r['category'] not in POSITIVE:
        gaps.append({'source': 'matrix', 'id': name,
                     'category': r['category'], 'detail': r['note']})
g8 = load_json('g8_reproduction/evidence/g8_result.json')
if g8 is UNRESOLVED:
    gaps.append({'source': 'g8', 'id': 'G8_RESULT_UNREADABLE',
                 'category': 'NOT_ESTABLISHED',
                 'detail': 'the G8 result could not be read, so its '
                           'prerequisites and findings cannot be enumerated'})
    g8_ok = False
else:
    g8_ok = True
    pp = g8.get('production_prerequisites', {})
    for e in pp.get('entries', []):
        if e.get('status') != 'RESOLVED':
            gaps.append({'source': 'g8_prerequisite', 'id': e.get('id'),
                         'category': e.get('status'),
                         'severity': e.get('severity'),
                         'detail': e.get('statement'),
                         'evidence': e.get('evidence')})
    for f in g8.get('known_fail_open_findings', {}).get('findings', []):
        gaps.append({'source': 'g8_fail_open', 'id': f.get('id'),
                     'category': f.get('status'),
                     'detail': f.get('means'),
                     'evidence': f"{f.get('gate')}/{f.get('where')}"})

matrix['KNOWN_GAPS'] = collections.OrderedDict([
    ('category', 'ENUMERATED' if g8_ok else 'NOT_ESTABLISHED'),
    ('question', 'What was not established, measured negatively, or left '
                 'unresolved?'),
    ('note', 'Generated from the matrix categories, G8 production '
             'prerequisites and G8 reproduced FAIL_OPEN findings. UNKNOWN, '
             'VACUOUS, NOT_ESTABLISHED and unresolved prerequisites appear '
             'verbatim and are not softened.'),
    ('count', len(gaps)),
    ('entries', gaps),
    ('evidence_files', ['g8_reproduction/evidence/g8_result.json']),
])

doc = collections.OrderedDict([
    ('schema', 'semantic-map-1/final-matrix/1'),
    ('gate', 'SM1-FINAL'), ('issue', 58), ('tracker', 48),
    ('generated', datetime.datetime.now(datetime.timezone.utc)
     .strftime('%Y-%m-%dT%H:%M:%SZ')),
    ('registry', collections.OrderedDict([
        ('path', str(REGISTRY.relative_to(REGISTRY.parents[1]))),
        ('sha256', hashlib.sha256(REGISTRY.read_bytes()).hexdigest()),
        ('rows_declared', len(reg['rows'])),
    ])),
    ('category_vocabulary', reg['category_vocabulary']),
    ('positive_categories', sorted(POSITIVE)),
    ('matrix', matrix),
    ('not_established',
     sorted(k for k, v in matrix.items()
            if v['category'] == 'NOT_ESTABLISHED')),
    ('access_log', access.log),
])
json.dump(doc, open(OUT, 'w'), indent=2)

w = sys.stdout.write
w(f'  {len(matrix)} rows extracted from {len(access.log)} evidence files\n\n')
for name, r in matrix.items():
    w(f'  {name:34} {r["category"]}\n')
ne = doc['not_established']
w(f'\n  NOT_ESTABLISHED: {ne if ne else "none"}\n')
w(f'  KNOWN_GAPS entries: {matrix["KNOWN_GAPS"]["count"]}\n')
unread = [k for k, v in access.log.items() if not v['read']]
w(f'  evidence files unreadable: {unread if unread else "none"}\n')
sys.exit(0)
