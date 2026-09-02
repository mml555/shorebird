#!/usr/bin/env python3
"""D-CENSUS-2. The two super numbers, reported separately and never pooled.

WHY TWO NUMBERS. D-SUPER shipped narrow-v1, not `super` in general. A site is
end-to-end admissible only when the RELEASE version of that same method already
direct-called the same semantic target. Counting every zero-argument
`super.method()` as supported would overstate what a real patch may carry, so
this reports:

  1 MECHANISM-CAPABLE   -- what the compiler can represent: a `super.member()`
    method call whose SOURCE argument list is empty. Source, not kernel: the
    census kernel is `--aot --tfa` and TFA rewrites argument counts, which is
    why analysisVersion 10/11 refuse to report an arity at all. The
    classification comes from the product's own fail-closed scanner
    (`route_b_super_source.routeBSuperCallArgs`), applied by
    `tool/census_super_shape.dart`.

  2 NARROW-V1 ADMISSIBLE -- additionally: `releaseSuperTargets` was MEASURED for
    that method, every site's target RESOLVED, and each resolved target appears
    in the measured set. Absent measurement is not an empty one; the analyzer
    omits the key rather than reporting `[]`, and an omitted key is not
    admissible.

WHAT A CENSUS CANNOT SAY. A census has ONE kernel: the corpus is its own
release (`releaseIsSelf` in the header). So measurement 2 answers "does the
release direct-call the target its own super site names" -- which is exactly the
condition for a patch that PRESERVES that call. It does NOT estimate whether a
patch introducing a NEW super call would be admissible, and nothing here should
be read that way.

The construct attribution is imported from census_report, not restated, so both
reporters share one definition of D0.3's corrected rules.
"""
import argparse
import json
import os
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import census_report as cr  # noqa: E402


def key(t):
    """The portable provenance tuple: fileUri | fileOffset | name | kind."""
    if not t:
        return None
    return (t.get('fileUri'), t.get('fileOffset'), t.get('name'), t.get('kind'))


def super_facts(row):
    """(sites, mechanism_capable, v1_admissible, why_not)."""
    sites = row.get('superSites') or []
    if not sites:
        return (0, False, False, None)
    if not all(s.get('kind') == 'method' for s in sites):
        return (len(sites), False, False, 'not_a_method_call')
    shapes = {s.get('sourceArgs') for s in sites}
    if shapes != {'zeroArguments'}:
        # hasArguments / unverifiable / sourceUnavailable -- all fail closed.
        return (len(sites), False, False, 'shape:' + ','.join(sorted(
            s for s in shapes if s != 'zeroArguments')))
    if 'releaseSuperTargets' not in row:
        # The analyzer omits the key when the base kernel is unlinked. A
        # missing measurement is a refusal, not a negative result.
        return (len(sites), True, False, 'measurement_absent')
    measured = {key(t) for t in (row.get('releaseSuperTargets') or [])}
    for s in sites:
        k = key(s.get('target'))
        if k is None:
            return (len(sites), True, False, 'target_unresolved')
        if k not in measured:
            return (len(sites), True, False, 'target_disagreement')
    return (len(sites), True, True, None)


def occurrences(rows, admissible=frozenset()):
    """Raw occurrence counts per construct, over the population passed in.

    The caller passes the STILL-BLOCKED rows, so this column shares a
    population with the `methods` and `SOLE` columns beside it. Counting it
    over every row instead produced rows like `super occur=30, methods=1` --
    occurrences from methods that are no longer blocked at all.

    Super sites in a narrow-v1 ADMISSIBLE method are not occurrences of a
    blocker any more, so they are skipped rather than counted.
    """
    occ = Counter()
    for r in rows:
        if id(r) not in admissible:
            occ['construct.super'] += len(r.get('superSites') or [])
        parents = r.get('unconsumedThisParents') or {}
        for name, n in parents.items():
            if name.startswith('Super'):
                continue      # attributed to super, per D0.3
            elif name == 'InstanceTearOff':
                occ['construct.method_tearoff'] += n
            else:
                occ['construct.this_escape'] += n
        for u in r['unsupported']:
            c = cr.canonical(u, r['target'])
            if c.startswith('receiver.super_'):
                occ['construct.super'] += 1
            elif c == 'receiver.unconsumed_this':
                continue
            else:
                occ[c] += 1
    return occ


def analyse(path, exclude=(), drop_generated=True):
    header, rows = cr.load(path)
    rows = [r for r in rows if not cr.excluded_by(r, exclude, drop_generated)]

    facts = {id(r): super_facts(r) for r in rows}
    considered = len(rows)
    d0_lowerable = sum(1 for r in rows if r['lowerable'])

    def c2_lowerable(r):
        n, _mech, adm, _ = facts[id(r)]
        if r['unsupported']:
            return False
        return n == 0 or adm

    c2 = sum(1 for r in rows if c2_lowerable(r))

    mech_methods = sum(1 for r in rows if facts[id(r)][1])
    adm_methods = sum(1 for r in rows if facts[id(r)][2])
    site_shapes = Counter()
    for r in rows:
        for s in (r.get('superSites') or []):
            site_shapes[s.get('sourceArgs')] += 1
    why = Counter(facts[id(r)][3] for r in rows
                  if (r.get('superSites') and not facts[id(r)][2]))

    # Constructs AFTER narrow-v1: an admissible super site is no longer a
    # blocker, so it is removed from that method's construct set. Everything
    # else is D0.3's rule, imported unchanged.
    ctouch, csole = Counter(), Counter()
    still_blocked = 0
    for r in rows:
        if c2_lowerable(r):
            continue
        still_blocked += 1
        cs = set(cr.constructs(r))
        if facts[id(r)][2]:
            cs.discard('construct.super')
        for c in cs:
            ctouch[c] += 1
        if len(cs) == 1:
            csole[next(iter(cs))] += 1

    return {
        'header': header,
        'considered': considered,
        'd0_lowerable': d0_lowerable,
        'c2_lowerable': c2,
        'd0_blocked': considered - d0_lowerable,
        'c2_blocked': considered - c2,
        'still_blocked': still_blocked,
        'super_methods': sum(1 for r in rows if (r.get('superSites') or [])),
        'super_sites': sum(len(r.get('superSites') or []) for r in rows),
        'mech_methods': mech_methods,
        'adm_methods': adm_methods,
        'site_shapes': site_shapes,
        'why_not': why,
        'ctouch': ctouch,
        'csole': csole,
        # Over the still-blocked population only, and with admissible super
        # sites excluded, so every column in the blocker table counts the same
        # methods.
        'occ': occurrences(
            [r for r in rows if not c2_lowerable(r)],
            admissible={id(r) for r in rows if facts[id(r)][2]},
        ),
    }


def pct(n, d):
    return '--' if not d else '%.2f%%' % (100.0 * n / d)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--corpus', action='append', required=True,
                    help='label|d0_considered|d0_lowerable|path')
    ap.add_argument('--out')
    args = ap.parse_args()

    out = open(args.out, 'w') if args.out else sys.stdout
    w = out.write
    results = []

    w('=' * 78 + '\n')
    w('D-CENSUS-2 -- narrow-v1 super admissibility, measured separately from\n')
    w('mechanism lowerability. Read the module docstring before the numbers.\n')
    w('=' * 78 + '\n')

    for spec in args.corpus:
        label, d0_considered, d0_lowerable, path = spec.split('|', 3)
        d0_considered, d0_lowerable = int(d0_considered), int(d0_lowerable)
        a = analyse(path)
        results.append((label, a))

        w('\n' + '-' * 78 + '\n%s\n' % label + '-' * 78 + '\n')
        h = a['header']
        w('  censusVersion %s   analysisVersion %s   releaseIsSelf %s   linked %s\n'
          % (h.get('censusVersion'), h.get('analysisVersion'),
             h.get('releaseIsSelf'), h.get('censusIsLinked')))

        # Reproduction check FIRST: an "after" number is meaningless if the
        # "before" one did not come back.
        repro = (a['considered'] == d0_considered
                 and a['d0_lowerable'] == d0_lowerable)
        w('\n  D0 REPRODUCTION  considered %d vs %d, lowerable %d vs %d -> %s\n'
          % (a['considered'], d0_considered, a['d0_lowerable'], d0_lowerable,
             'EXACT' if repro else 'MISMATCH -- STOP'))

        w('\n  %-28s %10s %12s\n' % ('Metric', 'D0', 'D-CENSUS-2'))
        w('  %s\n' % ('-' * 52))
        w('  %-28s %10d %12d\n' % ('Total instance procedures',
                                   d0_considered, a['considered']))
        w('  %-28s %10d %12d\n' % ('Fully lowerable',
                                   d0_lowerable, a['c2_lowerable']))
        w('  %-28s %10s %12s\n' % ('Lowerability %',
                                   pct(d0_lowerable, d0_considered),
                                   pct(a['c2_lowerable'], a['considered'])))
        w('  %-28s %10d %12d\n' % ('Blocked',
                                   d0_considered - d0_lowerable,
                                   a['c2_blocked']))
        w('  %-28s %10s %12d\n' % ('Super mechanism-capable', '0',
                                   a['mech_methods']))
        w('  %-28s %10s %12d\n' % ('Super narrow-v1 admissible', '0',
                                   a['adm_methods']))

        w('\n  SUPER DETAIL -- the two numbers, not collapsed\n')
        w('    methods containing a super site      %6d\n' % a['super_methods'])
        w('    super sites                          %6d\n' % a['super_sites'])
        for shape, n in sorted(a['site_shapes'].items()):
            w('      source shape %-22s %6d\n' % (shape, n))
        w('    mechanism-capable methods            %6d\n' % a['mech_methods'])
        w('    narrow-v1 ADMISSIBLE methods         %6d\n' % a['adm_methods'])
        w('    gap (capable but not admissible)     %6d\n'
          % (a['mech_methods'] - a['adm_methods']))
        if a['why_not']:
            w('    why a super method is not admissible:\n')
            for reason, n in a['why_not'].most_common():
                w('      %-36s %6d\n' % (reason, n))

        w('\n  REMAINING BLOCKERS, after narrow-v1 admissibility\n')
        w('  %-32s %6s %8s %8s %8s %9s\n'
          % ('blocker', 'occur', 'methods', '% corpus', 'SOLE', '% blocked'))
        w('  %s\n' % ('-' * 78))
        for name in sorted(a['ctouch'],
                           key=lambda c: (-a['csole'][c], -a['ctouch'][c], c)):
            w('  %-32s %6d %8d %8s %8d %9s\n'
              % (name, a['occ'][name], a['ctouch'][name],
                 pct(a['ctouch'][name], a['considered']),
                 a['csole'][name], pct(a['csole'][name], a['still_blocked'])))
        w('    blocked methods after narrow-v1      %6d\n' % a['still_blocked'])

    # Replication across the two real corpora.
    real = [(l, a) for l, a in results if 'airgap' not in l.lower()]
    if len(real) == 2:
        (l1, a1), (l2, a2) = real
        w('\n' + '=' * 78 + '\n')
        w('REPLICATION -- sole-blocked after narrow-v1 admissibility\n')
        w('=' * 78 + '\n')
        w('  %-32s %14s %14s  %s\n' % ('blocker', l1, l2, 'replicated?'))
        w('  %s\n' % ('-' * 78))
        names = set(a1['csole']) | set(a2['csole'])
        for name in sorted(names, key=lambda c: -(a1['csole'][c]
                                                  + a2['csole'][c])):
            n1, n2 = a1['csole'][name], a2['csole'][name]
            w('  %-32s %14d %14d  %s\n'
              % (name, n1, n2, 'YES' if n1 and n2 else 'no'))
        w('\n  "Replicated" means sole-blocked in BOTH, nothing about magnitude.\n')

    if args.out:
        out.close()


if __name__ == '__main__':
    main()
