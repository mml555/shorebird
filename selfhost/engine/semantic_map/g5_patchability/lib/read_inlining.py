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
SCHEMA = 6
FIELDS = 20
SHT_NOTE = 7


class NoteError(Exception):
    """Validation failed. Every candidate becomes UNKNOWN.

    Carries a STABLE CODE as well as prose. The falsification suite asserts the
    code, not just that something was refused: a reader that collapsed every
    problem into one generic refusal would otherwise pass every arm, and one
    gate could silently mask another.
    """

    def __init__(self, code, message):
        super().__init__(f'{code}: {message}')
        self.code = code
        self.message = message


def read_note(path):
    """Return (records, diagnostics). Raises NoteError on any validation failure.

    Identity is the whole section header plus the note header: name, sh_type,
    owner, note type, schema and uniqueness are all checked, because a section
    name is not a signature.
    """
    try:
        b = open(path, 'rb').read()
    except OSError as ex:
        # Not a parser defect: the artifact is simply not readable. Modeled so
        # it does not arrive labeled as an unmodeled exception.
        raise NoteError('ARTIFACT_UNREADABLE',
                        f'cannot read {path}: {ex.strerror}')
    diag = {'aot_sha256': hashlib.sha256(b).hexdigest()}
    if len(b) < 64 or b[:4] != b'\x7fELF':
        raise NoteError('NOT_ELF', 'not an ELF file')
    if b[4] != 2:
        raise NoteError('ELF32_UNSUPPORTED',
                        'not ELF64; this reader does not model ELF32')

    # Every read is bounds-checked. A malformed offset must arrive as a modeled
    # refusal, not as a struct.error that kills the process before any state is
    # written -- a caller reading only the histogram would then see no rows at
    # all rather than UNKNOWN, which is the one outcome this reader must never
    # produce.
    def need(o, n, what, code='MALFORMED_ELF_SECTION_TABLE'):
        if o < 0 or o + n > len(b):
            raise NoteError(code, f'{what} wants bytes {o}..{o + n} of a '
                            f'{len(b)}-byte file')

    def u16(o, what='u16'): need(o, 2, what); return struct.unpack_from('<H', b, o)[0]
    def u32(o, what='u32'): need(o, 4, what); return struct.unpack_from('<I', b, o)[0]
    def u64(o, what='u64'): need(o, 8, what); return struct.unpack_from('<Q', b, o)[0]

    shoff = u64(0x28, 'e_shoff')
    shentsize, shnum, shstrndx = (u16(0x3a, 'e_shentsize'),
                                  u16(0x3c, 'e_shnum'), u16(0x3e, 'e_shstrndx'))
    if shoff == 0 or shnum == 0:
        raise NoteError('MALFORMED_ELF_SECTION_TABLE', 'no section table')
    if shentsize < 64:
        raise NoteError('MALFORMED_ELF_SECTION_TABLE',
                        f'e_shentsize={shentsize}, too small for an ELF64 '
                        f'section header')
    if shstrndx >= shnum:
        raise NoteError('MALFORMED_ELF_SECTION_TABLE',
                        f'e_shstrndx={shstrndx} is not below '
                        f'e_shnum={shnum}')
    need(shoff, shnum * shentsize, 'section table')
    stroff = u64(shoff + shstrndx * shentsize + 0x18, 'shstrtab sh_offset')

    def name_at(idx):
        s = stroff + idx
        if s < 0 or s >= len(b):
            raise NoteError('SECTION_NAME_OUT_OF_BOUNDS',
                            f'section name offset {s} lies outside the '
                            f'{len(b)}-byte file')
        e = b.find(b'\x00', s)
        if e < 0:
            raise NoteError('SECTION_NAME_UNTERMINATED',
                            f'section name at {s} is unterminated')
        try:
            return b[s:e].decode('utf-8')
        except UnicodeDecodeError as ex:
            # Refusing the whole file because an unrelated section carries a
            # junk name is deliberate: this reader cannot tell which section it
            # failed to name, so it cannot claim the note it wants is unique.
            raise NoteError('SECTION_NAME_NOT_UTF8',
                            f'section name at {s} is not valid '
                            f'UTF-8: {ex}')

    hits = [shoff + i * shentsize for i in range(shnum)
            if name_at(u32(shoff + i * shentsize)) == NOTE]
    if not hits:
        raise NoteError('NOTE_SECTION_ABSENT', f'no {NOTE} section')
    if len(hits) > 1:
        raise NoteError('DUPLICATE_NOTE_SECTION',
                        f'{len(hits)} sections named {NOTE}; a duplicate or '
                        f'conflicting note cannot establish anything')
    hdr = hits[0]
    if u32(hdr + 0x04) != SHT_NOTE:
        raise NoteError('NOTE_SECTION_NOT_SHT_NOTE',
                        f'sh_type={u32(hdr + 0x04)}, expected SHT_NOTE')
    off, size = u64(hdr + 0x18, 'note sh_offset'), u64(hdr + 0x20, 'note sh_size')
    need(off, size, 'note section extent', 'NOTE_EXTENT_OUT_OF_BOUNDS')
    diag['note_section_sha256'] = hashlib.sha256(b[off:off + size]).hexdigest()
    if size < 12:
        raise NoteError('NOTE_TOO_SHORT',
                        f'note section is {size} bytes, too short for a '
                        f'header')
    nsz, dsz, ntype = (u32(off, 'n_namesz'), u32(off + 4, 'n_descsz'),
                       u32(off + 8, 'n_type'))
    if ntype != NOTE_TYPE:
        raise NoteError('NOTE_TYPE_MISMATCH',
                        f'note type={ntype}, expected {NOTE_TYPE}')
    if nsz != len(OWNER) or b[off + 12:off + 12 + nsz] != OWNER:
        got = b[off + 12:off + 12 + nsz]
        raise NoteError('NOTE_OWNER_MISMATCH',
                        f'owner is {got!r} (name_size={nsz}), expected '
                        f'{OWNER!r} ({len(OWNER)})')
    # The producer writes name and description contiguously, as GenerateBuildId
    # does; the padded offset is tried only as a fallback.
    payload = start = None
    for cand in (off + 12 + nsz, off + 12 + ((nsz + 3) & ~3)):
        if cand + dsz <= len(b) and b[cand:cand + 15] == b'schema_version=':
            payload, start = b[cand:cand + dsz].rstrip(b'\x00'), cand
            break
    if payload is None:
        raise NoteError('NOTE_DESCRIPTION_MALFORMED',
                        'note description does not begin with '
                        'schema_version=')

    # THE NOTE MUST CONSUME ITS SECTION. A note section is a sequence, so
    # checking one header leaves room for a second, conflicting Shorebird note
    # after this one -- which the reader would silently ignore while reporting
    # the first as authoritative. Uniqueness across sections is not uniqueness
    # within one.
    if start + dsz > off + size:
        raise NoteError('NOTE_EXTENT_OUT_OF_BOUNDS',
                        f'note description ends at {start + dsz}, past the '
                        f'end of its {size}-byte section at {off}')
    tail = b[start + dsz:off + size]
    if tail.strip(b'\x00'):
        raise NoteError('DUPLICATE_AUTHORITATIVE_NOTE',
                        f'{len(tail)} bytes follow the note inside its own '
                        f'section; a duplicate or conflicting note cannot '
                        f'establish anything')

    head, _, rest = payload.partition(b'records=')
    if not rest:
        raise NoteError('NOTE_DESCRIPTION_MALFORMED', 'no records= header')
    fields = dict(
        l.split(b'=', 1) for l in head.splitlines() if b'=' in l)
    if fields.get(b'schema_version') != str(SCHEMA).encode():
        raise NoteError('SCHEMA_VERSION_MISMATCH',
                        f'schema_version={fields.get(b"schema_version")}, '
                        f'this reader understands {SCHEMA}')
    if fields.get(b'fields_per_record') != str(FIELDS).encode():
        raise NoteError('FIELDS_PER_RECORD_MISMATCH',
                        f'fields_per_record='
                        f'{fields.get(b"fields_per_record")}, expected {FIELDS}')
    count_b, _, body = rest.partition(b'\n')
    try:
        declared = int(count_b)
    except ValueError:
        raise NoteError('RECORD_COUNT_NOT_INTEGER',
                        f'records={count_b!r} is not an integer')

    recs, i = [], 0
    while i < len(body):
        row = []
        for _ in range(FIELDS):
            c = body.find(b':', i)
            if c < 0:
                raise NoteError('RECORD_TRUNCATED',
                                'truncated record: no length terminator')
            try:
                n = int(body[i:c])
            except ValueError:
                raise NoteError('FIELD_LENGTH_INVALID',
                                f'bad field length {body[i:c]!r}')
            i = c + 1
            if n < 0 or i + n > len(body):
                raise NoteError('FIELD_LENGTH_OUT_OF_RANGE',
                                'field length runs past the payload')
            try:
                row.append(body[i:i + n].decode('utf-8'))
            except UnicodeDecodeError as ex:
                raise NoteError('RECORD_FIELD_NOT_UTF8',
                                f'record field at offset {i} is not valid '
                                f'UTF-8: {ex}')
            i += n
        recs.append(row)
    if len(recs) != declared:
        raise NoteError('RECORD_COUNT_MISMATCH',
                        f'parsed {len(recs)} records but the header '
                        f'declares '
                        f'{declared}')
    diag['records'] = len(recs)
    return recs, diag


# ------------------------------------------------------- candidate admission
# WHICH DECLARATIONS THE NOTE CAN WITNESS. See evidence/recorder_completeness.md
# for the source-level enumeration; the short form:
#
# Every copy of a Dart function's body IL into another function is registered
# by exactly one code path (FlowGraphInliner::NextInlineId, called from exactly
# one site). But a second family of compiler operations materializes a callee's
# semantics into a caller WITHOUT registering an inline id -- the
# CallSpecializer replacements. Those are gated, and the gates decide which
# kinds this reader may make a safety claim about.
CANDIDATE_KINDS = {
    # kImplicitGetter/kImplicitSetter only; the VM's own comment says
    # "Non-implicit getters are inlined like normal methods by conventional
    # inlining in FlowGraphInliner". A G1 getter/setter row is always an
    # explicit declaration, so it cannot be an implicit accessor.
    'method', 'getter', 'setter',
    # Operator replacement is gated on operand class ids drawn from a fixed set
    # of VM primitives (Smi, Mint, Double, Float32x4, Int32x4, Float64x2). An
    # app-declared class id is never in that set.
    'operator',
}

# Declarations that HAVE a body but whose materialization the completeness
# proof does not cover. They are candidates, and they refuse -- dropping them
# would let a later change flip them into candidacy and inherit an unsound
# NOT_INLINED.
REFUSED_KINDS = {
    'field': 'a field-backed implicit accessor can be materialized into a '
             'caller by CallSpecializer::TryInlineInstanceGetter/Setter and '
             'AotCallSpecializer::TryInlineFieldAccess, neither of which '
             'reaches FlowGraphInliner::NextInlineId, so the note cannot '
             'witness it',
    'constructor': 'constructor body materialization is not covered by the '
                   'recorder-completeness proof',
    'factory': 'factory body materialization is not covered by the '
               'recorder-completeness proof',
}

# Rows that declare no body at all, so there is nothing to inline and no claim
# to make. They are reported separately and counted, never silently dropped.
NO_BODY_KINDS = {'class'}


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


def project(lib, owner, kind, name, g1_index, libkey):
    """Project VM coordinates onto exactly one G1 declaration, or explain why not.

    Returns (row, code, detail). `row` is None when the projection is not
    unique, and the code says WHICH failure it was -- an owner disagreement is
    not the same fact as no candidate at all.
    """
    kinds = DIRECT_KIND.get(kind)
    if kinds is None:
        return None, 'UNSUPPORTED_VM_KIND', f'unsupported VM kind {kind}'

    # A private VM name carries its declaring library's key, e.g.
    # `_state@17145467`. Only that library's EXACT key is removed; a regex over
    # trailing digits would strip a legitimate name, and ScrubName would also
    # rewrite get:/set: and so not match G1's vmName contract.
    vm_name = name
    if '@' in name:
        # The key comes from the PRODUCER (Library::private_key()), never from
        # the name being validated. Schema 6 carries it per side.
        if not libkey or libkey == '<unknown>':
            return None, 'PRIVATE_KEY_MISSING', (
                f'private VM name {name!r} but the producer supplied no '
                f'private key for {lib}')
        # A constructor arrives as `_Class@key.` or `_Class@key.named`: the key
        # sits on the class part, not at the end of the string.
        if name.endswith(libkey):
            vm_name = name[:-len(libkey)]
        elif libkey + '.' in name:
            vm_name = name.replace(libkey + '.', '.', 1)
        else:
            return None, 'PRIVATE_KEY_MISMATCH', (
                f'private VM name {name!r} does not carry the declaring '
                f'library key {libkey!r}')

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
            return None, 'CONSTRUCTOR_NAME_MALFORMED', (
                f'constructor VM name {vm_name!r} has no Class. prefix')

    # MATCH ONLY ON G1'S VM-FACING NAMES. The canonical `name` was previously
    # accepted as a fallback; it is removed. G1's `name` is the declared name and
    # is not the VM binding name for accessors or lowered members, so matching on
    # it could put an inline relation on declaration A -- and then make B falsely
    # appear NOT_INLINED. That is a dangerous positive, not a coverage gain.
    cands = [r for r in g1_index.get(lib, [])
             if r['kind'] in kinds
             and vm_name in (r.get('vmName'), r.get('loweredName'))]

    # OWNER MUST AGREE, with ONE explicit exception. A blanket "owner optional"
    # rule let an ordinary class-owner disagreement pass whenever a single
    # candidate happened to remain. The exception is extension lowering, and it
    # has to be visible in G1's own metadata (ownerKind), not assumed: an
    # extension member is lowered to a synthetic top-level owner while G1
    # recovers the extension owner.
    def owner_ok(r):
        if (r.get('owner') or '') == (owner or ''):
            return True
        if not owner and r.get('ownerKind') in ('extension', 'extension_type'):
            return True
        return False

    rejected = [r for r in cands if not owner_ok(r)]
    cands = [r for r in cands if owner_ok(r)]
    if rejected and not cands:
        return None, 'OWNER_MISMATCH', (
            f'owner mismatch for {lib} {kind} {vm_name!r}: VM says {owner!r}, '
            f'G1 says {[r.get("owner") for r in rejected]!r} with ownerKind '
            f'{[r.get("ownerKind") for r in rejected]!r}')
    if not cands:
        return None, 'NO_AUTHORITATIVE_G1_PROJECTION', (
            f'no G1 candidate for {lib} {kind} {vm_name!r}')
    if len(cands) > 1:
        return None, 'AMBIGUOUS_G1_PROJECTION', (
            f'{len(cands)} G1 candidates for {lib} {kind} {vm_name!r}; '
            f'ambiguity is not resolved by preference')
    return cands[0], 'UNIQUE', 'unique'


def main():
    if len(sys.argv) < 5:
        print('usage: read_inlining.py <aot> <g2-rows.json> <private-keys.json> '
              '<out.json>', file=sys.stderr)
        return 2
    aot, g2_path, keys_path, out_path = sys.argv[1:5]
    g2 = json.load(open(g2_path))
    # Kept only so the CLI shape is stable; schema 6 carries the key per record,
    # so no external key file is consulted.
    _ = keys_path

    g1_index = {}
    for r in g2['rows']:
        g1_index.setdefault(r['library'], []).append(r)

    note_ok, note_error, note_code, recs, diag = True, None, None, [], {}
    try:
        recs, diag = read_note(aot)
    except NoteError as ex:
        note_ok, note_error, note_code = False, ex.message, ex.code
    except Exception as ex:
        # BACKSTOP. A parser exception must resolve to a modeled UNKNOWN, never
        # merely crash: crashing writes no output, and an absent row must never
        # be read as a safe row. Anything arriving here is a reader defect --
        # it is labeled unmodeled rather than dressed up as a known cause.
        note_ok = False
        note_code = 'UNMODELED_PARSER_EXCEPTION'
        note_error = f'unmodeled parser exception: {type(ex).__name__}: {ex}'

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
        in_libkey, in_plibkey = r[16], r[17]
        if lib not in in_scope and (plib or '') not in in_scope:
            out_of_scope += 1
            continue
        if kind == 'ImplicitClosureFunction':
            if not pkind or pkind == '<unknown>':
                unprojected.append({
                    'record': r[:8],
                    'code': 'IMPLICIT_CLOSURE_PARENT_UNRESOLVED',
                    'reason': 'implicit closure with an unresolved synthetic '
                              'parent'})
                continue
            row, code, why = project(plib, powner, pkind, pname, g1_index,
                                     in_plibkey)
            if row is None:
                unprojected.append({'record': r[:8], 'code': code,
                                    'reason': why})
            else:
                via_child.add(row['declaration_id'])
            continue
        row, code, why = project(lib, owner, kind, name, g1_index, in_libkey)
        if row is None:
            unprojected.append({'record': r[:8], 'code': code, 'reason': why})
        else:
            inlined.add(row['declaration_id'])

    # A record that could not be projected is a fact this reader cannot place.
    # Every candidate becomes UNKNOWN rather than risk calling the unplaced
    # declaration NOT_INLINED.
    complete = note_ok and not unprojected

    states, hist, no_body = [], {}, []
    for r in g2['rows']:
        did = r['declaration_id']
        if r['kind'] in NO_BODY_KINDS:
            no_body.append({'declaration_id': did, 'library': r['library'],
                            'name': r['name'], 'kind': r['kind'],
                            'reason': 'declares no body, so no inline copy of '
                                      'it can exist'})
            continue
        if r['kind'] in REFUSED_KINDS:
            st, code, why = ('UNKNOWN', 'KIND_NOT_COVERED_BY_PROOF',
                             REFUSED_KINDS[r['kind']])
        elif r['kind'] not in CANDIDATE_KINDS:
            # Fail closed on a kind nobody has classified.
            st, code, why = ('UNKNOWN', 'KIND_UNCLASSIFIED',
                             f"kind {r['kind']!r} is not classified by the "
                             f"recorder-completeness proof")
        elif did in inlined:
            st, code, why = ('INLINED', 'INLINEE',
                             'the declared function is an inlinee')
        elif not note_ok:
            st, code, why = ('UNKNOWN', 'NOTE_NOT_VALIDATED',
                             f'note not validated: {note_error}')
        elif not complete:
            st, code, why = ('UNKNOWN', 'PROJECTION_INCOMPLETE',
                             f'{len(unprojected)} record(s) could not be '
                             f'projected onto G1, so absence proves nothing')
        elif did in via_child:
            # SM1-G5's tear-off arm showed behaviour still moved for a
            # top-level function torn off in its own library and called
            # immediately. That is ONE shape, so anything else stays UNKNOWN.
            st, code, why = ('UNKNOWN', 'ONLY_SYNTHETIC_CHILD_INLINEE',
                             'only a synthetic child is an inlinee; the '
                             'harmless case is established for one shape only')
        else:
            st, code, why = ('NOT_INLINED', 'ABSENT_FROM_VALIDATED_NOTE',
                             'absent from a fully validated note')
        states.append({'declaration_id': did, 'library': r['library'],
                       'owner': r['owner'], 'kind': r['kind'],
                       'name': r['name'], 'state': st, 'code': code,
                       'reason': why})
        hist[st] = hist.get(st, 0) + 1

    # EVERY G1 ROW IS ACCOUNTED FOR. A row that is neither a candidate nor
    # explicitly body-less would otherwise vanish, and a caller asking for a
    # declaration's state would get silence -- which is exactly the reading
    # this gate refuses ("no missing row interpreted as safe").
    # The reconciliation is MACHINE OUTPUT, not prose: one line per state plus
    # the body-less rows, summing to the G1 inventory, asserted here rather
    # than left for a reader of the report to add up.
    accounting = {
        'total_g1_rows': len(g2['rows']),
        'INLINED': hist.get('INLINED', 0),
        'NOT_INLINED': hist.get('NOT_INLINED', 0),
        'UNKNOWN': hist.get('UNKNOWN', 0),
        'NO_BODY': len(no_body),
    }
    accounting['accounted'] = (accounting['INLINED'] + accounting['NOT_INLINED']
                               + accounting['UNKNOWN'] + accounting['NO_BODY'])
    if accounting['accounted'] != accounting['total_g1_rows']:
        raise SystemExit(f'inventory mismatch: accounted='
                         f"{accounting['accounted']} but total_g1_rows="
                         f"{accounting['total_g1_rows']}")

    json.dump({
        'schema': 'semantic-map-1/g5-inlining-state/2',
        'gate': 'SM1-G5', 'issue': 54,
        'aot': aot,
        'note_validated': note_ok,
        'note_error': note_error,
        'note_error_code': note_code,
        'note_complete_projection': complete,
        'unprojected_records': unprojected[:20],
        'unprojected_count': len(unprojected),
        'out_of_scope_records': out_of_scope,
        'in_scope_libraries': sorted(in_scope),
        'diagnostics': diag,
        'state_histogram': hist,
        'accounting': accounting,
        'g1_rows': len(g2['rows']),
        'rows_accounted_for': accounting['accounted'],
        'no_body_rows': no_body,
        'states': states,
    }, open(out_path, 'w'), indent=2)
    print('  ' + ' '.join(f'{k}={v}' for k, v in accounting.items())
          + f' -> {out_path}')
    if not note_ok:
        print(f'  NOTE NOT VALIDATED [{note_code}]: {note_error}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
