#!/usr/bin/env python3
"""Produce a weakened binding verifier, for the sensitivity control.

Two modes:
  bind     -- the release-binding comparisons are removed, so any map binds to
              any release. Every identity swap arm must then fail.
  digest   -- the digest check is removed, so a tampered map binds. The
              integrity arms must then fail.

The transformation is asserted: if the anchor is not found exactly once, this
refuses rather than emitting a copy identical to the real verifier.

usage: weaken_verifier.py <verify_binding.py> <out.py> <bind|digest>
"""
import pathlib
import sys

SRC, OUT, MODE = sys.argv[1:4]
src = pathlib.Path(SRC).read_text()

if MODE == 'bind':
    anchor = "        elif got != want:"
    repl = "        elif False:  # WEAKENED: binding comparison removed"
elif MODE == 'digest':
    anchor = "        if recomputed != declared:"
    repl = "        if False:  # WEAKENED: digest comparison removed"
else:
    sys.exit(f'weaken_verifier: unknown mode {MODE!r}')

if src.count(anchor) != 1:
    sys.exit(f'weaken_verifier: anchor for {MODE!r} occurs '
             f'{src.count(anchor)} times, expected exactly 1')
weak = src.replace(anchor, repl, 1)
if weak == src:
    sys.exit('weaken_verifier: output identical to input')
pathlib.Path(OUT).write_text(weak)
print(f'  weakened verifier written: {MODE}')
