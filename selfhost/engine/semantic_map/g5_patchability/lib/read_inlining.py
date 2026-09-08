#!/usr/bin/env python3
"""read_inlining.py -- SM1-G5 route 2 reader.

Projects the compiler-emitted inlining relation onto SM1-G1 declaration
identity and assigns every G2 candidate exactly one state:

    INLINED       the declared function itself appears as an inlinee
    NOT_INLINED   it does not, and the note is trusted to be complete
    UNKNOWN       anything else

A MISSING ROW IS NEVER SAFE. Absence only yields NOT_INLINED when the note
validated completely; if validation fails, every candidate is UNKNOWN, because
"the note did not say" cannot be allowed to read as "not inlined".

WHAT THIS READER REFUSES TO DO
  * parse operator symbols to recover a kind -- the VM's RegularFunction is
    disambiguated against G1's authoritative inventory instead;
  * strip a private key with a regex like @\\d+$ -- only the declaring
    library's exact private key is removed, and a mismatch is UNKNOWN;
  * apply the VM's ScrubName, which also rewrites get:/set: and so does not
    equal G1's vmName contract;
  * resolve a >1-candidate projection by preference. Ambiguity is UNKNOWN.
"""
import hashlib
import json
import struct
import sys

NOTE = '.note.shorebird.inlining'
OWNER = b'Shorebird\x00'
NOTE_TYPE = 2
SCHEMA = 5
FIELDS = 16
SHT_NOTE = 7


class NoteError(Exception):
    """Validation failed. Every candidate becomes UNKNOWN."""


def read_note(path):
    """Return (records, diagnostics). Raises NoteError on any validation failure.

    Identity is the whole section header plus the note header: name, sh_type,
    owner, note type, schema and uniqueness are all checked, because a section
    name is not a signature.
    """
    b = open(path, 'rb').read()
    diag = {'aot_sha256': hashlib.sha256(b).hexdigest()}
    if len(b) < 64 or b[:4] != b'\x7fELF':
        raise NoteError('not an ELF file')
    if b[4] != 2:
        raise NoteError('not ELF64; this reader does not model ELF32')

    def u16(o): return struct.unpack_from('<H', b, o)[0]
    def u32(o): return struct.unpack_from('<I', b, o)[0]
    def u64(o): return struct.unpack_from('<Q', b, o)[0]

    shoff, shentsize, shnum, shstrndx = u64(0x28), u16(0x3a), u16(0x3c), u16(0x3e)
    if shoff == 0 or shnum == 0:
        raise NoteError('no section table')
    stroff = u64(shoff + shstrndx * shentsize + 0x18)

    def name_at(idx):
        s = stroff + idx
        e = b.index(b'\x00', s)
        return b[s:e].decode()

    hits = [shoff + i * shentsize for i in range(shnum)
            if name_at(u32(shoff + i * shentsize)) == NOTE]
    if not hits:
        raise NoteError(f'no {NOTE} section')
    if len(hits) > 1:
        raise NoteError(f'{len(hits)} sections named {NOTE}; a duplicate or '
                        f'conflicting note cannot establish anything')
    hdr = hits[0]
    if u32(hdr + 0x04) != SHT_NOTE:
        raise NoteError(f'sh_type={u32(hdr + 0x04)}, expected SHT_NOTE')
    off, size = u64(hdr + 0x18), u64(hdr + 0x20)
    diag['note_section_sha256'] = hashlib.sha256(b[off:off + size]).hexdigest()
    if size < 12:
        raise NoteError(f'note section is {size} bytes, too short for a header')
    nsz, dsz, ntype = u32(off), u32(off + 4), u32(off + 8)
    if ntype != NOTE_TYPE:
        raise NoteError(f'note type={ntype}, expected {NOTE_TYPE}')
    if nsz != len(OWNER) or b[off + 12:off + 12 + nsz] != OWNER:
        got = b[off + 12:off + 12 + nsz]
        raise NoteError(f'owner is {got!r} (name_size={nsz}), expected '
                        f'{OWNER!r} ({len(OWNER)})')
    # The producer writes name and description contiguously, as GenerateBuildId
    # does; the padded offset is tried only as a fallback.
    for start in (off + 12 + nsz, off + 12 + ((nsz + 3) & ~3)):
        if start + dsz <= len(b) and b[start:start + 15] == b'schema_version=':
            payload = b[start:start + dsz].rstrip(b'\x00')
            break
    else:
        raise NoteError('note description does not begin with schema_version=')

    head, _, rest = payload.partition(b'records=')
    if not rest:
        raise NoteError('no records= header')
    fields = dict(
        l.split(b'=', 1) for l in head.splitlines() if b'=' in l)
    if fields.get(b'schema_version') != str(SCHEMA).encode():
        raise NoteError(f'schema_version={fields.get(b"schema_version")}, '
                        f'this reader understands {SCHEMA}')
    if fields.get(b'fields_per_record') != str(FIELDS).encode():
        raise NoteError(f'fields_per_record='
                        f'{fields.get(b"fields_per_record")}, expected {FIELDS}')
    count_b, _, body = rest.partition(b'\n')
    try:
        declared = int(count_b)
    except ValueError:
        raise NoteError(f'records={count_b!r} is not an integer')

    recs, i = [], 0
    while i < len(body):
        row = []
        for _ in range(FIELDS):
            c = body.find(b':', i)
            if c < 0:
                raise NoteError('truncated record: no length terminator')
            try:
                n = int(body[i:c])
            except ValueError:
                raise NoteError(f'bad field length {body[i:c]!r}')
            i = c + 1
            if n < 0 or i + n > len(body):
                raise NoteError('field length runs past the payload')
            row.append(body[i:i + n].decode())
            i += n
        recs.append(row)
    if len(recs) != declared:
        raise NoteError(f'parsed {len(recs)} records but the header declares '
                        f'{declared}')
    diag['records'] = len(recs)
    return recs, diag


# ------------------------------------------------------------------ projection
# The VM kinds that project DIRECTLY onto a G1 declaration. An implicit closure
# is a tear-off wrapper, not a competing identity, so it is not in this set --
# it is followed to its parent instead.
DIRECT_KIND = {
    'GetterFunction': ['getter'],
    'SetterFunction': ['setter'],
    'Constructor:generative': ['constructor'],
    'Constructor:factory': ['factory'],
    # Coarser than G1: disambiguated against the inventory, never by parsing
    # the name for operator symbols.
    'RegularFunction': ['method', 'operator'],
}


def project(lib, owner, kind, name, g1_index, private_keys):
    """Project VM coordinates onto exactly one G1 declaration, or explain why not.

    Returns (row, reason). `row` is None when the projection is not unique.
    """
    kinds = DIRECT_KIND.get(kind)
    if kinds is None:
        return None, f'unsupported VM kind {kind}'

    # A private VM name carries its declaring library's key, e.g.
    # `_state@17145467`. Only that library's EXACT key is removed; a regex over
    # trailing digits would strip a legitimate name, and ScrubName would also
    # rewrite get:/set: and so not match G1's vmName contract.
    vm_name = name
    if '@' in name:
        key = private_keys.get(lib)
        if key is None:
            return None, f'private VM name {name!r} but no private key known ' \
                         f'for {lib}'
        suffix = '@' + key
        if not name.endswith(suffix):
            return None, f'private VM name {name!r} does not end with the ' \
                         f'declaring library key {suffix!r}'
        vm_name = name[:-len(suffix)]

    # THE VM'S UNNAMED-CONSTRUCTOR FORM. The VM writes a generative
    # constructor as "Class." or "Class.named"; G1 records owner=Class with
    # name='' for the unnamed one. This is a documented shape, not a guess, so
    # it is projected rather than refused -- but only when the prefix matches
    # the owner the VM itself reported.
    if kinds == ['constructor'] or kinds == ['factory']:
        if '.' in vm_name:
            prefix, _, tail = vm_name.partition('.')
            if owner in ('', prefix):
                owner = prefix
                vm_name = tail
        else:
            return None, f'constructor VM name {vm_name!r} has no Class. prefix'

    cands = [r for r in g1_index.get(lib, [])
             if r['kind'] in kinds
             and (r.get('vmName') == vm_name or r.get('loweredName') == vm_name
                  or r['name'] == vm_name)]
    # The VM's owner is not required to equal G1's canonical owner: an extension
    # member is lowered to a synthetic top-level owner while G1 recovers the
    # extension. Owner is used only to narrow when it is a real class name on
    # both sides.
    if owner and len(cands) > 1:
        narrowed = [r for r in cands if r.get('owner') == owner]
        if len(narrowed) == 1:
            cands = narrowed
    if not cands:
        return None, f'no G1 candidate for {lib} {kind} {vm_name!r}'
    if len(cands) > 1:
        return None, (f'{len(cands)} G1 candidates for {lib} {kind} '
                      f'{vm_name!r}; ambiguity is not resolved by preference')
    return cands[0], 'unique'


def main():
    if len(sys.argv) < 5:
        print('usage: read_inlining.py <aot> <g2-rows.json> <private-keys.json> '
              '<out.json>', file=sys.stderr)
        return 2
    aot, g2_path, keys_path, out_path = sys.argv[1:5]
    g2 = json.load(open(g2_path))
    private_keys = json.load(open(keys_path)) if keys_path != '-' else {}

    g1_index = {}
    for r in g2['rows']:
        g1_index.setdefault(r['library'], []).append(r)

    note_ok, note_error, recs, diag = True, None, [], {}
    try:
        recs, diag = read_note(aot)
    except NoteError as ex:
        note_ok, note_error = False, str(ex)

    # Which declarations appear as an INLINEE, and which only via a synthetic
    # child. Both are recorded; only the first makes a declaration INLINED.
    # SCOPE. G2's inventory covers a declared set of libraries. A record whose
    # inlinee library is outside that set cannot BE any candidate in it, so it
    # is irrelevant rather than unprojectable -- counting it as a projection
    # failure made every in-scope candidate UNKNOWN on the strength of records
    # about dart:async, which is fail-closed to the point of saying nothing.
    #
    # The fail-closed property is kept exactly where it matters: an IN-SCOPE
    # record that will not project still forces UNKNOWN.
    in_scope = set(g1_index)
    inlined, via_child, unprojected, out_of_scope = set(), set(), [], 0
    for r in recs:
        lib, owner, kind, name = r[0], r[1], r[2], r[3]
        plib, powner, pkind, pname = r[4], r[5], r[6], r[7]
        if lib not in in_scope and (plib or '') not in in_scope:
            out_of_scope += 1
            continue
        if kind == 'ImplicitClosureFunction':
            if not pkind or pkind == '<unknown>':
                unprojected.append({'record': r[:8],
                                    'reason': 'implicit closure with an '
                                              'unresolved synthetic parent'})
                continue
            row, why = project(plib, powner, pkind, pname, g1_index, private_keys)
            if row is None:
                unprojected.append({'record': r[:8], 'reason': why})
            else:
                via_child.add(row['declaration_id'])
            continue
        row, why = project(lib, owner, kind, name, g1_index, private_keys)
        if row is None:
            unprojected.append({'record': r[:8], 'reason': why})
        else:
            inlined.add(row['declaration_id'])

    # A record that could not be projected is a fact this reader cannot place.
    # Every candidate becomes UNKNOWN rather than risk calling the unplaced
    # declaration NOT_INLINED.
    complete = note_ok and not unprojected

    states, hist = [], {}
    for r in g2['rows']:
        if r['kind'] not in ('method', 'getter', 'setter', 'operator'):
            continue
        did = r['declaration_id']
        if did in inlined:
            st, why = 'INLINED', 'the declared function is an inlinee'
        elif not note_ok:
            st, why = 'UNKNOWN', f'note not validated: {note_error}'
        elif not complete:
            st, why = 'UNKNOWN', (f'{len(unprojected)} record(s) could not be '
                                  f'projected onto G1, so absence proves nothing')
        elif did in via_child:
            # SM1-G5's tear-off arm showed behaviour still moved for a
            # top-level function torn off in its own library and called
            # immediately. That is ONE shape, so anything else stays UNKNOWN.
            st, why = 'UNKNOWN', ('only a synthetic child is an inlinee; the '
                                  'harmless case is established for one shape '
                                  'only')
        else:
            st, why = 'NOT_INLINED', 'absent from a fully validated note'
        states.append({'declaration_id': did, 'library': r['library'],
                       'owner': r['owner'], 'kind': r['kind'],
                       'name': r['name'], 'state': st, 'reason': why})
        hist[st] = hist.get(st, 0) + 1

    json.dump({
        'schema': 'semantic-map-1/g5-inlining-state/1',
        'gate': 'SM1-G5', 'issue': 54,
        'aot': aot,
        'note_validated': note_ok,
        'note_error': note_error,
        'note_complete_projection': complete,
        'unprojected_records': unprojected[:20],
        'unprojected_count': len(unprojected),
        'out_of_scope_records': out_of_scope,
        'in_scope_libraries': sorted(in_scope),
        'diagnostics': diag,
        'state_histogram': hist,
        'states': states,
    }, open(out_path, 'w'), indent=2)
    print(f'  candidates={len(states)} {hist} -> {out_path}')
    if not note_ok:
        print(f'  NOTE NOT VALIDATED: {note_error}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
