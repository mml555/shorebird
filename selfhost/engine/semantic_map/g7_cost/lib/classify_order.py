#!/usr/bin/env python3
"""The order-dependence rule, in one testable place.

Extracted from run_g7.sh so it can be controlled deterministically. #57
requires three sensitivity controls on this classifier, and a rule embedded in
a shell heredoc cannot be exercised without running a seven-minute measurement.

THE RULE. A stage is order-dependent only when BOTH hold:

    the two order-medians differ by more than 10%, AND
    the gap between them exceeds the run-to-run spread within those orders

The second clause is the load-bearing one. A bare ratio test flagged five
stages on one run, zero on the next and four on the next, from identical code:
that is machine drift presenting as a per-stage property, which is the exact
confound SL1 reported. Below the noise floor the difference is
indistinguishable from drift and is reported as such.

THIS IS A COST DIAGNOSTIC, NOT A SAFETY CLAIM. `max(stdev(A), stdev(B))` is a
heuristic noise floor. It supports "do not quote this median" and nothing
about causality.

VALIDATION IS FAIL-CLOSED. A stage missing one schedule side is UNDECIDABLE,
never "unaffected" -- the absence of a comparison is not the absence of an
effect.
"""


def classify(a, z):
    """a, z: per-order stats dicts with median_ms, stdev_ms, n.

    Returns a verdict dict. `order_dependent` is True only when the effect
    exceeds both the ratio threshold and the noise floor; `decidable` is False
    when either side has no samples.
    """
    if not a or not z or not a.get('n') or not z.get('n'):
        return {
            'decidable': False,
            'order_dependent': None,
            'why': 'one schedule side has no samples; an effect cannot be '
                   'ruled out, so this is undecidable rather than unaffected',
        }
    am, zm = a.get('median_ms'), z.get('median_ms')
    if not am:
        return {'decidable': False, 'order_dependent': None,
                'why': 'the base-first median is zero or absent'}
    ratio = zm / am
    gap = abs(zm - am)
    noise = max(a.get('stdev_ms') or 0.0, z.get('stdev_ms') or 0.0)
    exceeds_10pct = abs(ratio - 1) > 0.10
    exceeds_noise = gap > noise
    return {
        'decidable': True,
        'base_first_median_ms': am,
        'map_first_median_ms': zm,
        'ratio': round(ratio, 3),
        'gap_ms': round(gap, 1),
        'within_order_spread_ms': round(noise, 1),
        'exceeds_10pct': bool(exceeds_10pct),
        'exceeds_noise_floor': bool(exceeds_noise),
        'order_dependent': bool(exceeds_10pct and exceeds_noise),
    }
