#!/usr/bin/env python3
"""Stage 40 differential diagnosis: diff the REACHABILITY GRAPH, not its result.

Stage 40 compared two sets of survivors. A set difference cannot distinguish
"the edge into this declaration disappeared" from "the declaration that used
to pull it in disappeared" from "it was never pulled in by an edge at all".
This runs both arms with --maot_dump_reach_edges and answers that directly.

Diagnosis only. Nothing here changes a recording point.
"""
import collections, json, os, subprocess, sys

FORK = '/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT = '/Volumes/build/route-b/flutter/engine/src/out/maot_host'
NS = 'ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
WD = ('/private/tmp/claude-501/-Users-mendell-shorebird/'
      '541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/sizemat')
ED = os.path.join(WD, 'edgediff')
os.makedirs(ED, exist_ok=True)

PHASE2 = 'retain:AddTypesOf'


def run(tag, dill):
    aot = os.path.join(ED, '%s.aot' % tag)
    ret = os.path.join(ED, '%s.retained' % tag)
    edg = os.path.join(ED, '%s.edges' % tag)
    # Re-analysis of a completed pair must not re-run a 40-minute snapshot;
    # the classification changed twice while the first pair was still building.
    if os.environ.get('EDGEDIFF_REUSE') and os.path.exists(ret) and \
            os.path.exists(edg):
        return load(tag, ret, edg, aot)
    for p in (ret, edg):
        if os.path.exists(p):
            os.remove(p)
    r = subprocess.run(
        [os.path.join(OUT, 'gen_snapshot'), '--snapshot_kind=app-aot-elf',
         '--elf=%s' % aot, '--maot_namespace=%s' % NS,
         '--maot_disable_retention_roots',
         '--maot_dump_retained=%s' % ret,
         '--maot_dump_reach_edges=%s' % edg, dill],
        capture_output=True, text=True, timeout=10800)
    if r.returncode != 0:
        print('%s SNAPSHOT rc=%d' % (tag, r.returncode))
        print('\n'.join(r.stderr.splitlines()[-15:]))
        sys.exit(1)
    return load(tag, ret, edg, aot, r.stderr)


def load(tag, ret, edg, aot, stderr=''):
    retained = {l.rstrip('\n') for l in open(ret, errors='replace') if l.strip()}
    edges = []
    for l in open(edg, errors='replace'):
        p = l.rstrip('\n').split('\t')
        if len(p) == 3:
            edges.append(tuple(p))
    return dict(tag=tag, retained=retained, edges=edges,
                stderr=stderr, aot=aot)


def index(edges):
    """callee -> set of (caller, kind); caller -> set of callees."""
    inn = collections.defaultdict(set)
    for caller, callee, kind in edges:
        inn[callee].add((caller, kind))
    return inn


# Retain reasons are the edge kinds. Map them onto the classes the PM asked
# for. Anything unmapped is reported verbatim rather than lumped into "other".
# The edge kind is the retain reason. These are the exact strings from
# RetainReasons plus the two this instrumentation adds. Mapping is by exact
# match, not substring: "needed for symbolic stack traces" is emitted at
# EXACTLY ONE AddFunction site -- the static call table walk in AddCalleesOf --
# which is the edge class #67 removed, so collapsing it into a fuzzy bucket
# would hide the thing being looked for.
CLASS = {
    'needed for symbolic stack traces': 'static call (call table)',
    # kForcedRetain reaches AddFunction from two sites: the static call table
    # walk when dwarf_stack_traces_mode is ON, and IsHitByTableSelector in
    # CheckForNewDynamicFunctions. dwarf mode is OFF in these runs -- proved by
    # the call table emitting kSymbolicStackTraces instead -- so every
    # kForcedRetain edge here is a dispatch-table selector edge.
    'forced via flag': 'virtual/interface (dispatch table selector)',
    '<none>': 'static call (call table, no reason)',
    'called via selector': 'virtual/interface (selector)',
    'called through getter': 'virtual/interface (via getter)',
    'dynamic invocation forwarder': 'dynamic',
    'needs monomorphic checked entry': 'dynamic (switchable call)',
    'native function': 'native',
    'method extractor': 'closure/tear-off',
    'implicit closure': 'closure/tear-off',
    'local closure': 'closure/tear-off',
    'parent of a local function': 'closure/tear-off',
    'invoke field dispatcher': 'dynamic (invoke field)',
    'implicit getter': 'implicit accessor',
    'implicit setter': 'implicit accessor',
    'implicit static getter': 'implicit accessor',
    'static field initializer': 'field initializer',
    'instance field initializer': 'field initializer',
    'late field initializer': 'field initializer',
    'needed for async stack unwinding': 'async unwinding',
    'entry point pragma': 'entry point / root',
    'this is main function of the root library': 'entry point / root',
    'ffi callback target': 'ffi',
    'mutable-aot declaration': 'MAOT declaration root',
    'retain:AddTypesOf': 'structural (phase-2 retention only)',
}
RELEASE = ('a reachable caller holds a mutable indirect call whose release '
           'target ordinary AOT reachability would have discovered')
CLASS[RELEASE] = 'MAOT release edge'


def klass(kind):
    return CLASS.get(kind, 'UNMAPPED: %s' % (kind or '')[:60])


def first_missing_edge(decl, a_in, b_retained, b_in, seen=None, depth=0):
    """Walk baseline in-edges up from `decl` until we reach a predecessor that
    MAOT also retained. The edge out of that predecessor is the first edge the
    two graphs disagree about."""
    if seen is None:
        seen = set()
    if decl in seen or depth > 24:
        return None
    seen.add(decl)
    preds = a_in.get(decl)
    if not preds:
        return ('<no baseline in-edge>', decl, '<none>', depth)
    # Prefer a predecessor MAOT still has: that is where the graphs fork.
    for caller, kind in sorted(preds):
        if caller == '<root>' or caller in b_retained:
            if (caller, decl, kind) not in b_in.get(decl, set()) or \
               (caller, kind) not in b_in.get(decl, set()):
                return (caller, decl, kind, depth)
    for caller, kind in sorted(preds):
        if caller in ('<root>', decl):
            continue
        up = first_missing_edge(caller, a_in, b_retained, b_in, seen, depth + 1)
        if up is not None:
            return up
    caller, kind = sorted(preds)[0]
    return (caller, decl, kind, depth)


def main():
    A = run('A', os.path.join(WD, 'k0.dill'))
    B = run('B', os.path.join(WD, 'k1.dill'))

    a_edges = set(A['edges'])
    b_edges = set(B['edges'])
    a_in, b_in = index(A['edges']), index(B['edges'])

    print('=== GRAPH SIZES ===')
    print('%-6s %-10s %-12s %-12s' % ('arm', 'retained', 'edges(raw)', 'edges(uniq)'))
    for r, e in ((A, a_edges), (B, b_edges)):
        print('%-6s %-10d %-12d %-12d' % (r['tag'], len(r['retained']),
                                          len(r['edges']), len(e)))

    # COVERAGE. A retained declaration with no in-edge at all means the graph
    # is incomplete and every conclusion drawn from it is unsupported. Report
    # it before drawing any.
    print('\n=== EDGE-LOG COVERAGE (does the graph explain the set?) ===')
    for r, idx in ((A, a_in), (B, b_in)):
        uncovered = [d for d in r['retained'] if d not in idx]
        print('%-6s retained with NO in-edge = %d / %d' %
              (r['tag'], len(uncovered), len(r['retained'])))
        for u in sorted(uncovered)[:5]:
            print('         -', u[:110])

    missing = a_edges - b_edges
    extra = b_edges - a_edges
    print('\n=== EDGE DIFF ===')
    print('MISSING_EDGES (baseline has, MAOT lacks) = %d' % len(missing))
    print('EXTRA_EDGES   (MAOT has, baseline lacks) = %d' % len(extra))

    lost = A['retained'] - B['retained']
    gained = B['retained'] - A['retained']
    print('\n### LOST  (%d)' % len(lost))
    print('%-58s %-46s %-26s %s' %
          ('declaration', 'baseline predecessor', 'missing edge kind', 'class'))
    explained = 0
    for d in sorted(lost):
        fm = first_missing_edge(d, a_in, B['retained'], b_in)
        if fm is None:
            print('%-58s %-46s %-26s %s' % (d[-58:], '<unresolved>', '-', '-'))
            continue
        caller, callee, kind, depth = fm
        explained += 1
        print('%-58s %-46s %-26s %s' %
              (d[-58:], caller[-46:], kind[:26], klass(kind)))
        if callee != d:
            print('%-58s   via %s' % ('', callee[-90:]))
        preds_a = sorted(a_in.get(d, set()))
        preds_b = sorted(b_in.get(d, set()))
        print('%-58s   baseline in-edges=%d  maot in-edges=%d' %
              ('', len(preds_a), len(preds_b)))
        for c, k in preds_a[:4]:
            mark = 'kept' if (c, k) in set(preds_b) else 'GONE'
            print('%-58s     [%s] %s  <-  %s' % ('', mark, k[:28], c[-70:]))

    print('\n### EXTRA (%d) grouped by the edge class that introduced them' %
          len(gained))
    by_class = collections.Counter()
    by_kind = collections.Counter()
    via_release = 0
    root_only = 0
    for d in sorted(gained):
        preds = b_in.get(d, set())
        kinds = {k for _, k in preds}
        if not preds:
            by_class['<no in-edge: phase-2 only>'] += 1
            continue
        if RELEASE in kinds:
            via_release += 1
        if all(c == '<root>' for c, _ in preds):
            root_only += 1
        for k in kinds:
            by_kind[k] += 1
        by_class[klass(sorted(kinds)[0])] += 1
    print('%-44s %s' % ('cause / edge class', 'declarations'))
    for k, v in by_class.most_common():
        print('%-44s %d' % (k, v))
    print('\nreached through the STAGE40 release edge = %d / %d' %
          (via_release, len(gained)))
    print('reached ONLY from <root> (no caller)      = %d / %d' %
          (root_only, len(gained)))
    print('\ntop raw retain reasons among EXTRA:')
    for k, v in by_kind.most_common(12):
        print('   %-52s %d' % (k[:52], v))

    print('\nby package:')
    def bucket(n):
        if n.startswith('dart:'):
            return 'dart: (SDK)'
        if n.startswith('package:'):
            return 'package:' + n.split('/')[0][8:]
        if n.startswith('file:'):
            return 'file: (entry)'
        return 'other'
    for k, v in collections.Counter(bucket(n) for n in gained).most_common(10):
        print('   %-52s %d' % (k, v))

    print('\n=== SUMMARY ===')
    print('MISSING_EDGES count                        = %d' % len(missing))
    print('EXTRA_EDGES count                          = %d' % len(extra))
    print('LOST explained by edge diff                = %d/%d' %
          (explained, len(lost)))
    app = sum(1 for n in gained if not n.startswith('dart:'))
    print('EXTRA application declarations             = %d' % app)
    open(os.path.join(ED, 'missing_edges.tsv'), 'w').write(
        '\n'.join('\t'.join(e) for e in sorted(missing)))
    open(os.path.join(ED, 'extra_edges.tsv'), 'w').write(
        '\n'.join('\t'.join(e) for e in sorted(extra)))
    print('wrote %s/{missing,extra}_edges.tsv' % ED)


main()
