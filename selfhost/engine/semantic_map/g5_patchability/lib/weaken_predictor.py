#!/usr/bin/env python3
"""Produce the weakened predictor used as the dispatch-predicate control.

Deleting a block by string surgery is only a valid control if the surgery is
PROVEN to have found the intended block. A transformation that silently matched
nothing would leave the "control" identical to the real predictor, and every
arm would keep passing -- a control that cannot fail.

So this asserts: the anchor occurs exactly once, both decision-path reason
codes disappear while the vocabulary entries remain, and the output differs
from the input.

usage: weaken_predictor.py <predict_patchable.dart> <out.dart>
"""
import pathlib
import sys

SRC, OUT = sys.argv[1], sys.argv[2]
src = pathlib.Path(SRC).read_text()

ANCHOR = '    if (replaceable) {\n      final staticFlag'
n = src.count(ANCHOR)
if n != 1:
    sys.exit(f'weaken_predictor: anchor occurs {n} times, expected exactly 1; '
             f'the control would not be the intended weakening')

start = src.index(ANCHOR)
tail = '\n    }\n'
end = src.index(tail, start) + len(tail)
weak = src[:start] + src[end:]

if weak == src:
    sys.exit('weaken_predictor: output is identical to the input')

# The codes must survive in the vocabulary (that list is not the gate) but must
# no longer be reachable from the decision path.
for code in ('NON_STATIC_DISPATCH_UNPROVEN', 'STATIC_METADATA_UNUSABLE'):
    if f"'{code}'," not in weak:
        sys.exit(f'weaken_predictor: {code} vanished from the vocabulary too; '
                 f'the control removed more than the predicate')
    if weak.count(code) != 1:
        sys.exit(f'weaken_predictor: {code} still appears '
                 f'{weak.count(code)} times; the decision path was not removed')

pathlib.Path(OUT).write_text(weak)
print(f'  weakened predictor written: predicate block of '
      f'{end - start} chars removed')
