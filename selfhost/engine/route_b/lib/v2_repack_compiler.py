#!/usr/bin/env python3
# cspell:words repack repacked
"""Repack a Route B compiler archive with some members replaced, deterministically.

    v2_repack_compiler.py <donor.zip> <out.zip> [NAME=FILE]... [--note TEXT]

Every entry of the donor is carried over IN ITS ORDER with its own timestamp,
mode, extra field and compression, so the only entries whose bytes differ are
the replaced ones and PROVENANCE.txt. PROVENANCE.txt has the digest line of each
replaced member rewritten (and the old digest must match the donor's actual
member, or this refuses) and one `repacked` line appended per replacement.

Deterministic: same donor, same replacements, same note give the same bytes.
It is NOT byte-identical to a donor built by Info-ZIP `zip -y` when nothing is
replaced -- Python's zlib framing and header layout differ -- which is why the
mint reuses the donor's bytes when there is nothing to replace.

Refuses: a name that is not in the donor, PROVENANCE.txt as a replacement, a
replacement identical to the donor's member, or a PROVENANCE digest line that
disagrees with the donor's member.
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
    donor, out, pairs = args[0], args[1], args[2:]
    repl = {}
    for p in pairs:
        name, _, path = p.partition('=')
        if not path or name in repl:
            sys.stderr.write(f'bad or repeated replacement: {p}\n')
            return 2
        repl[name] = open(path, 'rb').read()
    z = zipfile.ZipFile(donor)
    names = [i.filename for i in z.infolist()]
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
        text += f'repacked         : {n} {sha(z.read(n))[:16]} -> {sha(data)[:16]}{(" " + note) if note else ""}\n'
    with zipfile.ZipFile(out, 'w') as o:
        for i in z.infolist():
            ni = zipfile.ZipInfo(i.filename, i.date_time)
            ni.external_attr = i.external_attr
            ni.compress_type = i.compress_type
            ni.create_system = i.create_system
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
