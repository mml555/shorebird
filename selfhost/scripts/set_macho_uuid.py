#!/usr/bin/env python3
"""Rewrite a Mach-O's LC_UUID in place.

WHY THIS IS NEEDED. The two track clients are copies of one build, so their main
executables carried an identical LC_UUID. iOS's local-network privacy machinery
attributes a connection by executable UUID: with three installed apps sharing
one, it logged `Got local network blocked notification: ... bundle_id: (null)`
and resolved the identity to whichever app it found first. Every app in the
colliding set then failed its local-network connection instantly (~0.2ms, no
round trip), including the base app that had worked before the copies existed.

Only the 16-byte UUID payload changes -- no code, no symbols, no load-command
sizes -- and the bundle is re-signed afterwards, so the signature covers the new
bytes.
"""
import struct
import sys

LC_UUID = 0x1B
MH_MAGIC_64, MH_CIGAM_64 = 0xFEEDFACF, 0xCFFAEDFE
FAT_MAGIC, FAT_CIGAM = 0xCAFEBABE, 0xBEBAFECA


def slices(buf):
    """Yield each Mach-O slice offset, handling fat binaries."""
    magic = struct.unpack('>I', buf[:4])[0]
    if magic in (FAT_MAGIC, FAT_CIGAM):
        nfat = struct.unpack('>I', buf[4:8])[0]
        for i in range(nfat):
            off = 8 + i * 20
            yield struct.unpack('>I', buf[off + 8:off + 12])[0]
    else:
        yield 0


def patch(path, uuid_bytes):
    with open(path, 'rb') as fh:
        buf = bytearray(fh.read())
    patched = 0
    for base in slices(buf):
        magic = struct.unpack('<I', buf[base:base + 4])[0]
        if magic not in (MH_MAGIC_64, MH_CIGAM_64):
            continue
        endian = '<' if magic == MH_MAGIC_64 else '>'
        ncmds = struct.unpack(endian + 'I', buf[base + 16:base + 20])[0]
        off = base + 32
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack(endian + 'II', buf[off:off + 8])
            if cmdsize == 0:
                break
            if cmd == LC_UUID:
                buf[off + 8:off + 24] = uuid_bytes
                patched += 1
            off += cmdsize
    if patched == 0:
        raise SystemExit(f'ERROR: no LC_UUID found in {path}')
    with open(path, 'wb') as fh:
        fh.write(buf)
    return patched


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: set_macho_uuid.py <macho> <32-hex-uuid>')
    hexstr = sys.argv[2].replace('-', '')
    if len(hexstr) != 32:
        raise SystemExit('uuid must be 32 hex chars')
    n = patch(sys.argv[1], bytes.fromhex(hexstr))
    print(f'  patched {n} LC_UUID slice(s) in {sys.argv[1]}')
