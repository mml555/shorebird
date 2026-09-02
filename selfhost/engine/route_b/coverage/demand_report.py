#!/usr/bin/env python3
"""D-DEMAND-1. Real patch demand: could Route B carry the changes developers
actually made?

UNIT: one instance method whose BODY changed between two adjacent first-parent
commits, classified against its own actual preceding version as the release.
Not lines, not construct occurrences, not every method that exists, never a
synthetic mutation.

WHERE EACH FACT COMES FROM, because they come from different places and mixing
them up would misattribute:

  unsupported reasons, super sites, releaseSuperTargets
      the PAIR document (`--base-dill` release, `--patched-dill` candidate).
      This is the product's own release-vs-candidate path, and the only place
      release evidence exists.
  unconsumedThisParents
      the CANDIDATE's census row. The pair document does not carry it, and
      without it D0.3's split of `uses this other than to read a member` into
      tear-off versus genuine escape cannot be made -- the split that stopped
      the roadmap being pointed at the wrong construct.
  super source shape
      `demand_shapes.py`, from `git show <commit>:<path>` through the product's
      own fail-closed scanner.
  introduced versus pre-existing
      the BASE's census row for the same target.

Pair-level refusals (`added`/`removed` members) are their own category: they
refuse a patch even when every changed method lowers, so counting them as
per-method blockers would be wrong.
"""
import argparse
import json
import os
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import census_report as cr  # noqa: E402


def key(t):
    if not t:
        return None
    return (t.get('fileUri'), t.get('fileOffset'), t.get('name'), t.get('kind'))


def load_census(path):
    if not os.path.exists(path):
        return None
    rows = {}
    for i, line in enumerate(open(path)):
        if i == 0 or not line.strip():
            continue
        r = json.loads(line)
        rows[r['target']] = r
    return rows


def super_verdict(low, target, commit, shapes):
    """(has_sites, admissible, why_not) for one changed method."""
    sites = low.get('superInvocations') or []
    if not sites:
        return (False, True, None)
    got = [shapes.get(f'{commit}|{target}|{s["offset"]}') for s in sites]
    if any(g != 'zeroArguments' for g in got):
        bad = sorted({g or 'unclassified' for g in got if g != 'zeroArguments'})
        return (True, False, 'shape:' + ','.join(bad))
    if 'releaseSuperTargets' not in low:
        return (True, False, 'measurement_absent')
    measured = {key(t) for t in (low.get('releaseSuperTargets') or [])}
    for s in sites:
        k = key(s.get('target'))
        if k is None:
            return (True, False, 'target_unresolved')
        if k not in measured:
            return (True, False, 'target_disagreement')
    return (True, True, None)


def analyse(work, label):
    window = [l.strip() for l in open(os.path.join(work, 'window.txt')) if l.strip()]
    by_prefix = {s[:8]: s for s in window}
    censuses = {}

    def census(sha):
        if sha not in censuses:
            censuses[sha] = load_census(os.path.join(work, 'census', f'{sha}.jsonl'))
        return censuses[sha]

    shapes = {}
    sp = os.path.join(work, 'shapes.json')
    if os.path.exists(sp):
        shapes = json.load(open(sp))['shapes']

    obs = []                     # one entry per changed method
    pair_rows = []               # one entry per pair
    pairs_dir = os.path.join(work, 'pairs')
    for name in sorted(os.listdir(pairs_dir)):
        if not name.endswith('.json'):
            continue
        bp, cp = name[:-5].split('_')
        base, cand = by_prefix.get(bp), by_prefix.get(cp)
        doc = json.load(open(os.path.join(pairs_dir, name)))
        base_c, cand_c = census(base), census(cand)

        changed = doc.get('changed') or []
        added = doc.get('added') or []
        removed = doc.get('removed') or []
        pair_cats = set()
        # The analyzer's own buckets are about REACHABILITY and call shape, not
        # about lowering: `representable` is a static-shaped call, `conditional`
        # an instance member whose devirtualization cannot be decided from the
        # kernel, and `unreachable` means the release cannot reach the member at
        # all. The producer only ever considers representable + conditional
        # (`route_b_producer.produce`), so a changed method outside those is
        # refused for a REACHABILITY reason and must not be reported as a
        # lowering blocker.
        # The DOCUMENT key is `patchable`; `representable` is what the parsed
        # Dart field is called. Reading the field name here silently made every
        # static-shaped change look unreachable, which showed up as an
        # implausible top refusal category.
        reachable = set(doc.get('patchable') or []) | set(
            doc.get('conditional') or [])
        unreachable = set(doc.get('unreachable') or [])
        unknown_reach = set(doc.get('unknown') or [])

        for target in changed:
            low = (doc.get('lowering') or {}).get(target) or {}
            unsupported = low.get('unsupported') or []
            has_super, super_ok, super_why = super_verdict(low, target, cand, shapes)
            admissible = not unsupported and super_ok

            # D0.3's attribution, on a row carrying the candidate's parent
            # classification. `superInvocations` is set to 0 when narrow-v1
            # admits the site, so an admitted super is not reported as a
            # blocker -- the same adjustment D-CENSUS-2 makes.
            crow = (cand_c or {}).get(target) or {}
            row = {
                'target': target,
                'unsupported': unsupported,
                'superInvocations': 0 if super_ok else 1,
                'unconsumedThisParents': crow.get('unconsumedThisParents') or {},
            }
            cats = set(cr.constructs(row))
            if super_ok:
                cats.discard('construct.super')
            if target in unreachable:
                cats.add('reach.unreachable')
            elif target in unknown_reach:
                cats.add('reach.unknown')
            elif target not in reachable:
                cats.add('reach.not_offered')
            admissible = admissible and target in reachable

            # Introduced or pre-existing: was the same construct already in the
            # RELEASE version of this same method?
            brow = (base_c or {}).get(target)
            if brow is None:
                origin = 'base_row_missing'
            else:
                brow_cats = set(cr.constructs({
                    'target': target,
                    'unsupported': brow.get('unsupported') or [],
                    'superInvocations': brow.get('superInvocations') or 0,
                    'unconsumedThisParents': brow.get('unconsumedThisParents') or {},
                }))
                origin = {c: ('pre_existing' if c in brow_cats else 'introduced')
                          for c in cats}

            obs.append({
                'pair': name[:-5], 'base': base, 'cand': cand, 'target': target,
                'admissible': admissible, 'cats': cats, 'super_why': super_why,
                'has_super': has_super, 'origin': origin,
            })
            if not admissible:
                pair_cats |= cats

        if added or removed:
            pair_cats.add('pair.member_set_changed')

        pair_rows.append({
            'pair': name[:-5], 'base': base, 'cand': cand,
            'changed': len(changed), 'added': len(added), 'removed': len(removed),
            'verdict': doc.get('verdict'), 'cats': pair_cats,
            'refused': sum(1 for o in obs if o['pair'] == name[:-5]
                           and not o['admissible']),
        })

    return {'label': label, 'obs': obs, 'pairs': pair_rows, 'window': window}


def pct(n, d):
    return '--' if not d else '%.2f%%' % (100.0 * n / d)


def report(a, w):
    obs, pairs = a['obs'], a['pairs']
    changed = len(obs)
    adm = sum(1 for o in obs if o['admissible'])
    refused = changed - adm
    active = [p for p in pairs if p['changed']]

    w('\n' + '-' * 78 + '\n%s\n' % a['label'] + '-' * 78 + '\n')
    w('  window %d commits, %d pairs, %d with a changed method\n'
      % (len(a['window']), len(pairs), len(active)))
    w('\n  %-32s %8s\n' % ('Metric', 'Count'))
    w('  %s\n' % ('-' * 42))
    w('  %-32s %8d\n' % ('changed Dart instance methods', changed))
    w('  %-32s %8d\n' % ('Route B admissible', adm))
    w('  %-32s %8d\n' % ('refused', refused))
    w('  %-32s %8s\n' % ('patch-demand compatibility %', pct(adm, changed)))

    if not changed:
        return

    # ---- refusal ranking, method-weighted ----
    touch, sole = Counter(), Counter()
    for o in obs:
        if o['admissible']:
            continue
        for c in o['cats']:
            touch[c] += 1
        if len(o['cats']) == 1:
            sole[next(iter(o['cats']))] += 1
    w('\n  REFUSAL RANKING (method-weighted)\n')
    w('  %-34s %8s %8s %11s\n'
      % ('refusal reason', 'methods', 'SOLE', '% refused'))
    w('  %s\n' % ('-' * 66))
    for c in sorted(touch, key=lambda x: (-sole[x], -touch[x], x)):
        w('  %-34s %8d %8d %11s\n' % (c, touch[c], sole[c], pct(sole[c], refused)))

    # ---- commit-weighted ----
    cw = Counter()
    for p in pairs:
        for c in p['cats']:
            cw[c] += 1
    w('\n  REFUSAL RANKING (commit-weighted: pairs containing the reason)\n')
    w('  %-34s %8s %11s\n' % ('refusal reason', 'pairs', '% pairs'))
    w('  %s\n' % ('-' * 56))
    for c in sorted(cw, key=lambda x: (-cw[x], x)):
        w('  %-34s %8d %11s\n' % (c, cw[c], pct(cw[c], len(active))))

    # ---- introduced vs pre-existing ----
    intro, pre, unknown = Counter(), Counter(), Counter()
    for o in obs:
        if o['admissible']:
            continue
        if o['origin'] == 'base_row_missing':
            for c in o['cats']:
                unknown[c] += 1
            continue
        for c, kind in o['origin'].items():
            (intro if kind == 'introduced' else pre)[c] += 1
    w('\n  INTRODUCED vs PRE-EXISTING (per refused method)\n')
    w('  %-34s %11s %13s %9s\n'
      % ('construct', 'introduced', 'pre-existing', 'unknown'))
    w('  %s\n' % ('-' * 70))
    for c in sorted(set(intro) | set(pre) | set(unknown),
                    key=lambda x: -(intro[x] + pre[x])):
        w('  %-34s %11d %13d %9d\n' % (c, intro[c], pre[c], unknown[c]))
    w('    pre-existing = the developer did not touch the construct; Route B\n')
    w('    refuses the whole method anyway. Real pain, different cause.\n')

    # ---- largest contributing commits ----
    w('\n  LARGEST CONTRIBUTING PAIRS (so one refactor cannot hide as N methods)\n')
    w('  %-20s %8s %9s  %s\n' % ('pair', 'changed', 'refused', 'verdict'))
    w('  %s\n' % ('-' * 60))
    for p in sorted(active, key=lambda x: -x['changed'])[:6]:
        w('  %-20s %8d %9d  %s\n'
          % (p['pair'], p['changed'], p['refused'], p['verdict']))
    biggest = max(active, key=lambda x: x['changed']) if active else None
    if biggest:
        w('    largest single pair is %s with %d of %d changed methods (%s)\n'
          % (biggest['pair'], biggest['changed'], changed,
             pct(biggest['changed'], changed)))

    # ---- super detail ----
    sup = [o for o in obs if o['has_super']]
    if sup:
        w('\n  SUPER in changed methods\n')
        w('    changed methods containing a super site   %6d\n' % len(sup))
        w('    narrow-v1 admissible                      %6d\n'
          % sum(1 for o in sup if o['super_why'] is None))
        whys = Counter(o['super_why'] for o in sup if o['super_why'])
        for k2, v in whys.most_common():
            w('      %-38s %6d\n' % (k2, v))
        div = [o for o in sup if o['super_why'] in
               ('target_disagreement', 'target_unresolved', 'measurement_absent')]
        w('    TARGET-EVIDENCE divergences (real, not manufactured) %6d\n' % len(div))
        for o in div[:5]:
            w('      %s  %s  %s\n' % (o['pair'], o['target'].split('#')[-1],
                                      o['super_why']))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--corpus', action='append', required=True,
                    help='label|workdir')
    ap.add_argument('--out')
    args = ap.parse_args()
    out = open(args.out, 'w') if args.out else sys.stdout
    w = out.write
    w('=' * 78 + '\n')
    w('D-DEMAND-1 -- could Route B carry the changes developers actually made?\n')
    w('Unit: one instance method whose BODY changed between adjacent commits.\n')
    w('=' * 78 + '\n')
    results = []
    for spec in args.corpus:
        label, work = spec.split('|', 1)
        a = analyse(work, label)
        results.append(a)
        report(a, w)
    if args.out:
        out.close()


if __name__ == '__main__':
    main()
