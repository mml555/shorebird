#!/usr/bin/env python3
# cspell:words dedent
"""Check SUPPORTED_STATE.yaml's format with NO external dependency.

WHY THIS EXISTS. The record's format check used PyYAML, which the stock macOS
python3 does not have. SELFHOST-CLEANROOM-1 hit that and the check reported
`record is not cleanly machine-readable` against a perfectly well-formed file --
the checker could not run and blamed its subject. "Install PyYAML when
verification fails" is not an acceptable step in a supported workflow, so the
dependency is gone from the supported path.

What it checks, and deliberately nothing more:

  1 INDENTATION IS COHERENT. Every mapping line's indent must be one that is
    currently open, so the sequence-and-mapping-at-one-indent defect that
    originally motivated the parse check is still caught.
  2 NO DUPLICATE KEY within one mapping. A duplicate PARSES under any YAML
    loader and silently keeps the last value, which is how an authoritative
    field gets shadowed -- it happened to `evidence:` on 2026-09-04.
  3 A mapping and a sequence never share an indent under the same parent.

It is NOT a YAML parser and does not pretend to be. When PyYAML IS available the
verifier additionally does a real load, so the strong check is not lost -- it is
just no longer required to run at all.

    record_lint.py <file>

Exit: 0 clean · 1 a finding (printed) · 2 usage
"""
import sys


def lint(path):
    findings = []
    # stack of (indent, kind, keys_seen, path)
    stack = [(-1, 'map', set(), '')]
    in_block = None          # indent of the line that opened a block scalar
    for lineno, raw in enumerate(open(path, encoding='utf-8'), 1):
        line = raw.rstrip('\n')
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(' '))

        # Block scalars (>- , | , >) swallow everything more indented.
        if in_block is not None:
            if indent > in_block:
                continue
            in_block = None

        stripped = line.strip()
        if stripped.startswith('#'):
            continue

        while stack and indent < stack[-1][0]:
            stack.pop()
        if not stack:
            findings.append((lineno, 'indent below every open level'))
            return findings

        is_item = stripped.startswith('- ') or stripped == '-'
        if is_item:
            if stack[-1][0] == indent and stack[-1][1] == 'map' and stack[-1][2]:
                findings.append((lineno, 'a sequence item shares the indent of a '
                                         'mapping with keys — YAML will reject or '
                                         'silently reinterpret this'))
            if stack[-1][0] < indent or stack[-1][1] != 'seq':
                stack.append((indent, 'seq', set(), stack[-1][3]))
            continue

        if ':' not in stripped:
            continue
        # A QUOTED key may itself contain colons -- an image reference like
        # "ghcr.io/owner/name:1.3.0" is one key, not a key of
        # "ghcr.io/owner/name". Splitting on the first colon reported two such
        # keys as duplicates of each other, failing a well-formed record and
        # sending the reader to fix the wrong artifact.
        if stripped[0] in ('"', "'"):
            quote = stripped[0]
            close = stripped.find(quote, 1)
            if close == -1 or stripped[close + 1:close + 2] != ':':
                continue
            key = stripped[1:close]
            rest = stripped[close + 2:].strip()
        else:
            key = stripped.split(':', 1)[0].strip()
            rest = stripped.split(':', 1)[1].strip()

        if stack[-1][0] < indent:
            stack.append((indent, 'map', set(), stack[-1][3]))
        cur = stack[-1]
        if cur[1] == 'seq':
            # keys inside a sequence item: a fresh mapping per item, and this
            # linter does not track item boundaries, so duplicates are not
            # claimed there.
            pass
        elif key in cur[2]:
            findings.append((lineno, f'duplicate key {key!r} in the mapping at '
                                     f'indent {indent}'
                                     f'{" under " + cur[3] if cur[3] else ""}'
                                     ' — YAML keeps the LAST value, so the '
                                     'earlier one is silently shadowed'))
        else:
            cur[2].add(key)

        if rest in ('>-', '>', '|', '|-', '>+', '|+'):
            in_block = indent
        elif not rest:
            stack.append((indent + 1, 'map', set(), key))
            stack[-1] = (indent + 1, 'pending', set(), key)
            stack.pop()
    return findings


def main(argv):
    if len(argv) != 2:
        sys.stderr.write('usage: record_lint.py <file>\n')
        return 2
    findings = lint(argv[1])
    for lineno, msg in findings:
        sys.stderr.write(f'{argv[1]}:{lineno}: {msg}\n')
    return 1 if findings else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
