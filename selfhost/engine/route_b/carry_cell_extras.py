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
new address. An extra whose bytes name the donor address (its full address or
its 8-character short form, also inside zip and jar entries) is refused,
because renaming its path alone would then be wrong.

  carry_cell_extras.py --donor D --cell C --members OUT_V4 \\
      --descriptor cell_manifests/C.v2 \\
      --donor-parts cell-D.tar.part-aa cell-D.tar.part-ab \\
      --donor-parts-sha256 PARTS.sha256 --donor-files-sha256 files.sha256 \\
      --donor-host-extras host-extras-D.tar \\
      --note 'route_b_compiler: ...' --out DIR

Every input is checked before it is used: the parts against the donor's
PARTS.sha256, every donor file against its files.sha256 (all of them must be
seen), the members against the descriptor's path and sha256 lines, and the
descriptor against the new address.

Writes into DIR (built as DIR.partial, renamed on success, removed on failure):
  overlay/                    the full overlay for C (rsync it into selfhost/cdn/overlay)
  cell-C.tar.part-a?          the full overlay tar in parts, split as the donor's
  PARTS.sha256, files.sha256  in the donor's formats
  host-extras-C.tar           the donor's host extras under the new address
  full-overlay-C.tar.sha256   the digest of the joined parts

As in the donor's release, the descriptor (cell-manifests/C.v2) is in overlay/
because the CDN serves it, but not in the parts. PROVENANCE.txt keeps the
donor's text, which describes the engine build, and gains a section that lists
this cell's own files and digests. Modes are normalized: directories 0755,
files 0755 when the donor's copy was executable, else 0644.

Exit: 0 written and checked, 1 refused, 2 usage.
"""

import argparse
import hashlib
import io
import os
import re
import shutil
import sys
import tarfile
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib'))
from v2_canonicalize import canonicalize  # noqa: E402  the mint's and verifier's one rule

PART_BYTES = 1992294400  # the donor's part size (GitHub's 2 GiB asset limit)
HEX40 = re.compile(r'^[0-9a-f]{40}$')


class Refused(Exception):
    pass


def die(msg):
    raise Refused(msg)


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


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def read_sums(path):
    """`<sha256>  <name>` lines, as shasum writes them."""
    sums = {}
    for line in open(path):
        if not line.strip():
            continue
        h, name = line.rstrip('\n').split(None, 1)
        name = name.lstrip('*')
        if name in sums:
            die(f'{path}: {name} listed twice')
        sums[name] = h
    return sums


def safe_rel(name):
    rel = name[2:] if name.startswith('./') else name
    rel = rel.rstrip('/')
    parts = rel.split('/')
    if not rel or rel.startswith('/') or any(p in ('', '.', '..') for p in parts):
        die(f'{name!r}: not a plain relative path')
    return rel


def mode_for(ti):
    if ti.isdir():
        return 0o755
    return 0o755 if ti.mode & 0o111 else 0o644


def names_donor(data, rel, needles):
    """Does this file name the donor, in its bytes or inside a zip/jar entry?"""
    if any(n in data for n in needles):
        return 'its bytes'
    if rel.endswith(('.zip', '.jar')):
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                for info in z.infolist():
                    if any(n in info.filename.encode() for n in needles):
                        return f'entry name {info.filename}'
                    with z.open(info) as e:
                        tail = b''
                        for chunk in iter(lambda: e.read(1 << 20), b''):
                            window = tail + chunk
                            if any(n in window for n in needles):
                                return f'entry {info.filename}'
                            tail = window[-64:]
        except zipfile.BadZipFile:
            return 'an unreadable zip'
    return None


def new_info(ti, rel, size):
    out = tarfile.TarInfo(rel + ('/' if ti.isdir() and ti.name.endswith('/') else ''))
    out.type = ti.type
    out.mode = mode_for(ti)
    for attr in ('mtime', 'uid', 'gid', 'uname', 'gname'):
        setattr(out, attr, getattr(ti, attr))
    out.size = size
    return out


def check_entry(ti, seen, where):
    if ti.issparse() or not (ti.isfile() or ti.isdir()):
        die(f'{where}: {ti.name}: only regular files and directories are expected')
    rel = safe_rel(ti.name)
    if rel in seen:
        die(f'{where}: {rel} appears twice')
    seen.add(rel)
    return rel


def carry(a, out):
    D, C = a.donor, a.cell
    needles = (D.encode(), D[:8].encode())

    descriptor = open(a.descriptor, 'rb').read()
    if sha256(descriptor)[:40] != C:
        die(f'{a.descriptor} does not authenticate {C}')
    want = {}
    for line in descriptor.decode().splitlines():
        f = line.split()
        if len(f) == 2 and '%H' in f[0]:
            want[f[0].replace('%H', C)] = f[1]
    if len(want) != 30:
        die(f'the descriptor lists {len(want)} members, not 30')

    members = {}
    for root, _, files in os.walk(a.members):
        for fn in files:
            p = os.path.join(root, fn)
            members[os.path.relpath(p, a.members)] = p
    if set(members) != set(want):
        die('--members does not hold exactly the descriptor\'s 30 paths: '
            f'missing {sorted(set(want) - set(members))}, extra {sorted(set(members) - set(want))}')
    # The descriptor hashes a member with the address put back as %H, by the
    # same rule the mint and verify_cell_members.sh use.
    member_sha = {}
    for rel, p in members.items():
        if sha256(canonicalize(p, C)) != want[rel]:
            die(f'{rel}: member bytes differ from the descriptor')
        member_sha[rel] = sha256_file(p)

    part_sums = read_sums(a.donor_parts_sha256)
    if sorted(part_sums) != sorted(os.path.basename(p) for p in a.donor_parts):
        die('--donor-parts must be exactly the parts PARTS.sha256 lists')
    a.donor_parts.sort(key=os.path.basename)
    for p in a.donor_parts:
        if sha256_file(p) != part_sums[os.path.basename(p)]:
            die(f'{p}: does not match PARTS.sha256')
    donor_files = read_sums(a.donor_files_sha256)

    donor_manifest = f'download.shorebird.dev/shorebird/cell-manifests/{D}.v2'
    prov_old = f'download.shorebird.dev/shorebird/{D}/PROVENANCE.txt'
    prov_new = prov_old.replace(D, C)
    if prov_old not in donor_files:
        die('the donor has no PROVENANCE.txt to carry')

    # The new cell's file list is known before streaming: the donor's, renamed,
    # with the members' digests. The stream must then agree with it.
    expect = {}
    for name, h in donor_files.items():
        rel = safe_rel(name)
        if D not in rel:
            die(f'{rel}: a donor file outside the donor address; this script only renames')
        expect[rel.replace(D, C)] = member_sha.get(rel.replace(D, C), h)
    if not set(want) <= set(expect):
        die('members the donor overlay has no path for: ' + ', '.join(sorted(set(want) - set(expect))))
    listing = ''.join(f'                          {h}  {n}\n'
                      for n, h in sorted(expect.items()) if n != prov_new)

    overlay = os.path.join(out, 'overlay')
    os.makedirs(overlay)

    def place(rel, data, mode):
        dst = os.path.join(overlay, rel)
        os.makedirs(os.path.dirname(dst), mode=0o755, exist_ok=True)
        with open(dst, 'wb') as f:
            f.write(data)
        os.chmod(dst, mode)

    full_path = os.path.join(out, f'full-overlay-{C}.tar')
    seen, got, extras = set(), {}, 0
    src = io.BufferedReader(Chain(a.donor_parts), 1 << 20)
    with tarfile.open(fileobj=src, mode='r|') as tin, \
            tarfile.open(full_path, 'w', format=tarfile.USTAR_FORMAT) as tout:
        for ti in tin:
            old = check_entry(ti, seen, 'donor parts')
            rel = old.replace(D, C)
            if ti.isdir():
                tout.addfile(new_info(ti, rel, 0))
                continue
            data = tin.extractfile(ti).read()
            if donor_files.get(old) != sha256(data):
                die(f'{old}: not the bytes the donor\'s files.sha256 lists')
            if old == donor_manifest:
                die('the donor parts carry the descriptor; this script expects them not to')
            if rel in members:
                data = open(members[rel], 'rb').read()
            elif old == prov_old:
                if not data.endswith(b'\n'):
                    data += b'\n'
                data += (f'carried_to:               {C} by carry_cell_extras.py from {D}: {a.note}\n'
                         f'                          The text above describes the engine build and the donor.\n'
                         f'files at {C[:8]} (sha256): every other file in this cell\'s overlay parts\n'
                         + listing).encode()
                extras += 1
            else:
                why = names_donor(data, old, needles)
                if why:
                    die(f'{old}: {why} names the donor address; renaming the path is not enough')
                extras += 1
            tout.addfile(new_info(ti, rel, len(data)), io.BytesIO(data))
            place(rel, data, mode_for(ti))
            got[rel] = sha256(data)

    missing = sorted(set(expect) - set(got))
    if missing:
        die(f'{len(missing)} donor files never arrived (truncated parts?): {missing[:3]}')
    for rel, h in got.items():
        if rel != prov_new and expect[rel] != h:
            die(f'{rel}: written bytes differ from the planned list')
    if extras != len(expect) - 30:
        die(f'{extras} extras, expected {len(expect) - 30}')
    place(f'download.shorebird.dev/shorebird/cell-manifests/{C}.v2', descriptor, 0o644)

    # The host extras: the donor's tar, renamed, every file byte-equal to the
    # overlay's copy (which is the donor's bytes).
    he_path = os.path.join(out, f'host-extras-{C}.tar')
    he_count, he_seen = 0, set()
    with tarfile.open(a.donor_host_extras, 'r') as tin, \
            tarfile.open(he_path, 'w', format=tarfile.USTAR_FORMAT) as tout:
        for ti in tin:
            old = check_entry(ti, he_seen, 'donor host extras')
            rel = old.replace(D, C)
            if ti.isdir():
                tout.addfile(new_info(ti, rel, 0))
                continue
            if rel in members:
                die(f'{rel}: a host extra that is an addressed member')
            data = tin.extractfile(ti).read()
            if got.get(rel) != sha256(data):
                die(f'{rel}: the host extra differs from the full overlay copy')
            tout.addfile(new_info(ti, rel, len(data)), io.BytesIO(data))
            he_count += 1
    if he_count != a.host_extras_count:
        die(f'{he_count} host extras, expected {a.host_extras_count}')

    # Split as the donor did, and record digests in the donor's formats.
    full_sha = hashlib.sha256()
    parts = []
    with open(full_path, 'rb') as f:
        for i in range(26):
            chunk = f.read(PART_BYTES)
            if not chunk:
                break
            full_sha.update(chunk)
            name = f'cell-{C}.tar.part-a{chr(ord("a") + i)}'
            with open(os.path.join(out, name), 'wb') as p:
                p.write(chunk)
            parts.append((sha256(chunk), name))
        else:
            die('more than 26 parts')
    os.remove(full_path)
    with open(os.path.join(out, 'PARTS.sha256'), 'w') as f:
        f.writelines(f'{h}  {n}\n' for h, n in parts)
    with open(os.path.join(out, 'files.sha256'), 'w') as f:
        f.writelines(f'{h}  {n}\n' for n, h in sorted(got.items()))
    with open(os.path.join(out, f'full-overlay-{C}.tar.sha256'), 'w') as f:
        f.write(f'{full_sha.hexdigest()}  full-overlay-{C}.tar\n')

    he_sha = sha256_file(he_path)
    return [
        f'cell            {C} (from donor {D})',
        f'overlay files   {len(got)} in the parts: 30 members, {extras} extras; descriptor in overlay/ only',
        f'host extras     {he_count} files, host-extras-{C}.tar sha256 {he_sha} ({os.path.getsize(he_path)} B)',
        *[f'part            {n} sha256 {h} ({os.path.getsize(os.path.join(out, n))} B)' for h, n in parts],
        f'full overlay    sha256 {full_sha.hexdigest()}',
    ]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--donor', required=True)
    ap.add_argument('--cell', required=True)
    ap.add_argument('--members', required=True, help="the new cell's minted overlay (30 members)")
    ap.add_argument('--descriptor', required=True, help='cell_manifests/<cell>.v2')
    ap.add_argument('--donor-parts', nargs='+', required=True)
    ap.add_argument('--donor-parts-sha256', required=True, help="the donor release's PARTS.sha256")
    ap.add_argument('--donor-files-sha256', required=True, help="the donor release's files.sha256")
    ap.add_argument('--donor-host-extras', required=True)
    ap.add_argument('--host-extras-count', type=int, default=26)
    ap.add_argument('--note', required=True, help='line appended to PROVENANCE.txt')
    ap.add_argument('--out', required=True)
    a = ap.parse_args()

    if not (HEX40.match(a.donor) and HEX40.match(a.cell)) or a.donor == a.cell:
        ap.error('--donor and --cell must be two different 40-hex addresses')
    if '\n' in a.note:
        ap.error('--note is one line')
    out = a.out.rstrip('/')
    tmp = out + '.partial'
    if os.path.exists(out) or os.path.exists(tmp):
        ap.error(f'{out} or {tmp} exists; give a fresh --out')
    os.umask(0o022)
    os.makedirs(tmp)
    try:
        summary = carry(a, tmp)
    except Refused as e:
        shutil.rmtree(tmp, ignore_errors=True)
        sys.stderr.write(f'REFUSED: {e}\n')
        sys.exit(1)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    os.rename(tmp, out)
    print('\n'.join(summary))
    print('CARRIED')


if __name__ == '__main__':
    main()
