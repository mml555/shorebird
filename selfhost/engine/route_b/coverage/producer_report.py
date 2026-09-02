#!/usr/bin/env python3
"""D-PRODUCER-DEMAND-1. The producer-truth number over D-DEMAND-1's corpus.

Three buckets, as ruled:

    analyzer refuses                    already-known incompatibility
    analyzer accepts, producer refuses  MEASUREMENT / PRODUCT PARITY GAP
    producer accepts                    real patch-demand compatibility

The corpus is not re-selected: windows, pairs, changed methods and weighting all
come from `demand_report.analyse` unchanged. This stage only adds what the
shipping producer said about each analyzer-admissible method, replayed against
the RELEASE's own generated capability manifest.
"""
import argparse
import os
import re
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from demand_report import analyse  # noqa: E402

# Exact causes, matched on the producer's own reason text. Ordered: the first
# match wins, so the specific patterns precede the general ones.
CAUSES = [
    ('private_type_reference',
     re.compile(r'private identifier this analysis did not resolve')),
    ('capability_no_manifest',
     re.compile(r'published no capability manifest')),
    ('capability_not_granted',
     re.compile(r'did not retain|not retained|not emitted|was built to keep|'
                r'manifest shows|skipped set|unconditional')),
    # The producer's own receiver-rewriting limit, which the analyzer's
    # `unsupported` list did not raise for this body. A distinct gap from a
    # capability one and from a private type.
    ('receiver_rewrite',
     re.compile(r'through a receiver this lowering cannot rewrite')),
    ('abi_shape', re.compile(r'named parameters|optional positional|generic|'
                             r'^[A-Z_]+\d* ')),
    ('receiver_construct', re.compile(r'uses `this` other than to read')),
    ('super_narrow_v1', re.compile(r'super|direct-super')),
    ('binding_or_survival', re.compile(r'survival|binding|receipt|shape change')),
    ('compiler_or_linking', re.compile(r'compil|link|bytecode|snapshot')),
    ('source_slicing_or_import',
     re.compile(r'parameter list could not be found|source span runs past|'
                r'RELATIVE import|source|span|offset|import')),
]


def cause_of(reason):
    for name, pattern in CAUSES:
        if pattern.search(reason):
            return name
    return 'other'


def load_producer(work):
    """target -> reason, plus the set of pairs whose remainder passed."""
    refused, passed_pairs, seen_pairs = {}, set(), set()
    d = os.path.join(work, 'producer')
    if not os.path.isdir(d):
        return refused, passed_pairs, seen_pairs
    for name in sorted(os.listdir(d)):
        if not name.endswith('.txt'):
            continue
        pair = name[:-4]
        seen_pairs.add(pair)
        for line in open(os.path.join(d, name), errors='replace'):
            if line.startswith('  REFUSE\t'):
                _, target, reason = line.rstrip('\n').split('\t', 2)
                refused[target] = reason
            elif 'admission passed for the remainder: true' in line:
                passed_pairs.add(pair)
    return refused, passed_pairs, seen_pairs


def pct(n, d):
    return '--' if not d else '%.2f%%' % (100.0 * n / d)


def report(label, work, w):
    a = analyse(work, label)
    refused_map, passed_pairs, seen_pairs = load_producer(work)

    obs = [o for o in a['obs'] if o['pair'] in seen_pairs]
    changed = len(obs)
    analyzer_refused = [o for o in obs if not o['admissible']]
    analyzer_ok = [o for o in obs if o['admissible']]
    parity_gap = [o for o in analyzer_ok if o['target'] in refused_map]
    producer_ok = [o for o in analyzer_ok if o['target'] not in refused_map]

    w('\n' + '-' * 78 + '\n%s\n' % label + '-' * 78 + '\n')
    w('  pairs replayed %d of %d with a changed method\n'
      % (len(seen_pairs & {p['pair'] for p in a['pairs'] if p['changed']}),
         len([p for p in a['pairs'] if p['changed']])))
    w('\n  %-42s %8s %10s\n' % ('Bucket', 'Count', '% changed'))
    w('  %s\n' % ('-' * 64))
    w('  %-42s %8d %10s\n' % ('analyzer refuses', len(analyzer_refused),
                              pct(len(analyzer_refused), changed)))
    w('  %-42s %8d %10s\n' % ('analyzer accepts, PRODUCER REFUSES',
                              len(parity_gap), pct(len(parity_gap), changed)))
    w('  %-42s %8d %10s\n' % ('producer accepts', len(producer_ok),
                              pct(len(producer_ok), changed)))
    w('  %s\n' % ('-' * 64))
    w('  %-42s %8d\n' % ('changed methods replayed', changed))
    w('  %-42s %10s   <-- analyzer upper bound\n'
      % ('analyzer-level compatibility',
         pct(len(analyzer_ok), changed)))
    w('  %-42s %10s   <-- PRODUCER TRUTH\n'
      % ('producer-level compatibility', pct(len(producer_ok), changed)))

    if parity_gap:
        w('\n  ANALYZER->PRODUCER DISAGREEMENTS, by exact cause\n')
        causes = Counter(cause_of(refused_map[o['target']]) for o in parity_gap)
        w('  %-34s %8s %10s\n' % ('cause', 'methods', '% of gap'))
        w('  %s\n' % ('-' * 56))
        for c, n in causes.most_common():
            w('  %-34s %8d %10s\n' % (c, n, pct(n, len(parity_gap))))
        w('\n  the disagreeing methods:\n')
        for o in parity_gap[:12]:
            w('    %-46s %s\n' % (o['target'].split('#')[-1][:44],
                                  cause_of(refused_map[o['target']])))

    # Producer-level refusal taxonomy: analyzer refusals keep their construct
    # attribution; parity-gap refusals are named by the producer's own cause.
    w('\n  PRODUCER-LEVEL REFUSAL TAXONOMY (every refused method)\n')
    tax = Counter()
    for o in analyzer_refused:
        for c in o['cats']:
            tax['analyzer:' + c] += 1
    for o in parity_gap:
        tax['producer:' + cause_of(refused_map[o['target']])] += 1
    total_refused = len(analyzer_refused) + len(parity_gap)
    w('  %-42s %8s %10s\n' % ('reason', 'methods', '% refused'))
    w('  %s\n' % ('-' * 64))
    for c, n in tax.most_common():
        w('  %-42s %8d %10s\n' % (c, n, pct(n, total_refused)))
    return {'label': label, 'changed': changed, 'analyzer_ok': len(analyzer_ok),
            'producer_ok': len(producer_ok), 'gap': len(parity_gap),
            'obs': obs, 'refused_map': refused_map, 'parity_gap': parity_gap}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--corpus', action='append', required=True,
                    help='label|workdir')
    ap.add_argument('--out')
    args = ap.parse_args()
    out = open(args.out, 'w') if args.out else sys.stdout
    w = out.write
    w('=' * 78 + '\n')
    w('D-PRODUCER-DEMAND-1 -- the producer-truth number over D-DEMAND-1\'s\n')
    w('exact corpus. Capabilities come from each RELEASE\'s own generated\n')
    w('manifest, never from the candidate\'s source.\n')
    w('=' * 78 + '\n')
    for spec in args.corpus:
        label, work = spec.split('|', 1)
        report(label, work, w)
    if args.out:
        out.close()


if __name__ == '__main__':
    main()
