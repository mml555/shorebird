#!/usr/bin/env python3
"""Rewrite a throwaway cell's PROVENANCE.txt for swapped artifacts.

Kept as its own file rather than a heredoc inside the shell loop: the nested
form did not parse, and a provenance rewrite is not a place to be clever.
"""
import hashlib, io, os, re, sys

cell, replaced = sys.argv[1], sys.argv[2]
path = os.path.join(cell, 'PROVENANCE.txt')
text = io.open(path).read()

for pair in replaced.split(','):
    name = pair.split('=', 1)[0]
    with open(os.path.join(cell, name), 'rb') as handle:
        sha = hashlib.sha256(handle.read()).hexdigest()
    text, n = re.subn(
        r'(?m)^(' + re.escape(name) + r'\s*:\s*)[0-9a-f]{64}$',
        lambda m: m.group(1) + sha, text)
    if n != 1:
        raise SystemExit(
            'expected exactly one %s hash line, found %d' % (name, n))
    print('  PROVENANCE updated: %-26s -> %s' % (name, sha[:16]))

banner = (
    'THROWAWAY CELL -- D-SUPER-2B.1c host runs only.\n'
    'Replaced: %s\n'
    'This bundle must never be published or pinned. The only path to a\n'
    'supported cell is publish_route_b_compiler.sh, and 0015 has not earned\n'
    'one: no device qualification, no artifact audit, no coherence check.\n\n'
    % replaced)
io.open(path, 'w').write(banner + text)
