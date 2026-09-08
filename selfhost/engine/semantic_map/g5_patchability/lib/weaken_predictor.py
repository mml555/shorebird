#!/usr/bin/env python3
"""Produce the weakened predictor used as the dispatch-predicate control.

Deleting a block by string surgery is only a valid control if the surgery is
PROVEN to have found the intended block. A transformation that silently matched
nothing would leave the "control" identical to the real predictor, and every
arm would keep passing -- a control that cannot fail.

So this asserts: the anchor occurs exactly once, both decision-path reason
codes disappear while the vocabulary entries remain, and the output differs
from the input.

Each gate is removed on its own, so a control proves the gate it names rather
than "some refusal disappeared".

usage: weaken_predictor.py <predict_patchable.dart> <out.dart> [dispatch|frontend]
"""
import pathlib
import sys

SRC, OUT = sys.argv[1], sys.argv[2]
GATE = sys.argv[3] if len(sys.argv) > 3 else 'dispatch'
src = pathlib.Path(SRC).read_text()

GATES = {
    # gate: (anchor, closing delimiter, codes that must leave the decision path)
    'dispatch': ('    if (replaceable) {\n      final staticFlag', '\n    }\n',
                 ('NON_STATIC_DISPATCH_UNPROVEN', 'STATIC_METADATA_UNUSABLE')),
    'frontend': ("    if (replaceable) reasons.add('FRONTEND_MATERIALIZATION_UNPROVEN');",
                 '\n', ('FRONTEND_MATERIALIZATION_UNPROVEN',)),
}
if GATE not in GATES:
    sys.exit(f'weaken_predictor: unknown gate {GATE!r}; '
             f'expected one of {sorted(GATES)}')
ANCHOR, tail, CODES = GATES[GATE]

n = src.count(ANCHOR)
if n != 1:
    sys.exit(f'weaken_predictor: anchor for gate {GATE!r} occurs {n} times, '
             f'expected exactly 1; the control would not be the intended '
             f'weakening')

start = src.index(ANCHOR)
end = src.index(tail, start) + len(tail)
weak = src[:start] + src[end:]

if weak == src:
    sys.exit('weaken_predictor: output is identical to the input')

# The codes must survive in the vocabulary (that list is not the gate) but must
# no longer be reachable from the decision path.
for code in CODES:
    if f"'{code}'," not in weak:
        sys.exit(f'weaken_predictor: {code} vanished from the vocabulary too; '
                 f'the control removed more than the predicate')
    if weak.count(code) != 1:
        sys.exit(f'weaken_predictor: {code} still appears '
                 f'{weak.count(code)} times; the decision path was not removed')

pathlib.Path(OUT).write_text(weak)
print(f'  weakened predictor written: gate {GATE!r}, '
      f'{end - start} chars removed')
