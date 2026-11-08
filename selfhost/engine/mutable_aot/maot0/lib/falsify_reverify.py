#!/usr/bin/env python3
"""Falsify the content-vs-stamp split in reverify_universe.py, both ways.

Separating the provenance stamp from the universe content only counts as a
correction rather than a loosening if the content check still bites. Each arm
below edits the frozen universe TEXTUALLY -- re-serialising the JSON would
change every byte and make every arm "differ" for the wrong reason, which is
how the first attempt at this check fooled itself.

usage: falsify_reverify.py <maot0-dir>
exit 0 iff every arm behaves as stated.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

ARMS = [
    ('untouched copy', 'identical', 0),
    ('stamp differs, content identical', 'identical', 0),
    ('one entry renamed, stamp identical', 'DIFFERS', 1),
    ('stamp malformed, content identical', 'DIFFERS', 1),
    ('stamp differs AND content differs', 'DIFFERS', 1),
]
FILES = ('kernel_declarations.json', 'vm_runtime_state.json')


def main(argv):
    here = os.path.abspath(argv[1] if len(argv) > 1 else '.')
    frozen = os.path.join(here, 'universe')
    script = os.path.join(here, 'lib', 'reverify_universe.py')
    head = json.load(open(os.path.join(frozen, FILES[0])))[
        'provenance']['dart_tree_head']
    entry = json.load(open(os.path.join(frozen, FILES[0])))['entries'][0]
    name = next(v for v in entry.values() if isinstance(v, str))

    tmp = tempfile.mkdtemp(prefix='maot0_rv_')
    ok = True
    try:
        def fresh():
            for f in FILES:
                shutil.copy(os.path.join(frozen, f), os.path.join(tmp, f))

        def edit(f, old, new):
            p = os.path.join(tmp, f)
            t = open(p).read()
            assert old in t, f'{old!r} not in {f}'
            open(p, 'w').write(t.replace(old, new, 1))

        def run():
            p = subprocess.run(
                [sys.executable, script, tmp, frozen] + list(FILES),
                capture_output=True, text=True)
            return p.returncode, p.stdout.strip()

        setups = [
            lambda: None,
            lambda: edit(FILES[0], head, 'a' * 40),
            lambda: edit(FILES[0], f'"{name}"', '"ZZZ_RENAMED"'),
            lambda: edit(FILES[0], head, 'not-a-sha'),
            lambda: (edit(FILES[0], head, 'b' * 40),
                     edit(FILES[0], f'"{name}"', '"ZZZ_RENAMED"')),
        ]
        for (label, want_content, want_rc), setup in zip(ARMS, setups):
            fresh()
            setup()
            rc, out = run()
            got = 'identical' if f'{FILES[0]} content:identical' in out \
                else 'DIFFERS'
            good = (got == want_content and rc == want_rc)
            ok = ok and good
            print(f'  {"pass" if good else "FAIL"}  {label}: '
                  f'content={got} rc={rc} (want {want_content}/{want_rc})')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
