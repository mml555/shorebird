#!/usr/bin/env python3
"""MAOT-0 re-derivation check: separate universe CONTENT from the provenance
stamp of the tree it was read from.

Byte-comparing the whole file conflates two different facts:

  * the universe changed -- new or removed declarations, so the frozen matrix
    no longer describes the language surface it claims to cover; and
  * the universe was read from a different commit -- the content may be
    word-for-word the same.

The first is a defect. The second is an observation, and when the content is
identical it is a STRONGER statement than the freeze made on its own: the
universe is unchanged ACROSS those two commits. Reporting the second as the
first is how a borrowed build rig reads as a language-surface change.

Everything except the single `dart_tree_head` token is still compared byte for
byte.

usage: reverify_universe.py <derived-dir> <frozen-dir> <file> [<file>...]
prints one line per file:  <file> <content:identical|DIFFERS> <tree:same|SHA>
exit 0 iff every file's CONTENT is identical.
"""
import json
import os
import re
import sys

HEX40 = re.compile(r'\b[0-9a-f]{40}\b')


def head_of(path):
    try:
        return json.load(open(path)).get('provenance', {}).get('dart_tree_head')
    except Exception:
        return None


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        return 2
    derived, frozen, files = argv[1], argv[2], argv[3:]
    ok = True
    for f in files:
        derived_path = os.path.join(derived, f)
        frozen_path = os.path.join(frozen, f)
        if not (os.path.exists(derived_path) and os.path.exists(frozen_path)):
            print(f'{f} content:ABSENT tree:unknown')
            ok = False
            continue
        derived_text = open(derived_path).read()
        frozen_text = open(frozen_path).read()
        derived_head = head_of(derived_path)
        frozen_head = head_of(frozen_path)
        tree = ('same' if derived_head == frozen_head
                else (derived_head or 'unknown'))
        # Normalize ONLY the stamp, and only when both are present and
        # well-formed, so a malformed or missing head cannot be normalized
        # into agreement.
        if (derived_head and frozen_head and HEX40.fullmatch(derived_head)
                and HEX40.fullmatch(frozen_head) and derived_head != frozen_head):
            derived_text = derived_text.replace(
                f'"{derived_head}"', f'"{frozen_head}"')
        same = derived_text == frozen_text
        ok = ok and same
        print(f'{f} content:{"identical" if same else "DIFFERS"} tree:{tree}')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
