#!/usr/bin/env python3
# cspell:words repack repacked compresslevel infolist
"""Repack a Route B compiler archive with some members replaced, deterministically.

    v2_repack_compiler.py <donor.zip> <out.zip> [NAME=FILE]... --note TEXT

Every entry of the donor is carried over IN ITS ORDER with its own timestamp,
mode, extra field and compression, so the only entries whose bytes differ are
the replaced ones and PROVENANCE.txt. PROVENANCE.txt has the digest line of each
replaced member rewritten (and the old digest must match the donor's actual
member, or this refuses) and one `repacked` line appended per replacement.

Deterministic: same donor, same replacements, same note give the same bytes.
It is NOT byte-identical to a donor built by Info-ZIP `zip -y` when nothing is
replaced -- Python's zlib framing and header layout differ -- which is why the
mint reuses the donor's bytes when there is nothing to replace.

--note is REQUIRED with any replacement (one line, no control characters): it is
written into PROVENANCE.txt, which also says the replaced file is NOT from the
build the header describes.

Refuses: a name that is not in the donor, PROVENANCE.txt as a replacement, a
replacement identical to the donor's member, a PROVENANCE digest line that
disagrees with the donor's member, a donor with a repeated entry name or a zip64
extra record, a missing note, a note with a control character.

The bytes depend on the Python and zlib that wrote them (zlib's deflate output
can differ between versions); the same toolchain gives the same bytes. Publish
the minted output, do not re-mint it elsewhere and expect the same address.
"""
import hashlib
import sys
import zipfile


def sha(b):
    return hashlib.sha256(b).hexdigest()


def main(argv):
    note = ''
    args = []
    it = iter(argv[1:])
    for a in it:
        if a == '--note':
            note = next(it)
        else:
            args.append(a)
    if len(args) < 2:
        sys.stderr.write(__doc__)
        return 2
    if any(ord(c) < 32 or 0x7f <= ord(c) <= 0x9f or ord(c) in (0x2028, 0x2029) for c in note):
        sys.stderr.write('--note must be one line without control or line-separator characters\n')
        return 2
    donor, out, pairs = args[0], args[1], args[2:]
    repl = {}
    for p in pairs:
        name, _, path = p.partition('=')
        if not path or name in repl:
            sys.stderr.write(f'bad or repeated replacement: {p}\n')
            return 2
        repl[name] = open(path, 'rb').read()
    if repl and not note.strip():
        sys.stderr.write('--note is required with a replacement\n')
        return 2
    z = zipfile.ZipFile(donor)
    names = [i.filename for i in z.infolist()]
    if len(set(names)) != len(names):
        sys.stderr.write(f'refusing {donor}: repeated entry name\n')
        return 3
    for i in z.infolist():
        ex, k = i.extra, 0
        while k + 4 <= len(ex):
            hid, ln = int.from_bytes(ex[k:k+2], 'little'), int.from_bytes(ex[k+2:k+4], 'little')
            if hid == 1:
                sys.stderr.write(f'refusing {donor}: {i.filename} has a zip64 extra record\n')
                return 3
            k += 4 + ln
    for n in repl:
        if n == 'PROVENANCE.txt' or n not in names:
            sys.stderr.write(f'refusing replacement {n}: not a replaceable member of {donor}\n')
            return 3
        if sha(repl[n]) == sha(z.read(n)):
            sys.stderr.write(f'refusing replacement {n}: identical to the donor\'s member\n')
            return 3
    prov = z.read('PROVENANCE.txt').decode('utf-8')
    lines = prov.split('\n')
    for n, data in sorted(repl.items()):
        old, new = sha(z.read(n)), sha(data)
        hits = [i for i, l in enumerate(lines)
                if l.split(':')[0].strip() == n and old in l]
        if len(hits) != 1:
            sys.stderr.write(f'PROVENANCE.txt has {len(hits)} lines for {n} naming the donor digest; need exactly 1\n')
            return 3
        lines[hits[0]] = lines[hits[0]].replace(old, new)
    text = '\n'.join(lines)
    if not text.endswith('\n'):
        text += '\n'
    for n, data in sorted(repl.items()):
        text += f'repacked         : {n} {sha(z.read(n))[:16]} -> {sha(data)[:16]} (source sha256 {sha(data)}) {note}\n'
    if repl and not any(l.startswith('repacked-notice') for l in lines):
        text += ('repacked-notice  : the header above (engine revision, built, host out, dart revision) '
                 'describes the donor archive. The files on the repacked lines were substituted from a '
                 'separate build; every other entry is the donor\'s, unchanged.\n')
    with zipfile.ZipFile(out, 'w') as o:
        for i in z.infolist():
            ni = zipfile.ZipInfo(i.filename, i.date_time)
            ni.external_attr = i.external_attr
            ni.compress_type = i.compress_type
            ni.create_system = i.create_system
            ni.internal_attr = i.internal_attr
            ni.extra = i.extra
            if i.filename == 'PROVENANCE.txt':
                data = text.encode('utf-8')
            else:
                data = repl.get(i.filename, None)
                if data is None:
                    data = z.read(i)
            o.writestr(ni, data, compresslevel=9)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
