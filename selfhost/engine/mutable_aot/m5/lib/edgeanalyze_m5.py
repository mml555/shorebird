#!/usr/bin/env python3
"""Post-analysis over the two edge logs written by edgediff_m5.py.

Separate from the run so the 40-minute snapshot pair is not repeated every
time a question changes.
"""
import collections, os, sys

ED = ('/private/tmp/claude-501/-Users-mendell-shorebird/'
      '541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/sizemat/edgediff')
RELEASE = ('a reachable caller holds a mutable indirect call whose release '
           'target ordinary AOT reachability would have discovered')
STATIC = 'needed for symbolic stack traces'   # only emitted at the call table
TABLESEL = 'forced via flag'                  # IsHitByTableSelector, dwarf off


def load(tag):
    edges = []
    for l in open(os.path.join(ED, '%s.edges' % tag), errors='replace'):
        p = l.rstrip('\n').split('\t')
        if len(p) == 3:
            edges.append(tuple(p))
    retained = {l.rstrip('\n') for l in
                open(os.path.join(ED, '%s.retained' % tag), errors='replace')
                if l.strip()}
    return edges, retained


A, ar = load('A')
B, br = load('B')
sa, sb = set(A), set(B)
missing, extra = sa - sb, sb - sa

print('=== EDGE DIFF BY KIND ===')
print('%-62s %8s %8s %8s %8s' % ('edge kind', 'A', 'B', 'missing', 'extra'))
kinds = sorted({k for _, _, k in sa | sb})
ca = collections.Counter(k for _, _, k in sa)
cb = collections.Counter(k for _, _, k in sb)
cm = collections.Counter(k for _, _, k in missing)
cx = collections.Counter(k for _, _, k in extra)
for k in kinds:
    print('%-62s %8d %8d %8d %8d' % (k[:62], ca[k], cb[k], cm[k], cx[k]))

print('\n=== STATIC-CALL-TABLE EDGES (the class #67 removed) ===')
a_static = {(c, t) for c, t, k in sa if k == STATIC}
b_static = {(c, t) for c, t, k in sb if k == STATIC}
b_release = {(c, t) for c, t, k in sb if k == RELEASE}
print('A static-call-table edges           = %d' % len(a_static))
print('B static-call-table edges           = %d' % len(b_static))
print('B release edges                     = %d' % len(b_release))
gone = a_static - b_static
print('static edges A has and B lacks      = %d' % len(gone))
print('  ... of those restored as a release edge = %d' % len(gone & b_release))
print('  ... restored with the SAME caller+callee pair')
print('release edges with no matching baseline static edge = %d' %
      len(b_release - a_static))

print('\n=== WHICH CALLEES DID THE RELEASE EDGE INTRODUCE? ===')
b_only_targets = {t for c, t in b_release}
a_any_targets = {t for _, t, _ in sa}
new_targets = b_only_targets - a_any_targets
print('release-edge callees            = %d' % len(b_only_targets))
print('  never a callee in baseline    = %d' % len(new_targets))
for t in sorted(new_targets)[:10]:
    print('     -', t[:104])

print('\n=== DISPATCH-TABLE SELECTOR EDGES ===')
a_tab = {(c, t) for c, t, k in sa if k == TABLESEL}
b_tab = {(c, t) for c, t, k in sb if k == TABLESEL}
print('A = %d   B = %d   A-only = %d   B-only = %d' %
      (len(a_tab), len(b_tab), len(a_tab - b_tab), len(b_tab - a_tab)))

print('\n=== RETAINED SET ACCOUNTED FOR BY THE GRAPH ===')
for tag, edges, ret in (('A', sa, ar), ('B', sb, br)):
    callees = {t for _, t, _ in edges}
    print('%s retained=%d  appear as a callee=%d  orphan=%d' %
          (tag, len(ret), len(ret & callees), len(ret - callees)))
