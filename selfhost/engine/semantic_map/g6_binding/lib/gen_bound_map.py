#!/usr/bin/env python3
"""Build a semantic map BOUND to exactly one release.

The map describes one release, so every identity it is bound to is read from
that release's own artifacts -- never passed in as an assertion.

BINDING FIELDS (#55):
    schema_version
    release_id
    release_kernel_hash
    release_aot_identity            sha256 AND the GNU build id
    flutter_dart_compiler_identities
    generator_identity
    digest

WHY sha256 AND NOT the GNU build id. SM1-G5 measured that a GNU build id hashes
only four snapshot text/rodata segments, so two different AOTs can share one.
The build id is recorded because it is what the running program can report, but
identity is the artifact digest. The falsification includes an arm where the
build id matches and the digest does not.

usage: gen_bound_map.py <schema-version> <release-name> <kernel> <aot> \
           <g1-rows.json> <manifest.json> <tools-dir> <out.json>
"""
import hashlib
import json
import pathlib
import struct
import sys

SCHEMA_VERSION = int(sys.argv[1])
NAME, KERNEL, AOT, G1, MANIFEST, TOOLS, OUT = sys.argv[2:9]


def sha(p):
    return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()


def gnu_build_id(path):
    """Read .note.gnu.build-id out of the ELF, or None.

    Recorded, never trusted as identity -- see the module docstring.
    """
    b = pathlib.Path(path).read_bytes()
    if len(b) < 64 or b[:4] != b'\x7fELF' or b[4] != 2 or b[5] != 1:
        return None
    shoff = struct.unpack_from('<Q', b, 0x28)[0]
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 0x3a)
    if shoff == 0 or shnum == 0 or shstrndx >= shnum:
        return None
    strhdr = shoff + shstrndx * shentsize
    stroff, strsz = struct.unpack_from('<Q', b, strhdr + 0x18)[0], \
        struct.unpack_from('<Q', b, strhdr + 0x20)[0]
    for i in range(shnum):
        h = shoff + i * shentsize
        nameidx = struct.unpack_from('<I', b, h)[0]
        if nameidx >= strsz:
            continue
        s = stroff + nameidx
        e = b.find(b'\x00', s, stroff + strsz)
        if e < 0 or b[s:e] != b'.note.gnu.build-id':
            continue
        off, size = struct.unpack_from('<Q', b, h + 0x18)[0], \
            struct.unpack_from('<Q', b, h + 0x20)[0]
        if off + size > len(b) or size < 12:
            return None
        nsz, dsz = struct.unpack_from('<I', b, off)[0], \
            struct.unpack_from('<I', b, off + 4)[0]
        start = off + 12 + ((nsz + 3) & ~3)
        return b[start:start + dsz].hex()
    return None


def canonical(obj):
    """Canonical bytes for digesting: sorted keys, no incidental whitespace."""
    return json.dumps(obj, sort_keys=True, separators=(',', ':')).encode()


man = json.load(open(MANIFEST))
g1 = json.load(open(G1))

kernel_hash = sha(KERNEL)
aot_sha = sha(AOT)

body = {
    'schema': 'semantic-map-1/bound-map/1',
    'schema_version': SCHEMA_VERSION,
    # An opaque id for the release, DERIVED from the two artifacts it names, so
    # it cannot silently disagree with them -- but still an independent field,
    # because #55 requires every binding field to be swappable on its own.
    'release_id': hashlib.sha256(
        f'{NAME}|{kernel_hash}|{aot_sha}'.encode()).hexdigest(),
    'release_name': NAME,
    'release_kernel_hash': kernel_hash,
    'release_aot_identity': {
        'sha256': aot_sha,
        'gnu_build_id': gnu_build_id(AOT),
        'identity_field': 'sha256',
        'why': 'a GNU build id hashes only four snapshot segments, so two '
               'different AOTs can share one; it is recorded, not trusted',
    },
    'flutter_dart_compiler_identities': {
        'dart_revision': man['base']['dart_revision'],
        'frozen_effective_tree': man['base']['frozen_effective_tree'],
        'gen_snapshot_sha256':
            man['built']['instrumented_gen_snapshot_sha256_schema6'],
    },
    'generator_identity': {
        'generator': 'g6_binding/lib/gen_bound_map.py',
        'generator_sha256': sha(__file__),
        'tools': {p.name: sha(p) for p in sorted(pathlib.Path(TOOLS).iterdir())
                  if p.is_file() and p.suffix in ('.py', '.dart')},
    },
    'declarations': [
        {'declaration_id': r['declaration_id'], 'library': r['library'],
         'owner': r.get('owner'), 'kind': r['kind'], 'name': r['name']}
        for r in g1['rows']
    ],
}
body['digest'] = hashlib.sha256(canonical(body)).hexdigest()
json.dump(body, open(OUT, 'w'), indent=2)
print(f"  {NAME}: schema_version={SCHEMA_VERSION} "
      f"declarations={len(body['declarations'])}")
print(f"    release_id  {body['release_id']}")
print(f"    kernel      {kernel_hash}")
print(f"    aot sha256  {aot_sha}")
print(f"    build id    {body['release_aot_identity']['gnu_build_id']}")
print(f"    digest      {body['digest']}")
