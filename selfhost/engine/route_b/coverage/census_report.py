#!/usr/bin/env python3
"""D0.2 -- report a structural body census, per corpus, with no `other` bucket.

WHAT THIS MEASURES, and the sentence is load-bearing:

    Of the instance methods that EXIST in these applications today, which of
    Route B's CURRENT lowering refusals would prevent each one from being
    lowered.

It is not, and cannot be turned into, an estimate of how many real patches
would succeed. Every method counts once, whether it changes weekly or has never
been touched. The denominator is existence, not demand.

WHY A RAW HISTOGRAM WOULD PICK THE WRONG FEATURE. If 800 methods are blocked by
compound writes and 700 by named parameters, but 750 of the 800 are blocked by
BOTH, then closing compound writes unlocks 50 methods, not 800. So every
category is reported three ways: how many methods it touches, how many it is
the ONLY blocker for, and what that is as a share of the blocked population.
The third number is the one a roadmap should be read off.

CATEGORIES ARE CLOSED. `_lowering`'s reason strings interpolate member names, so
they are canonicalised by pattern. An unrecognised reason is a FATAL ERROR, not
an `other` bucket: a refusal added to the analyzer later must force this file to
be updated rather than quietly dissolving into a miscellaneous row and
distorting the ranking it was supposed to inform.
"""
import argparse, json, re, sys
from collections import Counter
from itertools import combinations

# Ordered: first match wins. Anchored where the reason is fixed text.
CATEGORIES = [
    ('abi.named_parameters',        re.compile(r'^the method takes named parameters$')),
    ('abi.optional_positionals',    re.compile(r'^the method takes optional positional parameters$')),
    ('abi.generic',                 re.compile(r'^the method is generic$')),
    ('receiver.compound_same_offset', re.compile(r'^reads and writes `.+` in one expression \(.+\), which this lowering cannot rewrite as a single edit$')),
    ('receiver.super_set',          re.compile(r'^assigns to `super\..+`$')),
    ('receiver.super_get',          re.compile(r'^reads `super\..+`$')),
    ('receiver.super_call',         re.compile(r'^calls `super\..+\(\)`$')),
    ('receiver.getter_invocation',  re.compile(r'^invokes the getter `.+` on the receiver$')),
    ('receiver.unconsumed_this',    re.compile(r'^uses `this` other than to read a member$')),
    ('receiver.private_unresolvable', re.compile(r'^(reads|calls|assigns to) the private member `.+`, which resolves to no declaration this analysis can name')),
]

DISCLAIMER = """\
================================================================================
STRUCTURAL BODY CENSUS -- NOT PATCH DEMAND
================================================================================
Each existing method counts once, regardless of how likely that method is to
change in practice.

Percentages measure current Route B refusal reachability over methods that
EXIST. They do NOT estimate:
  - patch success rate,
  - frequency of real changes,
  - user demand,
  - or percentage of production fixes Route B can ship.

Only the LOWERING stage was run. Reachability, release retention, the
producer's own source-text refusals and the bytecode compiler are separate
stages and were not evaluated. `lowerable` means this stage raised no
objection, and nothing more.

The two corpora are reported separately and are NOT pooled: one is a synthetic
regression fixture written to exercise this mechanism, the other is an
application written by people who had never heard of it.
================================================================================
"""


def canonical(reason, target):
    for name, pattern in CATEGORIES:
        if pattern.match(reason):
            return name
    sys.stderr.write(
        '\nCENSUS ERROR -- unknown refusal reason\n'
        '  raw reason: %s\n  selector  : %s\n\n'
        'The lowering contract emitted a refusal this report has no category\n'
        'for. Add it to CATEGORIES rather than letting it fall into a bucket:\n'
        'an uncategorised refusal would distort every ranking below it.\n' % (reason, target))
    sys.exit(2)


def load(path):
    with open(path) as handle:
        lines = [line for line in handle if line.strip()]
    return json.loads(lines[0]), [json.loads(line) for line in lines[1:]]


# Applied IDENTICALLY to every corpus, which is the only thing that makes it a
# filter rather than a thumb on the scale. On a corpus with no generated code it
# removes nothing, and the report says so.
#
# It exists because localsend carries ~55 slang locale files of ~316 generated
# translation getters each: 18,193 of its 19,164 instance procedures, all
# mechanically identical. Left in, they dilute every percentage roughly tenfold
# and make the two corpora non-comparable -- Wonderous has none at all. Removed,
# 971 hand-written procedures remain, against Wonderous's 1,282.
#
# Both views are reported. The exclusion is a reporting slice; the census
# executable, the taxonomy and the denominator rule are unchanged.
def excluded_by(row, patterns, drop_generated):
    if drop_generated and row.get('generated'):
        return True
    return any(pat in row['target'] for pat in patterns)


def pct(n, d):
    return '   --  ' if not d else '%6.2f%%' % (100.0 * n / d)


def report(label, kind, path, out, exclude=(), drop_generated=False):
    header, rows = load(path)
    dropped = [r for r in rows if excluded_by(r, exclude, drop_generated)]
    rows = [r for r in rows if not excluded_by(r, exclude, drop_generated)]
    considered = len(rows)
    lowerable = sum(1 for r in rows if r['lowerable'])
    blocked = considered - lowerable

    cats = [{canonical(u, r['target']) for u in r['unsupported']} for r in rows]
    touches, sole = Counter(), Counter()
    for cs in cats:
        for c in cs:
            touches[c] += 1
        if len(cs) == 1:
            sole[next(iter(cs))] += 1

    w = out.write
    w('\n%s\n' % ('-' * 80))
    w('%s   (%s)\n' % (label, kind))
    w('%s\n' % ('-' * 80))
    w('  dill                        %s\n' % header['dill'])
    w('  include                     %s\n' % ', '.join(header['include']))
    w('\n')
    if exclude or drop_generated:
        what = list(exclude) + (['files marked @generated'] if drop_generated else [])
        w('  excluded                    %s\n' % ', '.join(what))
        w('    rows removed                   %6d of %d\n'
          % (len(dropped), len(dropped) + considered))
        if not dropped:
            w('    (this corpus has none -- the same filter, no effect)\n')
        w('\n')
    w('  instance procedures considered   %6d\n' % considered)
    w('    lowerable now                  %6d   %s\n' % (lowerable, pct(lowerable, considered)))
    w('    blocked by >=1 reason          %6d   %s\n' % (blocked, pct(blocked, considered)))
    w('\n')
    w('  excluded from the denominator, counted so the exclusion is visible:\n')
    w('    static (no receiver to lower)  %6d\n' % header['skippedStatic'])
    w('    abstract / external (no body)  %6d\n' % header['skippedNoBody'])
    w('    no usable source span          %6d\n' % header['skippedNoSpan'])

    w('\n  REFUSAL CATEGORIES\n')
    w('  %-32s %8s %8s %8s %9s\n' % ('category', 'methods', '% of all', 'SOLE', '% unlock'))
    w('  %s\n' % ('-' * 74))
    # Ranked by marginal unlock -- the number a roadmap is read off -- not by
    # raw prevalence, which is the number that picks the wrong feature.
    for name, _ in sorted(CATEGORIES, key=lambda c: (-sole[c[0]], -touches[c[0]], c[0])):
        if not touches[name]:
            continue
        w('  %-32s %8d %8s %8d %9s\n' % (
            name, touches[name], pct(touches[name], considered),
            sole[name], pct(sole[name], blocked)))
    if not blocked:
        w('  (nothing is blocked in this corpus)\n')
    else:
        w('\n  SOLE = methods for which this is the ONLY refusal. "% unlock" is that\n')
        w('  count over the BLOCKED population: what closing this one category alone\n')
        w('  would move. Categories overlap, so the "methods" column does not sum to\n')
        w('  the blocked total and the "SOLE" column does not sum to it either --\n')
        w('  the remainder is methods blocked by two or more categories at once.\n')

    # D0.3 -- WHAT THE `this` CATEGORY IS ACTUALLY MADE OF.
    #
    # One reason string, several mechanisms. Reported because the first reading
    # of this census ranked `receiver.unconsumed_this` top by a wide margin, and
    # a sample of the sole-blocked methods turned out to be `bgBuilder:
    # _buildBg` and `onPointerSignal: _handleTrackpadEvent` -- METHOD TEAR-OFFS,
    # not a receiver escaping. Those are separate features with separate costs
    # and must not be ranked as one line.
    this_rows = [r for r in rows if any(
        canonical(u, r['target']) == 'receiver.unconsumed_this'
        for u in r['unsupported'])]
    if this_rows:
        parents, sole_parents = Counter(), Counter()
        for r in this_rows:
            for name, n in (r.get('unconsumedThisParents') or {}).items():
                parents[name] += n
            cs = {canonical(u, r['target']) for u in r['unsupported']}
            if cs == {'receiver.unconsumed_this'}:
                for name in (r.get('unconsumedThisParents') or {}):
                    sole_parents[name] += 1
        w('\n  INSIDE receiver.unconsumed_this -- by the PARENT of each `this`\n')
        w('  %-34s %10s %12s\n' % ('kernel parent node', 'occurrences',
                                    'sole-blocked'))
        w('  %s\n' % ('-' * 60))
        for name, n in parents.most_common():
            w('  %-34s %10d %12d\n' % (name, n, sole_parents[name]))
        w('\n  InstanceTearOff is `onPressed: _handleTap` -- `this` is the RECEIVER\n')
        w('  of a tear-off, and the lowered spelling is the same textual edit as a\n')
        w('  read. Arguments/VariableDeclaration/ReturnStatement are the receiver\n')
        w('  genuinely escaping. Raw node names, so an unexamined shape cannot hide.\n')

    # ---- D0.3 CORRECTION: rank CONSTRUCTS, not reason strings ------------
    #
    # `super.go()` emits TWO refusals -- `calls `super.go()`` and `uses `this`
    # other than to read a member` -- from ONE construct, because the CFE puts a
    # ThisExpression inside SuperMethodInvocation. Verified on a probe whose
    # source contains no `this` at all.
    #
    # Read off the raw table above, that artifact says super has 0% marginal
    # unlock (it always "co-occurs" with the `this` refusal it generates itself)
    # and inflates the `this` category with 43 methods that are really super
    # calls. Both readings are wrong, and both point a roadmap the wrong way.
    #
    # So constructs are attributed once each. THIS is the table to plan from.
    def constructs(r):
        cs = set()
        parents = set((r.get('unconsumedThisParents') or {}).keys())
        for u in r['unsupported']:
            c = canonical(u, r['target'])
            if c.startswith('receiver.super_'):
                cs.add('construct.super')
            elif c == 'receiver.unconsumed_this':
                continue          # attributed by parent, just below
            else:
                cs.add(c)
        if any(n.startswith('Super') for n in parents):
            cs.add('construct.super')
        if 'InstanceTearOff' in parents:
            cs.add('construct.method_tearoff')
        if any(not n.startswith('Super') and n != 'InstanceTearOff'
               for n in parents):
            cs.add('construct.this_escape')
        return cs

    ctouch, csole = Counter(), Counter()
    for r in rows:
        cs = constructs(r)
        for c in cs:
            ctouch[c] += 1
        if len(cs) == 1:
            csole[next(iter(cs))] += 1
    w('\n  CONSTRUCTS, attributed once each  <-- PLAN FROM THIS TABLE\n')
    w('  %-32s %8s %8s %8s %9s\n' % ('construct', 'methods', '% of all',
                                      'SOLE', '% unlock'))
    w('  %s\n' % ('-' * 74))
    for name in sorted(ctouch, key=lambda c: (-csole[c], -ctouch[c], c)):
        w('  %-32s %8d %8s %8d %9s\n' % (
            name, ctouch[name], pct(ctouch[name], considered),
            csole[name], pct(csole[name], blocked)))

    pairs = Counter()
    for cs in cats:
        for a, b in combinations(sorted(cs), 2):
            pairs[(a, b)] += 1
    if pairs:
        w('\n  TOP BLOCKER CO-OCCURRENCES\n')
        for (a, b), n in pairs.most_common(8):
            w('  %6d   %s + %s\n' % (n, a, b))
        w('\n  These are why raw prevalence misleads: a pair that co-occurs often is a\n')
        w('  pair where closing either one alone unlocks almost nothing.\n')

    # D-HYGIENE, informational. Not a refusal and must never be ranked as one.
    known = [r for r in rows if r['needsAlphaRename'] is not None]
    renames = sum(1 for r in known if r['needsAlphaRename'])
    lowerable_renames = sum(
        1 for r in known if r['needsAlphaRename'] and r['lowerable'])
    w('\n  D-HYGIENE EXERCISE COUNT (informational -- NOT a blocker)\n')
    w('    declarations spelling `self`   %6d of %d with readable source\n'
      % (renames, len(known)))
    w('      of those, lowerable now      %6d\n' % lowerable_renames)
    w('    These lower CORRECTLY; they cost a capture-avoiding receiver rename.\n')
    w('    Counting them as unsupported would put a solved problem back into the\n')
    w('    ranking. The test is the producer\'s own conservative substring scan, so\n')
    w('    it over-triggers on comments and on names like `selfTest`.\n')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--corpus', action='append', required=True,
                    help='label|kind|path.jsonl')
    ap.add_argument('--exclude-generated', action='store_true',
                    help='drop rows whose SOURCE FILE carries a codegen marker; '
                         'applied identically to every corpus')
    ap.add_argument('--exclude', action='append', default=[],
                    help='drop rows whose target contains this substring; '
                         'applied identically to every corpus')
    ap.add_argument('--out')
    args = ap.parse_args()

    import io
    buf = io.StringIO()
    buf.write(DISCLAIMER)
    for spec in args.corpus:
        label, kind, path = spec.split('|', 2)
        report(label, kind, path, buf, tuple(args.exclude),
               args.exclude_generated)
    text = buf.getvalue()
    if args.out:
        with open(args.out, 'w') as handle:
            handle.write(text)
    else:
        sys.stdout.write(text)


if __name__ == '__main__':
    main()
