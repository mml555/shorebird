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
# A REASON-TARGETED WEAKENING, used by falsify_predictor.py. It removes the
# code from the DECISION path only -- every occurrence after the vocabulary
# block is renamed -- so the arm asserting that code must fail while the
# vocabulary entry survives. This makes each arm prove the gate it names.
# THE GENERIC-COLLAPSE CONTROL. A predictor that still refuses everything but
# reports one undifferentiated code must satisfy NO reason-specific arm; this
# builds that predictor by renaming every vocabulary code in the decision path
# to a single value. It is the counterpart of the reader's control B.
if GATE == 'generic':
    cut = src.index('];', src.index('const refusalReasons'))
    head, body = src[:cut], src[cut:]
    import re as _re
    vb = src[src.index('const refusalReasons'):cut]
    codes = sorted(set(_re.findall(r"'([A-Z_]+)'", vb)), key=len, reverse=True)
    for c in codes:
        body = body.replace(f"'{c}'", "'GENERIC_REFUSAL'")
    weak = head + body
    if weak == src:
        sys.exit('weaken_predictor: output is identical to the input')
    pathlib.Path(OUT).write_text(weak)
    print(f'  weakened predictor written: {len(codes)} codes collapsed to one')
    sys.exit(0)

if GATE.startswith('reason:'):
    code = GATE.split(':', 1)[1]
    cut = src.index('];', src.index('const refusalReasons'))
    head, body = src[:cut], src[cut:]
    n_body = body.count(f"'{code}'")
    if n_body == 0:
        sys.exit(f'weaken_predictor: {code} never appears in the decision '
                 f'path, so it cannot be the gate for any arm')
    weak = head + body.replace(f"'{code}'", "'GATE_REMOVED_FOR_CONTROL'")
    if weak == src:
        sys.exit('weaken_predictor: output is identical to the input')
    pathlib.Path(OUT).write_text(weak)
    print(f'  weakened predictor written: gate for {code} removed '
          f'({n_body} decision-path occurrence(s))')
    sys.exit(0)

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
