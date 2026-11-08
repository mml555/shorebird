#!/usr/bin/env python3
"""D-DEMAND-3 stage 3: blocker attribution and single-feature unlock counts.

Reads the measured chains (chains.json) and the release manifests. Computes,
PER CORPUS and never pooled:

  * every refused observation's full blocker chain, categorised A/B/C/D;
  * sole-blocked vs multi-blocked;
  * for each candidate feature, how many observations become PRODUCIBLE if
    exactly that one blocker is solved and nothing else.

An unlock requires the probe to have reached admission (ADMITTED true) after
relaxing exactly that blocker, OR to have terminated on the private-reference
text backstop, which is the final admission gate in `_lower`.
"""
import json, sys
from collections import Counter, defaultdict

CH = json.load(open('/Volumes/build/route-b/demand1/chains.json'))
APP = {'Wonderous': 'wonderous', 'LocalSend': 'localsend'}

# reason substring -> (blocker id, category, candidate feature name)
CLASSES = [
    ('reads and writes', 'compound_same_offset', 'A', 'compound read+write at one offset'),
    ('the method takes named parameters', 'named_parameters', 'A', 'named parameters'),
    ('optional positional', 'optional_positionals', 'A', 'optional positionals'),
    ('other than to read a member', 'unconsumed_this', 'A', 'method tear-off / this-escape'),
    ('through a receiver this lowering cannot rewrite safely', 'receiver_rewrite', 'A', 'receiver rewrite'),
    ('a private identifier this analysis did not', 'private_reference', 'A', 'private method/top-level/type reference'),
    ('which this release did not retain', 'retention', 'B', 'retention (release evidence)'),
    ('published no capability manifest', 'no_manifest', 'B', 'retention (release evidence)'),
    ('never constructed', 'introduced_private_construction', 'C', 'candidate-introduced private construction'),
]


def classify(reason):
    """EVERY class this reason matches, not just the first.

    `_lower` refuses on the whole `unsupported` list at once and joins it with
    '; ', so one refusal string can carry several distinct constructs --
    `_RangeSelectorState._getHandle` carries named parameters AND two
    unconsumed-`this` uses. Returning only the first match dropped the tear-off
    from that observation's chain and would have understated what it needs.
    """
    hits = [(bid, cat, feature) for needle, bid, cat, feature in CLASSES
            if needle in reason]
    return hits or [('unclassified', 'D', 'UNCLASSIFIED — ' + reason[:60])]


def manifest_has(app, base, name):
    m = json.load(open(f'/Volumes/build/route-b/demand1/{app}/manifest13/{base}.manifest.json'))
    for field, v in m.items():
        if not isinstance(v, list):
            continue
        for k in v:
            tail = k.split('#')[-1]
            if tail == name or tail == name + '.new':
                return field.replace('private', '')
    return None


rows_by_corpus = {}
for label, rows in CH.items():
    app = APP[label]
    out = []
    for r in rows:
        chain = []
        for b in r['blockers']:
            for bid, cat, feature in classify(b['reason']):
                chain.append({'id': bid, 'cat': cat, 'feature': feature,
                              'reason': b['reason']})
        term = str(r.get('terminal') or '')
        if r.get('admitted') == 'not_walked':
            chain.append({'id': 'reachability', 'cat': 'C',
                          'feature': 'reachability (release cannot reach it)',
                          'reason': term})
        # Was the backstop's identifier already retained by that release? If it
        # was, the missing piece is ANALYSIS RESOLUTION alone (A) and not
        # retention (B) -- the release evidence is already there.
        retained = None
        if 'PRIVATE_REFERENCE_TEXT_BACKSTOP' in term:
            name = term.split('(')[1].split(')')[0]
            retained = manifest_has(app, r['pair'].split('_')[0], name)
            for c in chain:
                if c['id'] == 'private_reference':
                    c['retained'] = retained
                    if retained is None:
                        # Needs resolution AND a retention-policy change: two
                        # blockers, so not a single-feature unlock.
                        c['cat'] = 'A+B'
                        c['feature'] = ('private reference + retention '
                                        '(NOT a single-feature unlock)')
        distinct = []
        for c in chain:
            if c['id'] not in [d['id'] for d in distinct]:
                distinct.append(c)
        admitted = r.get('admitted') == 'true'
        backstop_final = r.get('backstop_final') == 'true'
        out.append({
            'pair': r['pair'], 'target': r['target'],
            'short': r['target'].split('#')[-1],
            'analyzer_admissible': r['analyzer_admissible'],
            'analyzer_cats': r['analyzer_cats'],
            'chain': distinct,
            'n_blockers': len(distinct),
            'sole': len(distinct) == 1,
            'admitted_in_own_pair': admitted and not distinct,
            'admits_after_chain': admitted or backstop_final,
            'backstop_final': backstop_final,
        })
    rows_by_corpus[label] = out


def w(s=''):
    print(s)


w('=' * 96)
w('D-DEMAND-3 — refusal attribution on the frozen stack. Per corpus, never pooled.')
w('=' * 96)

unlocks = defaultdict(lambda: defaultdict(int))
for label, rows in rows_by_corpus.items():
    real = len([r for r in rows if not r['admitted_in_own_pair']])
    w()
    w('-' * 96)
    w(f'{label}: {len(rows)} observations counted refused by the frozen accounting')
    w('-' * 96)
    for r in rows:
        tag = ('SOLE' if r['sole'] else
               f"MULTI({r['n_blockers']})" if r['n_blockers'] else 'NONE')
        w(f"\n  {r['short'][:52]:54} [{r['pair']}]")
        w(f"    analyzer admissible {str(r['analyzer_admissible']):5}  "
          f"cats={r['analyzer_cats']}")
        for i, c in enumerate(r['chain']):
            extra = ''
            if c['id'] == 'private_reference':
                extra = ('  retained-by-release: '
                         + (c.get('retained') or 'NO'))
            w(f"    [{i}] {c['cat']:3} {c['id']:32}{extra}")
        w(f"    -> {tag}"
          + ('  ADMITTED IN ITS OWN PAIR (frozen accounting marks it refused '
             'because the same target was refused in another pair)'
             if r['admitted_in_own_pair'] else ''))
    # sole-blocked unlock counting
    for r in rows:
        if r['admitted_in_own_pair'] or not r['sole']:
            continue
        c = r['chain'][0]
        if c['cat'] in ('C', 'A+B'):
            # C is refused by design or unreachable; A+B needs two changes.
            # Both are reported, neither is a one-blocker unlock.
            continue
        unlocks[c['feature']][label] += 1

w()
w('=' * 96)
w('SOLE-BLOCKED vs MULTI-BLOCKED')
w('=' * 96)
w(f"  {'corpus':12} {'refused':8} {'admits in own pair':20} {'sole':6} {'multi':6}")
for label, rows in rows_by_corpus.items():
    mis = sum(1 for r in rows if r['admitted_in_own_pair'])
    sole = sum(1 for r in rows if r['sole'] and not r['admitted_in_own_pair'])
    multi = sum(1 for r in rows
                if not r['sole'] and not r['admitted_in_own_pair'])
    w(f"  {label:12} {len(rows):8} {mis:20} {sole:6} {multi:6}")

w()
w('=' * 96)
w('IF WE SOLVED EXACTLY ONE BLOCKER — observations that become producible')
w('=' * 96)
w(f"  {'candidate':46} {'Wonderous':>10} {'LocalSend':>10}")
w('  ' + '-' * 68)
for feature in sorted(unlocks, key=lambda f: -sum(unlocks[f].values())):
    w(f"  {feature:46} {unlocks[feature].get('Wonderous', 0):>10} "
      f"{unlocks[feature].get('LocalSend', 0):>10}")

w()
w('  Multi-blocked observations, and what they would ALL need:')
for label, rows in rows_by_corpus.items():
    for r in rows:
        if r['sole'] or r['admitted_in_own_pair']:
            continue
        need = ' + '.join(c['id'] for c in r['chain'])
        w(f"    {label:11} {r['short'][:44]:46} {need}")

w()
w('=' * 96)
w('THE PAIRED CASE — tear-off and private-reference resolution together')
w('=' * 96)
w('  Every unconsumed-`this` observation that is NOT unlocked alone lands on the')
w('  private-reference backstop naming the very member being torn off. Counted')
w('  here because it is the one combination the measurement forces on us; it is')
w('  TWO blockers, not one, and is reported as such.')
for label, rows in rows_by_corpus.items():
    both = [r for r in rows
            if not r['admitted_in_own_pair']
            and r['admits_after_chain']
            and {c['id'] for c in r['chain']} <= {'unconsumed_this',
                                                  'private_reference'}]
    retained_all = all(
        c.get('retained') for r in both for c in r['chain']
        if c['id'] == 'private_reference')
    w(f"  {label:11} {len(both):2} observations"
      + ('  (every named member ALREADY retained by its release)'
         if retained_all else '  (at least one needs a retention change too)'))

json.dump(rows_by_corpus, open('/Volumes/build/route-b/demand1/attribution.json', 'w'), indent=1)
