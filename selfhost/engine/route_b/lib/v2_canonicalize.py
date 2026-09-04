#!/usr/bin/env python3
# cspell:words canonicalize canonicalization canonicalizer
"""The v2 cell canonicalizer -- ONE authority, used by mint and by verify.

A cell's address is a digest over its members, and some members must CONTAIN
that address: `engine_stamp.json` names it as `git_revision`, and a Maven POM
declares `1.0.0-<address>` as its own version because Gradle validates the POM
body against the requested coordinate. That is only circular if you hash the
rendered bytes. The address is taken over a stage holding a literal `%H`, so
canonicalization is the inverse of rendering: it maps published bytes back to
the template that was addressed.

The rule that makes this safe is that it REFUSES rather than rewrites. A hash
anywhere but the one field this schema permits for that file is a defect --
possibly an attempt to smuggle mutable content past the address -- so it exits
non-zero instead of quietly normalising it away.

    v2_canonicalize.py <file> <hash> [--digest]

Default output is the canonical bytes. `--digest` prints the sha256 hex of
those bytes instead, which is what the manifest holds.

Exit: 0 canonical - 3 refused (hash in a place the schema does not permit)
      2 usage

WHY THIS IS A FILE AND NOT TWO COPIES. mint_route_b_cell.sh and
verify_cell_members.sh each carried their own inlined copy of this logic. They
agreed, but nothing MADE them agree: a rule added to the mint and not to the
verifier would publish cells the verifier then rejects, and -- much worse -- a
rule relaxed in the verifier and not the mint would report a drifted cell as
intact. Adding the POM rule to two places was the point at which that stopped
being acceptable.
"""
import hashlib
import os
import sys


def refuse(name, msg):
    sys.stderr.write(f'{name}: {msg}\n')
    sys.exit(3)


def canonicalize(path, h):
    raw = open(path, 'rb').read()
    name = os.path.basename(path)
    if h.encode() not in raw:
        return raw

    text = raw.decode('utf-8')
    lines = text.split('\n')

    # Where a POM's dependency declarations begin. A POM's project-level
    # <version> and a dependency's <version> are the SAME TEXT once stripped, so
    # matching the line content alone cannot tell them apart -- a hash smuggled
    # into a dependency's version was accepted by exactly that rule until a
    # negative control caught it. Position is the discriminator that content
    # cannot supply.
    dep_at = len(lines)
    if name.endswith('.pom'):
        for i, line in enumerate(lines):
            if '<dependencies' in line:
                dep_at = i
                break

    out = []
    hits = 0
    for idx, line in enumerate(lines):
        if h in line:
            hits += 1
            if name == 'engine_stamp.json':
                # Only as the git_revision value.
                field = f'"git_revision": "{h}"'
                if field not in line:
                    refuse(name, f'{h} outside git_revision')
                line = line.replace(field, '"git_revision": "%H"')
            elif name == 'artifacts_manifest.yaml':
                # Comments only. flutter_engine_revision is the UPSTREAM Flutter
                # base and must never be this hash, so a hit on a data line is a
                # defect.
                if not line.lstrip().startswith('#'):
                    refuse(name, f'{h} on a non-comment line')
                line = line.replace(h, '%H')
            elif name.endswith('.pom'):
                # A Maven POM declares its own coordinate, and Gradle refuses a
                # module whose POM body disagrees with the requested version
                # ("bad version: expected=… found=…"), so the address MUST
                # appear here. Exactly one place is permitted: the project's own
                # top-level <version>, whose value is `1.0.0-<address>`.
                #
                # Deliberately NOT a generic XML rewrite. A POM's dependency
                # blocks carry <version> elements too, and a hash appearing in
                # one of those would mean this cell's identity had leaked into a
                # third-party coordinate -- which must be refused, not
                # normalised. So the permitted occurrence must satisfy BOTH the
                # exact line content AND its position: before <dependencies>,
                # where the project's own coordinate lives. Content alone is not
                # enough, because a dependency's <version> line is the same text.
                #
                # A POM that declared its version AFTER <dependencies> would be
                # refused. That is valid XML and no generator here emits it; a
                # loud refusal is the right answer to a shape this schema has
                # never seen.
                want = f'<version>1.0.0-{h}</version>'
                if line.strip() != want or idx >= dep_at:
                    refuse(name, f'{h} outside the project <version> element')
                line = line.replace(want, '<version>1.0.0-%H</version>')
            else:
                refuse(name, 'no permitted hash-bearing field')
            if h in line:
                refuse(name, 'residual hash after canonicalization')
        out.append(line)

    # Occurrence budget. artifacts_manifest.yaml legitimately names the cell in
    # more than one comment; the other two schemas have exactly ONE field each,
    # so a second hash-bearing line is an unexpected field even when it happens
    # to look like the permitted one.
    if name != 'artifacts_manifest.yaml' and hits != 1:
        refuse(name, f'{hits} hash-bearing lines, exactly 1 permitted')

    return '\n'.join(out).encode('utf-8')


def main(argv):
    args = [a for a in argv[1:] if not a.startswith('--')]
    flags = {a for a in argv[1:] if a.startswith('--')}
    if len(args) != 2 or flags - {'--digest'}:
        sys.stderr.write('usage: v2_canonicalize.py <file> <hash> [--digest]\n')
        return 2
    canon = canonicalize(args[0], args[1])
    if '--digest' in flags:
        sys.stdout.write(hashlib.sha256(canon).hexdigest() + '\n')
    else:
        sys.stdout.buffer.write(canon)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
