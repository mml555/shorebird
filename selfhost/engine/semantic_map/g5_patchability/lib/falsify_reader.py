#!/usr/bin/env python3
"""Adversarial falsification of read_inlining.py.

Every arm mutates a real schema-6 AOT (or the G1 projection it is read
against) and asserts three things:

  1. the reader produced output at all -- a parser exception must resolve to a
     modeled UNKNOWN, never a crash, because a crash writes no rows and an
     absent row must never be read as a safe row;
  2. note_validated is False and the projection is incomplete;
  3. NO candidate is reported NOT_INLINED. NOT_INLINED is the safety fact this
     gate wants to use, so no mutation may be able to manufacture one.

The harness derives its own verdict: it exits non-zero if any arm fails, so a
pass cannot be asserted by transcription.

usage: falsify_reader.py <schema6.aot> <g2-rows.json> <workdir>
"""
import json, os, struct, subprocess, sys

# SM1_READER exists so this harness can be pointed at a deliberately weakened
# reader and shown to FAIL. A falsification set that cannot fail certifies
# nothing.
READER = os.environ.get(
    'SM1_READER',
    os.path.join(os.path.dirname(os.path.abspath(__file__)), 'read_inlining.py'))
NOTE = b'.note.shorebird.inlining'
BASE, ROWS, W = sys.argv[1], sys.argv[2], sys.argv[3]
OUT = os.path.join(W, 'fx.json')
results = []


# ------------------------------------------------------------------ ELF access
def sec(d, want=NOTE):
    """Locate (hdr, sh_offset, sh_size, shstrtab_offset) for a section."""
    shoff = struct.unpack_from('<Q', d, 0x28)[0]
    se, sn, sx = struct.unpack_from('<HHH', d, 0x3a)
    so = struct.unpack_from('<Q', d, shoff + sx * se + 0x18)[0]
    for i in range(sn):
        h = shoff + i * se
        o = so + struct.unpack_from('<I', d, h)[0]
        if d[o:d.index(b'\0', o)] == want:
            return (h, struct.unpack_from('<Q', d, h + 0x18)[0],
                    struct.unpack_from('<Q', d, h + 0x20)[0], so)
    raise SystemExit(f'harness: no {want!r} section in the baseline')


def strtab(d):
    shoff = struct.unpack_from('<Q', d, 0x28)[0]
    se, sn, sx = struct.unpack_from('<HHH', d, 0x3a)
    h = shoff + sx * se
    return (struct.unpack_from('<Q', d, h + 0x18)[0],
            struct.unpack_from('<Q', d, h + 0x20)[0])


def payload_bounds(d):
    """(start, descsz) of the note description."""
    _, off, _, _ = sec(d)
    nsz, dsz = struct.unpack_from('<I', d, off)[0], struct.unpack_from('<I', d, off + 4)[0]
    for cand in (off + 12 + nsz, off + 12 + ((nsz + 3) & ~3)):
        if d[cand:cand + 15] == b'schema_version=':
            return cand, dsz
    raise SystemExit('harness: cannot find the note description')


def body_start(d):
    """Offset of the first length-prefixed record field."""
    st, dsz = payload_bounds(d)
    i = d.index(b'records=', st, st + dsz)
    return d.index(b'\n', i) + 1


# --------------------------------------------------------------------- driver
def run(path, rows, label, expect_absent=None, note_intact=False):
    # Delete the output FIRST. Without this a run that crashed before writing
    # leaves the previous arm's JSON in place, and a crash masquerades as a
    # correctly-caught mutation.
    try:
        os.remove(OUT)
    except FileNotFoundError:
        pass
    r = subprocess.run([sys.executable, READER, path, rows, '-', OUT],
                       capture_output=True, text=True)
    if not os.path.exists(OUT):
        tail = '; '.join(r.stderr.strip().splitlines()[-2:])[:120] or '<no stderr>'
        results.append((label, 'FAIL', f'CRASHED, no modeled UNKNOWN: {tail}'))
        return
    d = json.load(open(OUT))
    hist = d['state_histogram']
    bad = []
    # A mutation of the G1 projection leaves the note itself validly framed, so
    # the arm asserts the EXPECTED value rather than a blanket False -- a note
    # that failed to validate here would mean the arm tested something else.
    if d['note_validated'] is not note_intact:
        bad.append(f"note_validated is {d['note_validated']}, "
                   f"expected {note_intact}")
    if d['note_complete_projection']:
        bad.append('projection reported complete')
    if hist.get('NOT_INLINED'):
        bad.append(f"manufactured {hist['NOT_INLINED']} NOT_INLINED")
    if expect_absent:
        st = {s['declaration_id']: s['state'] for s in d['states']}
        if st.get(expect_absent) == 'INLINED':
            bad.append(f'the target declaration is still INLINED')
    reason = (d.get('note_error') or '')[:96]
    results.append((label, 'FAIL' if bad else 'pass',
                    '; '.join(bad) if bad else f'{hist} <- {reason}'))


def mutate(label, fn, expect_absent=None):
    d = bytearray(open(BASE, 'rb').read())
    try:
        fn(d)
    except Exception as ex:                       # a broken arm is not a pass
        results.append((label, 'FAIL',
                        f'harness could not apply the mutation: '
                        f'{type(ex).__name__}: {ex}'))
        return
    p = os.path.join(W, 'fx.aot')
    open(p, 'wb').write(d)
    run(p, ROWS, label, expect_absent)


def mutate_rows(label, fn, expect_absent=None):
    j = json.load(open(ROWS))
    fn(j)
    p = os.path.join(W, 'fx_rows.json')
    json.dump(j, open(p, 'w'))
    run(BASE, p, label, expect_absent, note_intact=True)


# ------------------------------------------------------------------- baseline
def baseline():
    try:
        os.remove(OUT)
    except FileNotFoundError:
        pass
    subprocess.run([sys.executable, READER, BASE, ROWS, '-', OUT],
                   capture_output=True, text=True)
    d = json.load(open(OUT))
    ok = (d['note_validated'] and d['note_complete_projection']
          and d['state_histogram'].get('NOT_INLINED', 0) > 0)
    results.append(('BASELINE unmodified', 'pass' if ok else 'FAIL',
                    f"validated={d['note_validated']} "
                    f"complete={d['note_complete_projection']} "
                    f"{d['state_histogram']}"))
    return d


b0 = baseline()
INLINED = [s for s in b0['states'] if s['state'] == 'INLINED']

# ------------------------------------------------------------- note identity
mutate('owner forged, same length (Shorebirx)',
       lambda d: d.__setitem__(sec(d)[1] + 12 + 8, ord('X')))


def f_owner_gnu(d):
    """A real, ordinary owner -- not a corrupted one. Exact equality only."""
    off = sec(d)[1]
    struct.pack_into('<I', d, off, 4)
    d[off + 12:off + 12 + 10] = b'GNU\0\0\0\0\0\0\0'


mutate('owner replaced with an ordinary GNU owner', f_owner_gnu)
mutate('note n_type 2 -> 9',
       lambda d: struct.pack_into('<I', d, sec(d)[1] + 8, 9))
mutate('sh_type SHT_NOTE -> PROGBITS',
       lambda d: struct.pack_into('<I', d, sec(d)[0] + 0x04, 1))


def f_dup_section(d):
    h, _, _, _ = sec(d)
    shoff = struct.unpack_from('<Q', d, 0x28)[0]
    se, sn, _ = struct.unpack_from('<HHH', d, 0x3a)
    nameidx = struct.unpack_from('<I', d, h)[0]
    for i in range(sn):
        hh = shoff + i * se
        if hh != h and struct.unpack_from('<I', d, hh + 0x04)[0] == 7:
            struct.pack_into('<I', d, hh, nameidx)
            return
    raise RuntimeError('no second SHT_NOTE section to rename')


mutate('two sections claiming the note name', f_dup_section)


def f_trailing(d):
    """Shrink the note so live bytes remain after it, inside its own section."""
    st, dsz = payload_bounds(d)
    struct.pack_into('<I', d, sec(d)[1] + 4, 64)
    assert dsz > 96


mutate('live bytes trail the note inside its own section', f_trailing)


def f_second_note(d):
    """A genuine second Shorebird note in the SAME section, after the first."""
    off, size = sec(d)[1], sec(d)[2]
    st, dsz = payload_bounds(d)
    struct.pack_into('<I', d, off + 4, 64)          # first note ends early
    p = st + 64
    struct.pack_into('<I', d, p, 10)                # n_namesz
    struct.pack_into('<I', d, p + 4, off + size - (p + 12 + 12))
    struct.pack_into('<I', d, p + 8, 2)             # n_type
    d[p + 12:p + 22] = b'Shorebird\0'


mutate('a second Shorebird note in the same section', f_second_note)
mutate('note section renamed (note absent)',
       lambda d: d.__setitem__(sec(d)[3] + struct.unpack_from('<I', d, sec(d)[0])[0], ord('X')))

# --------------------------------------------- section table / name integrity
mutate('e_shoff out of bounds',
       lambda d: struct.pack_into('<Q', d, 0x28, len(d) * 4))
mutate('e_shstrndx >= e_shnum',
       lambda d: struct.pack_into('<H', d, 0x3e,
                                  struct.unpack_from('<H', d, 0x3c)[0] + 7))
mutate('e_shentsize too small for ELF64',
       lambda d: struct.pack_into('<H', d, 0x3a, 8))
mutate('sh_name index past the string table',
       lambda d: struct.pack_into('<I', d, sec(d)[0], 0xFFFFFF00))


def f_unterminated(d):
    o, n = strtab(d)
    d[o:o + n] = bytes(0x41 if c == 0 else c for c in d[o:o + n])


mutate('section names unterminated (no NUL in shstrtab)', f_unterminated)


def f_name_utf8(d):
    h, _, _, so = sec(d)
    d[so + struct.unpack_from('<I', d, h)[0] + 6] = 0xFF


mutate('section name is not valid UTF-8', f_name_utf8)
mutate('note sh_offset past EOF',
       lambda d: struct.pack_into('<Q', d, sec(d)[0] + 0x18, len(d) - 4))
mutate('note sh_size past EOF',
       lambda d: struct.pack_into('<Q', d, sec(d)[0] + 0x20, len(d) * 2))

# ---------------------------------------------------------- schema and framing
mutate('schema_version 6 -> 9',
       lambda d: d.__setitem__(d.index(b'schema_version=6', *payload_bounds(d)[:1]) + 15, ord('9')))


def f_fields(d):
    st, dsz = payload_bounds(d)
    i = d.index(b'fields_per_record=20', st, st + dsz)
    d[i + 18:i + 20] = b'99'


mutate('fields_per_record 20 -> 99', f_fields)


def f_count(d):
    """Length-preserving: the declared count must disagree with what parses."""
    st, dsz = payload_bounds(d)
    i = d.index(b'records=', st, st + dsz) + 8
    j = d.index(b'\n', i)
    n = len(d) - 1                     # keep the byte length identical
    d[i:j] = b'9' * (j - i)
    assert len(d) == n + 1


mutate('declared record count disagrees with the payload', f_count)


def f_len_inflated(d):
    i = body_start(d)
    k = d.index(b':', i)
    d[i:k] = b'9' * (k - i)


mutate('first field length inflated', f_len_inflated)


def f_len_nonnumeric(d):
    i = body_start(d)
    k = d.index(b':', i)
    d[i:k] = b'x' * (k - i)


mutate('field length is not an integer', f_len_nonnumeric)


def f_field_utf8(d):
    i = body_start(d)
    k = d.index(b':', i)
    d[k + 1] = 0xFF


mutate('record field is not valid UTF-8', f_field_utf8)
mutate('not an ELF file', lambda d: d.__setitem__(slice(0, 4), b'XXXX'))
mutate('ELF32, which this reader does not model',
       lambda d: d.__setitem__(4, 1))

# ------------------------------------------------------------- mapper identity
if INLINED:
    row = INLINED[0]
    lib, decl, key = row['library'], row['name'], row['declaration_id']

    def f_vmname(j):
        """Canonical `name` still matches; vmName/loweredName no longer do.

        With the canonical-name fallback removed this record must fail to
        project, so the declaration must NOT come back INLINED.
        """
        hit = 0
        for r in j['rows']:
            if r['library'] == lib and r.get('name') == decl:
                r['vmName'] = 'zzz_not_the_vm_name'
                r['loweredName'] = 'zzz_not_lowered_either'
                hit += 1
        if not hit:
            raise SystemExit(f'harness: no G1 row named {decl!r} in {lib}')

    mutate_rows(f'vmName/loweredName diverge from canonical name ({decl})',
                f_vmname, expect_absent=key)

    def f_owner(j):
        """An ordinary owner that disagrees with the record's own owner."""
        for r in j['rows']:
            if r['library'] == lib and r.get('name') == decl:
                r['owner'], r['ownerKind'] = 'NotTheOwner', 'class'

    mutate_rows(f'G1 owner disagrees with the record owner ({decl})',
                f_owner, expect_absent=key)

    def f_kind(j):
        """Kind outside the set the record's VM kind projects onto."""
        for r in j['rows']:
            if r['library'] == lib and r.get('name') == decl:
                r['kind'] = 'field'

    mutate_rows(f'G1 kind moved outside the projected set ({decl})',
                f_kind, expect_absent=key)
else:
    results.append(('mapper arm', 'FAIL',
                    'baseline produced no INLINED declaration to falsify'))

# ------------------------------------------------------------------- verdict
print(f'{"arm":58} {"result":6} detail')
print('-' * 100)
for label, verdict, detail in results:
    print(f'{label:58} {verdict:6} {detail}')
failed = [r for r in results if r[1] == 'FAIL']
print('-' * 100)
print(f'arms={len(results)} passed={len(results) - len(failed)} failed={len(failed)}')
print('SM1_G5_READER_FALSIFICATION: '
      + ('ALL_ARMS_REFUSED' if not failed else 'DEFECTS_PRESENT'))
sys.exit(1 if failed else 0)
