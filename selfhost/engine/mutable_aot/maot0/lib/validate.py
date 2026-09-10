#!/usr/bin/env python3
"""MAOT-0 (#63) -- validate the matrix against the frozen universes and lock.

Produces a structured report. Raises no verdict of its own beyond findings;
the aggregate is contract.derive_aggregate's job, so there is exactly one
place a "100%" can be computed.

Every check here has a matching falsification arm in falsify_maot0.py. A
check that has never been seen to fail is not known to work.
"""

import hashlib
import json
import os

import contract as C


def canon(obj):
    return json.dumps(obj, sort_keys=True, separators=(',', ':'))


def digest(obj):
    return hashlib.sha256(canon(obj).encode('utf-8')).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b''):
            h.update(chunk)
    return h.hexdigest()


def _f(findings, code, severity, message, **extra):
    rec = {'code': code, 'severity': severity, 'message': message}
    rec.update(extra)
    findings.append(rec)


def load_universes(universe_dir):
    """Load the frozen universes and check the freeze is self-consistent."""
    findings, entries = [], {}
    files = ('kernel_declarations.json', 'vm_runtime_state.json')
    for name in files:
        path = os.path.join(universe_dir, name)
        if not os.path.isfile(path):
            _f(findings, 'UNIVERSE_FILE_MISSING', 'blocking',
               f'frozen universe {name} is absent; coverage cannot be checked',
               file=name)
            continue
        with open(path, encoding='utf-8') as fh:
            doc = json.load(fh)
        prov = doc.get('provenance', {})
        # Branches are not provenance and a dirty tree is not an identity.
        if not prov.get('dart_tree_head_is_full_sha'):
            _f(findings, 'UNIVERSE_PROVENANCE_INVALID', 'blocking',
               f'{name} does not record a full 40-hex Dart tree SHA',
               file=name, head=prov.get('dart_tree_head'))
        if prov.get('extracted_paths_dirty'):
            _f(findings, 'UNIVERSE_PROVENANCE_INVALID', 'blocking',
               f'{name} was extracted from a tree with uncommitted changes '
               'under the extracted paths; that is not a nameable revision',
               file=name, detail=prov.get('extracted_paths_dirty_detail'))
        if doc.get('duplicate_ids'):
            _f(findings, 'UNIVERSE_DUPLICATE_IDS', 'blocking',
               f'{name} contains duplicate ids',
               file=name, ids=doc['duplicate_ids'])
        if doc.get('total') != len(doc.get('entries', [])):
            _f(findings, 'UNIVERSE_TOTAL_MISMATCH', 'blocking',
               f'{name} total does not match its entry count', file=name)
        for e in doc.get('entries', []):
            entries[e['id']] = e
    return entries, findings


def validate(matrix, universe_entries, repo_root, lock=None):
    findings = []
    rows = matrix.get('rows', [])

    # ---------------------------------------------------------- vocabulary
    declared_boundaries = {b['id'] for b in matrix.get('boundaries', [])}
    declared_exclusion_classes = {
        x['id'] for x in matrix.get('exclusion_classes', [])}

    # ------------------------------------------------------------ row shape
    seen_ids, seen_gates = set(), {}
    for row in rows:
        rid = row.get('id')
        if not rid:
            _f(findings, 'ROW_SCHEMA_INVALID', 'blocking',
               'a row has no id', row=canon(row)[:200])
            continue
        if rid in seen_ids:
            _f(findings, 'ROW_ID_DUPLICATE', 'blocking',
               f'row id {rid} appears more than once', row=rid)
        seen_ids.add(rid)

        for field in ('title', 'group', 'expected_post_patch', 'coexistence',
                      'migration', 'subsystem', 'gate_id'):
            if not row.get(field):
                _f(findings, 'ROW_SCHEMA_INVALID', 'blocking',
                   f'{rid}: required field {field!r} is missing or empty',
                   row=rid, field=field)

        if row.get('group') not in C.GROUPS:
            _f(findings, 'ROW_SCHEMA_INVALID', 'blocking',
               f'{rid}: unknown group {row.get("group")!r}', row=rid)
        if row.get('coexistence') not in C.COEXISTENCE:
            _f(findings, 'ROW_SCHEMA_INVALID', 'blocking',
               f'{rid}: unknown coexistence {row.get("coexistence")!r}',
               row=rid)
        if row.get('migration') not in C.MIGRATION:
            _f(findings, 'ROW_SCHEMA_INVALID', 'blocking',
               f'{rid}: unknown migration {row.get("migration")!r}', row=rid)
        for sub in row.get('subsystem', []) or []:
            if sub not in C.SUBSYSTEMS:
                _f(findings, 'ROW_SCHEMA_INVALID', 'blocking',
                   f'{rid}: unknown subsystem {sub!r}', row=rid)

        # Sketches are what make "expected semantics" concrete rather than a
        # slogan. #64 builds the executable fixture at gate_id; the sketch is
        # what it must be built from.
        for field in ('release_sketch', 'patch_sketch'):
            if not row.get(field):
                _f(findings, 'ROW_SCHEMA_INVALID', 'blocking',
                   f'{rid}: required field {field!r} is missing or empty',
                   row=rid, field=field)

        gate = row.get('gate_id')
        if gate:
            if gate in seen_gates:
                _f(findings, 'GATE_ID_DUPLICATE', 'blocking',
                   f'{rid}: gate_id {gate} is already used by '
                   f'{seen_gates[gate]}; two rows sharing one gate means one '
                   'of them is never independently proven', row=rid)
            seen_gates[gate] = rid

        # ------------------------------------------------------------ axes
        declared = row.get('axes') or {}
        for axis, value in declared.items():
            if axis not in C.AXES:
                _f(findings, 'AXIS_UNKNOWN', 'blocking',
                   f'{rid}: unknown axis {axis!r}', row=rid)
            if value not in C.ALL_AXIS_VALUES:
                _f(findings, 'AXIS_VALUE_INVALID', 'blocking',
                   f'{rid}: axis {axis} has invalid value {value!r}', row=rid)
        for axis in C.AXES:
            if axis not in declared:
                _f(findings, 'AXIS_MISSING', 'blocking',
                   f'{rid}: axis {axis} is not declared; an absent axis must '
                   'never read as a satisfied one', row=rid, axis=axis)
        notes = row.get('axis_notes') or {}
        for axis, value in declared.items():
            if value == C.AXIS_NOT_APPLICABLE and not notes.get(axis):
                _f(findings, 'AXIS_NOT_APPLICABLE_UNJUSTIFIED', 'blocking',
                   f'{rid}: axis {axis} is NOT_APPLICABLE with no '
                   'justification; that is the cheapest way to make a hard '
                   'row look finished', row=rid, axis=axis)

        # ------------------------------------------------------- scope/ties
        if not row.get('in_scope', True):
            ref = row.get('boundary_ref')
            if not ref:
                _f(findings, 'OUT_OF_SCOPE_ROW_WITHOUT_BOUNDARY', 'blocking',
                   f'{rid}: out of scope with no boundary_ref; an exclusion '
                   'must name the boundary that excludes it', row=rid)
            elif ref not in declared_boundaries:
                _f(findings, 'BOUNDARY_REF_UNKNOWN', 'blocking',
                   f'{rid}: boundary_ref {ref!r} is not a declared boundary',
                   row=rid)

        # -------------------------------------------------- state/evidence
        state = C.derive_row_state(row)
        provable, reasons = C.row_is_provable(row)
        if state == 'PROVEN' and not provable:
            _f(findings, 'PROVEN_ROW_WITHOUT_EVIDENCE', 'blocking',
               f'{rid}: axes derive PROVEN but: ' + '; '.join(reasons),
               row=rid, reasons=reasons)
        if state == 'IMPLEMENTED' and not row.get('gate_id'):
            _f(findings, 'IMPLEMENTED_ROW_WITHOUT_GATE', 'blocking',
               f'{rid}: IMPLEMENTED with no executable gate id', row=rid)

        ev = row.get('evidence')
        if isinstance(ev, dict) and ev.get('path'):
            abs_path = os.path.join(repo_root, ev['path'])
            if not os.path.isfile(abs_path):
                _f(findings, 'EVIDENCE_FILE_MISSING', 'blocking',
                   f'{rid}: evidence path {ev["path"]} does not exist',
                   row=rid)
            elif ev.get('sha256') and sha256_file(abs_path) != ev['sha256']:
                _f(findings, 'EVIDENCE_DIGEST_MISMATCH', 'blocking',
                   f'{rid}: evidence at {ev["path"]} does not match its '
                   'recorded digest', row=rid)

    # ------------------------------------------------------------- coverage
    covered = {}
    for row in rows:
        for uid in row.get('covers', []) or []:
            if uid not in universe_entries:
                _f(findings, 'COVERS_UNKNOWN_UNIVERSE_ID', 'blocking',
                   f'{row.get("id")}: covers {uid!r}, which is not in any '
                   'frozen universe', row=row.get('id'), universe_id=uid)
            covered.setdefault(uid, []).append(row.get('id'))

    blanket_tiers = {}
    for row in rows:
        for tier in row.get('covers_tiers', []) or []:
            if C.TIER_COVERAGE.get(tier) != 'blanket':
                _f(findings, 'TIER_BLANKET_NOT_PERMITTED', 'blocking',
                   f'{row.get("id")}: claims blanket coverage of tier '
                   f'{tier!r}, which the contract requires be covered '
                   'per row', row=row.get('id'), tier=tier)
            blanket_tiers.setdefault(tier, []).append(row.get('id'))

    excluded = {}
    for x in matrix.get('universe_exclusions', []) or []:
        uid, cls = x.get('universe_id'), x.get('class')
        if uid not in universe_entries:
            _f(findings, 'EXCLUSION_UNKNOWN_UNIVERSE_ID', 'blocking',
               f'exclusion names {uid!r}, which is not in any frozen '
               'universe', universe_id=uid)
        if cls not in declared_exclusion_classes:
            _f(findings, 'EXCLUSION_CLASS_UNKNOWN', 'blocking',
               f'exclusion of {uid!r} uses undeclared class {cls!r}',
               universe_id=uid)
        if not x.get('note'):
            _f(findings, 'EXCLUSION_UNJUSTIFIED', 'blocking',
               f'exclusion of {uid!r} carries no note', universe_id=uid)
        excluded[uid] = cls

    uncovered = []
    for uid, entry in sorted(universe_entries.items()):
        tier = entry['tier']
        if uid in covered or uid in excluded:
            continue
        if C.TIER_COVERAGE.get(tier) == 'blanket' and tier in blanket_tiers:
            continue
        uncovered.append({'universe_id': uid, 'tier': tier,
                          'name': entry.get('name'),
                          'source': entry.get('source')})
    for u in uncovered:
        _f(findings, 'UNIVERSE_ENTRY_UNCOVERED', 'blocking',
           f'{u["universe_id"]} ({u["tier"]}) is named by no row, no blanket '
           'and no exclusion', **u)

    for tier, policy in C.TIER_COVERAGE.items():
        present = any(e['tier'] == tier for e in universe_entries.values())
        if policy == 'blanket' and present and tier not in blanket_tiers:
            _f(findings, 'TIER_BLANKET_UNDECLARED', 'blocking',
               f'tier {tier!r} is covered by blanket policy but no row '
               'declares it', tier=tier)

    # ----------------------------------------------------------------- lock
    lock_report = check_lock(rows, lock, findings)

    return {
        'findings': findings,
        'coverage': {
            'universe_total': len(universe_entries),
            'covered_by_row': len(covered),
            'covered_by_exclusion': len(excluded),
            'blanket_tiers': {t: sorted(set(v))
                              for t, v in sorted(blanket_tiers.items())},
            'uncovered': uncovered,
        },
        'lock': lock_report,
    }


def compute_lock(rows):
    projections = {r['id']: C.row_lock_projection(r)
                   for r in rows if r.get('id')}
    return {
        'schema': 'maot0.lock/1',
        'rows': {rid: digest(p) for rid, p in sorted(projections.items())},
        'set_digest': digest(sorted(projections)),
        'purpose': (
            'Detects a row moving toward supported without that move being an '
            'explicit reviewed act. Advanced only by run_maot0.sh '
            '--accept-lock, which refuses while any blocking finding stands.'),
    }


def check_lock(rows, lock, findings):
    current = compute_lock(rows)
    if lock is None:
        _f(findings, 'LOCK_MISSING', 'blocking',
           'no matrix.lock.json; without it a row state can move with no '
           'trace')
        return {'status': 'missing', 'current_set_digest': current['set_digest']}

    drift = []
    locked_rows = lock.get('rows', {})
    by_id = {r['id']: r for r in rows if r.get('id')}

    for rid, row_digest in current['rows'].items():
        if rid not in locked_rows:
            _f(findings, 'LOCK_ROW_ADDED', 'blocking',
               f'{rid} is in the matrix but not in the lock', row=rid)
            drift.append({'row': rid, 'kind': 'added'})
        elif locked_rows[rid] != row_digest:
            row = by_id.get(rid, {})
            _f(findings, 'LOCK_ROW_STATE_DRIFT', 'blocking',
               f'{rid}: axis states, scope, gate or evidence changed without '
               'the lock being advanced', row=rid,
               derived_state=C.derive_row_state(row))
            drift.append({'row': rid, 'kind': 'drift',
                          'derived_state': C.derive_row_state(row)})
    for rid in locked_rows:
        if rid not in current['rows']:
            _f(findings, 'LOCK_ROW_REMOVED', 'blocking',
               f'{rid} is locked but absent from the matrix; a required row '
               'cannot be retired by deletion', row=rid)
            drift.append({'row': rid, 'kind': 'removed'})

    return {
        'status': 'clean' if not drift else 'drift',
        'drift': drift,
        'locked_rows': len(locked_rows),
        'current_set_digest': current['set_digest'],
        'locked_set_digest': lock.get('set_digest'),
    }
