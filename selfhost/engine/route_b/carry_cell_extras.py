#!/usr/bin/env python3
# cspell:words ustar typeflag gname
"""carry_cell_extras.py -- give a re-minted v2 cell its donor's unaddressed files.

mint_cell_v2.sh mints the 30 addressed members of a new cell. The donor's
release also carries files that are NOT part of the address: the debug and
profile Android engines, the host tools (linux-x64, darwin-x64), the Maven
modules for all modes, PROVENANCE.txt. The live CDN serves them under the
cell's path, the release ships them as host-extras-<address>.tar (26 host
files, which bootstrap_selfhost.sh pins by sha256) and as the full overlay in
parts. A cell published with only its 30 members has none of them.

None of those files depends on the Route B analyzer, which is the only thing a
v2 re-mint changes, so the new cell's copies are the donor's bytes under the
new address. This script refuses any extra whose bytes name the donor address,
because renaming its path alone would then be wrong.

  carry_cell_extras.py --donor D --cell C --members OUT_V4 \\
      --descriptor cell_manifests/C.v2 \\
      --donor-parts cell-D.tar.part-aa cell-D.tar.part-ab \\
      --donor-host-extras host-extras-D.tar \\
      --note 'route_b_compiler: ...' --out DIR

Writes into DIR:
  overlay/                    the full overlay for C (rsync it into selfhost/cdn/overlay)
  cell-C.tar.part-a?          the full overlay tar in parts, split as the donor's
  PARTS.sha256, files.sha256  in the donor's formats
  host-extras-C.tar           the donor's host extras under the new address
  full-overlay-C.tar.sha256   the digest of the joined parts

Exit: 0 written and checked, 1 refused, 2 usage.
"""

import argparse
import hashlib
import io
import os
import re
import sys
import tarfile

PART_BYTES = 1992294400  # the donor's part size (GitHub's 2 GiB asset limit)
HEX40 = re.compile(r'^[0-9a-f]{40}$')


def die(msg, code=1):
    sys.stderr.write(f'REFUSED: {msg}\n')
    sys.exit(code)


class Chain(io.RawIOBase):
    """The donor's parts read back to back, as `cat part-*` would."""

    def __init__(self, paths):
        self._files = [open(p, 'rb') for p in paths]
        self._i = 0

    def readable(self):
        return True

    def readinto(self, buf):
        while self._i < len(self._files):
            n = self._files[self._i].readinto(buf)
            if n:
                return n
            self._i += 1
        return 0

    def close(self):
        for f in self._files:
            f.close()
        super().close()


def tar_format(first_block):
    """The donor's tar dialect, so the new tar is written the same way."""
    magic = first_block[257:265]
    typeflag = first_block[156:157]
    if magic == b'ustar  \0' or typeflag in (b'L', b'K'):
        return tarfile.GNU_FORMAT
    if typeflag in (b'x', b'g'):
        return tarfile.PAX_FORMAT
    return tarfile.USTAR_FORMAT


def sniff(path_or_paths):
    paths = path_or_paths if isinstance(path_or_paths, list) else [path_or_paths]
    with open(paths[0], 'rb') as f:
        return tar_format(f.read(512))


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def norm(name):
    return name[2:] if name.startswith('./') else name


def renamed(ti, donor, cell):
    new = ti.name.replace(donor, cell)
    if ti.isfile() and donor not in ti.name:
        die(f'{ti.name}: a file outside the donor address; this script only renames')
    if ti.issym() or ti.islnk():
        die(f'{ti.name}: links are not expected in a cell overlay')
    copy = tarfile.TarInfo(new)
    for attr in ('mode', 'mtime', 'uid', 'gid', 'uname', 'gname', 'type'):
        setattr(copy, attr, getattr(ti, attr))
    return copy


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--donor', required=True)
    ap.add_argument('--cell', required=True)
    ap.add_argument('--members', required=True, help="the new cell's minted overlay (30 members)")
    ap.add_argument('--descriptor', required=True, help='cell_manifests/<cell>.v2')
    ap.add_argument('--donor-parts', nargs='+', required=True)
    ap.add_argument('--donor-host-extras', required=True)
    ap.add_argument('--note', required=True, help='line appended to PROVENANCE.txt')
    ap.add_argument('--out', required=True)
    a = ap.parse_args()

    D, C = a.donor, a.cell
    if not (HEX40.match(D) and HEX40.match(C)) or D == C:
        die('--donor and --cell must be two different 40-hex addresses', 2)
    descriptor = open(a.descriptor, 'rb').read()
    if sha256(descriptor)[:40] != C:
        die(f'{a.descriptor} does not authenticate {C}')
    if os.path.exists(a.out):
        die(f'{a.out} exists; give a fresh --out')
    if '\n' in a.note:
        die('--note is one line', 2)

    members = {}
    for root, _, files in os.walk(a.members):
        for fn in files:
            p = os.path.join(root, fn)
            rel = os.path.relpath(p, a.members)
            if fn.startswith('._') or fn == '.DS_Store':
                die(f'{rel}: macOS metadata in --members')
            members[rel] = p
    if len(members) != 30:
        die(f'--members holds {len(members)} files, not the 30 members of a v2 cell')
    if any(C not in rel for rel in members):
        die('--members holds a file outside the new address')

    overlay = os.path.join(a.out, 'overlay')
    os.makedirs(overlay)
    full_path = os.path.join(a.out, f'full-overlay-{C}.tar')
    used, files_sha, extras = set(), [], 0
    donor_manifest = f'download.shorebird.dev/shorebird/cell-manifests/{D}.v2'
    provenance = f'download.shorebird.dev/shorebird/{D}/PROVENANCE.txt'

    def place(rel, data, mode):
        dst = os.path.join(overlay, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, 'wb') as f:
            f.write(data)
        os.chmod(dst, mode & 0o777)

    fmt = sniff(a.donor_parts)
    src = io.BufferedReader(Chain(a.donor_parts), 1 << 20)
    with tarfile.open(fileobj=src, mode='r|') as tin, \
            tarfile.open(full_path, 'w', format=fmt) as tout:
        for ti in tin:
            new = renamed(ti, D, C)
            if not ti.isfile():
                tout.addfile(new)
                continue
            data = tin.extractfile(ti).read()
            old_rel, rel = norm(ti.name), norm(new.name)
            if rel in members:
                data = open(members[rel], 'rb').read()
                used.add(rel)
            elif old_rel == donor_manifest:
                data = descriptor
            elif old_rel == provenance:
                if not data.endswith(b'\n'):
                    data += b'\n'
                data += f'carried_to:               {C} by carry_cell_extras.py: {a.note}\n'.encode()
                extras += 1
            else:
                if D.encode() in data:
                    die(f'{old_rel}: its bytes name the donor address; renaming the path is not enough')
                extras += 1
            new.size = len(data)
            tout.addfile(new, io.BytesIO(data))
            place(rel, data, ti.mode)
            files_sha.append((sha256(data), rel))

    missing = sorted(set(members) - used)
    if missing:
        die('members the donor overlay has no path for: ' + ', '.join(missing))
    man_rel = f'download.shorebird.dev/shorebird/cell-manifests/{C}.v2'
    if not os.path.exists(os.path.join(overlay, man_rel)):
        place(man_rel, descriptor, 0o644)  # served live; the donor's parts may not carry it

    # The host extras: the donor's tar, renamed, every file byte-equal to the
    # overlay's copy (which is the donor's bytes).
    he_path = os.path.join(a.out, f'host-extras-{C}.tar')
    he_count = 0
    with tarfile.open(a.donor_host_extras, 'r') as tin, \
            tarfile.open(he_path, 'w', format=sniff(a.donor_host_extras)) as tout:
        for ti in tin:
            new = renamed(ti, D, C)
            if not ti.isfile():
                tout.addfile(new)
                continue
            rel = norm(new.name)
            if rel in members:
                die(f'{rel}: a host extra that is an addressed member')
            data = tin.extractfile(ti).read()
            ours = os.path.join(overlay, rel)
            if not os.path.exists(ours) or open(ours, 'rb').read() != data:
                die(f'{rel}: the host extra differs from the full overlay copy')
            new.size = len(data)
            tout.addfile(new, io.BytesIO(data))
            he_count += 1

    # Split as the donor did, and record digests in the donor's formats.
    full_sha = hashlib.sha256()
    parts = []
    with open(full_path, 'rb') as f:
        i = 0
        while True:
            chunk = f.read(PART_BYTES)
            if not chunk:
                break
            full_sha.update(chunk)
            name = f'cell-{C}.tar.part-a{chr(ord("a") + i)}'
            with open(os.path.join(a.out, name), 'wb') as p:
                p.write(chunk)
            parts.append((sha256(chunk), name))
            i += 1
    os.remove(full_path)
    with open(os.path.join(a.out, 'PARTS.sha256'), 'w') as f:
        f.writelines(f'{h}  {n}\n' for h, n in parts)
    with open(os.path.join(a.out, 'files.sha256'), 'w') as f:
        f.writelines(f'{h}  {n}\n' for h, n in sorted(files_sha, key=lambda x: x[1]))
    with open(os.path.join(a.out, f'full-overlay-{C}.tar.sha256'), 'w') as f:
        f.write(f'{full_sha.hexdigest()}  full-overlay-{C}.tar\n')

    he_sha = sha256(open(he_path, 'rb').read())
    print(f'cell            {C} (from donor {D})')
    print(f'overlay files   {len(files_sha)} in the parts: 30 members, {extras} extras'
          f'{", descriptor" if len(files_sha) - 30 - extras else ""}')
    print(f'host extras     {he_count} files, host-extras-{C}.tar sha256 {he_sha}'
          f' ({os.path.getsize(he_path)} B)')
    for h, n in parts:
        print(f'part            {n} sha256 {h} ({os.path.getsize(os.path.join(a.out, n))} B)')
    print(f'full overlay    sha256 {full_sha.hexdigest()}')
    print('CARRIED')


if __name__ == '__main__':
    main()
