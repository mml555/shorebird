#!/usr/bin/env python3
"""The revised routing-neutrality gate: strong retention exact, weak reported.

A declaration is WEAK only if its sole reason for being retained is another
function's inline metadata -- no call edge, no selector, no root, no structural
dependency of its own. That is a property of WHY it is retained, so each
AddTypesOf site now names itself and the classification reads those names
instead of inferring from outgoing edges.

Arms are the semantic control C and production B: same kernel, same
non-inlining semantics, differing only in the call indirection and the
release edge.
"""
import collections, os, subprocess, sys

OUT = '/Volumes/build/route-b/flutter/engine/src/out/maot_host'
NS = 'ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
WD = ('/private/tmp/claude-501/-Users-mendell-shorebird/'
      '541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/sizemat')
ED = os.path.join(WD, 'strongweak')
os.makedirs(ED, exist_ok=True)

# Retention sites that are inline metadata and nothing else.
WEAK_SITES = {'retain:inline-tree'}
ARMS = {
    'C': ['--maot_disable_call_indirection'],
    'B': [],
}


def run(tag):
    ret = os.path.join(ED, '%s.retained' % tag)
    edg = os.path.join(ED, '%s.edges' % tag)
    if not (os.environ.get('SW_REUSE') and os.path.exists(ret)):
        for p in (ret, edg):
            if os.path.exists(p):
                os.remove(p)
        r = subprocess.run(
            [os.path.join(OUT, 'gen_snapshot'), '--snapshot_kind=app-aot-elf',
             '--elf=%s' % os.path.join(ED, '%s.aot' % tag),
             '--maot_namespace=%s' % NS, '--maot_disable_retention_roots',
             '--maot_dump_retained=%s' % ret,
             '--maot_dump_reach_edges=%s' % edg] + ARMS[tag]
            + [os.path.join(WD, 'k1.dill')],
            capture_output=True, text=True, timeout=10800)
        if r.returncode != 0:
            print('%s SNAPSHOT rc=%d' % (tag, r.returncode))
            print('\n'.join(r.stderr.splitlines()[-12:]))
            sys.exit(1)
    edges = []
    for l in open(edg, errors='replace'):
        p = l.rstrip('\n').split('\t')
        if len(p) == 3:
            edges.append(tuple(p))
    retained = {l.rstrip('\n') for l in open(ret, errors='replace') if l.strip()}
    return set(edges), retained


def classify(edges, retained):
    """-> {declaration: set of retention kinds}, and the weak set."""
    kinds = collections.defaultdict(set)
    for _c, t, k in edges:
        kinds[t].add(k)
    weak = {d for d in retained
            if kinds.get(d) and set(kinds[d]) <= WEAK_SITES}
    return kinds, weak


def main():
    ec, rc = run('C')
    eb, rb = run('B')
    kc, wc = classify(ec, rc)
    kb, wb = classify(eb, rb)

    print('=== RETENTION CLASSES ===')
    print('%-4s %-10s %-10s %-10s' % ('arm', 'retained', 'strong', 'weak'))
    for tag, r, w in (('C', rc, wc), ('B', rb, wb)):
        print('%-4s %-10d %-10d %-10d' % (tag, len(r), len(r) - len(w), len(w)))

    # The gate is about MEMBERSHIP, not about which class a declaration that
    # both arms retain happens to fall into. Taking the difference of the two
    # strong SETS conflates the two: a declaration retained in both arms that
    # is strong in one and weak in the other appears in it, and would have been
    # reported here as a routing loss. It is not one.
    lost = rc - rb
    extra = rb - rc
    strong_lost = {d for d in lost if d not in wc}
    strong_extra = {d for d in extra if d not in wb}
    print('\n=== REVISED GATE A: routing neutrality, C vs B ===')
    print('C - B = %d declaration(s); B - C = %d' % (len(lost), len(extra)))
    print('STRONG_LOST_ROUTING  = %d' % len(strong_lost))
    for d in sorted(strong_lost):
        print('      -', d[:110], sorted(kc.get(d, ())))
    print('STRONG_EXTRA_ROUTING = %d' % len(strong_extra))
    for d in sorted(strong_extra):
        print('      +', d[:110], sorted(kb.get(d, ())))
    app = [d for d in strong_extra if not d.startswith('dart:')]
    print('   of which application declarations = %d' % len(app))

    # Reported, not gating: declarations both arms retain whose retention CLASS
    # differs. They are not a membership change, but they show that the class
    # boundary is itself order-sensitive, which is the same effect Stage 42
    # measured and the reason this gate is about membership.
    reclass = (wc & (rb - wb)) | (wb & (rc - wc))
    print('\nretained by both arms but classified differently = %d' % len(reclass))
    for d in sorted(reclass):
        print('      ~', d[:100])
        print('           C:', sorted(kc.get(d, ())))
        print('           B:', sorted(kb.get(d, ())))

    print('\n=== WEAK (inline-metadata-only) DELTA, reported not gating ===')
    print('weak in C, not retained in B = %d' % len(lost & wc))
    for d in sorted(lost & wc):
        print('      -', d[:110], sorted(kc.get(d, ())))
    print('weak in B, not retained in C = %d' % len(extra & wb))
    for d in sorted(extra & wb):
        print('      +', d[:110], sorted(kb.get(d, ())))

    print('\n=== the classification is not vacuous ===')
    allk = collections.Counter()
    for d in rc:
        for k in kc.get(d, ()):
            allk[k] += 1
    print('retention kinds seen in arm C (declarations carrying each):')
    for k, v in allk.most_common():
        print('   %-28s %6d   %s' % (k, v, 'WEAK' if k in WEAK_SITES else ''))
    print('\nweak declarations exist at all: %s' % ('yes' if wc else 'NO'))
    fails = []
    if strong_lost:
        fails.append('STRONG_LOST_ROUTING = %d' % len(strong_lost))
    if app:
        fails.append('STRONG_EXTRA_ROUTING application = %d' % len(app))
    if not wc:
        fails.append('no weak declarations found -- the exemption class is '
                     'empty, so it cannot have been applied')
    print('\n%s' % ('PASS' if not fails else 'FAIL: ' + '; '.join(fails)))
    return 1 if fails else 0


sys.exit(main())
