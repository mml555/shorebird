#!/usr/bin/env python3
"""compat_taxonomy.py -- the study's classification, kept apart from the run.

Separated so `compat_reclassify.py` can rederive every recorded row after the
taxonomy changes, without recompiling a kernel. Phase 0 changed it twice; that
cost seconds because of this split.

Three things are recorded per blocker and never merged:

    raw       the analyzer's own words, verbatim
    category  what kind of construct it is
    policy    what KIND OF PROBLEM it is, which is what decides remediation
    subtype   the distinction within a policy that would otherwise be lost

Policies, and why they are separate:

    model       the synthetic-library / privacy model itself. A replacement
                library cannot name another library's private members at all.
                Fixing this means changing what a payload IS.
    abi         signature, arity, calling convention. The entry-point contract
                has already been widened once (0 -> 0-or-1 positional), so this
                is a contract question, not a wall.
    structural  the change requires the program's structure to change -- a
                member added or removed, or a target that is not in the shipped
                program. A patch replaces bodies; it does not restructure.
    deliberate  could be built, decided not to. See the frozen surface in
                ROUTE_B.md.
    not-yet     an implementation gap inside an otherwise-supported model.
"""
import re

# EXACT MATCH ONLY, against the closed set of strings analyze_coverage.dart can
# emit. Anything unmatched stays `other`/`unclassified` and is printed; a
# classifier that quietly folds the unrecognized into a known bin is how a study
# reports confidence it has not earned.
LOWERING_RULES = [
    (re.compile(r'^reads the private member '),
     'private-app-member', 'model', 'private-read'),
    (re.compile(r'^assigns to the private member '),
     'private-app-member', 'model', 'private-write'),
    (re.compile(r'^calls the private member '),
     'private-app-member', 'model', 'private-call'),

    (re.compile(r'^the method takes parameters'),
     'signature-arity', 'abi', 'entry-point-arity'),
    (re.compile(r'^the method is generic$'),
     'signature-arity', 'abi', 'generic-method'),

    (re.compile(r'^reads `super\.'), 'super', 'deliberate', 'super-read'),
    (re.compile(r'^calls `super\.'), 'super', 'deliberate', 'super-call'),
    (re.compile(r'^assigns to `super\.'), 'super', 'deliberate', 'super-write'),
    (re.compile(r'^reads and writes .* in one expression'),
     'compound-write', 'deliberate', 'compound-write'),
    # Cascades produce this exact string and are NOT separable from `this` being
    # captured, passed or stored. One bucket, because that is what the analyzer
    # actually says -- a cascade count here would be invented.
    (re.compile(r'^uses `this` other than to read a member$'),
     'this-escape', 'deliberate', 'this-escape-or-cascade'),
    (re.compile(r'^is the receiver$'),
     'this-escape', 'deliberate', 'this-escape-or-cascade'),

    (re.compile(r'^invokes the getter .* on the receiver$'),
     'getter-invocation', 'not-yet', 'getter-invocation'),
]

# The analyzer labels these itself, so they need no string matching.
REJECTION_CATEGORY = {
    'added': ('added-member', 'structural', 'added'),
    'unreachable': ('unreachable-target', 'structural', 'unreachable'),
    'unknown': ('dispatch-table-unknown', 'not-yet', 'dispatch-table'),
}
REMOVED = ('removed-member', 'structural', 'removed')

POLICIES = ('model', 'abi', 'structural', 'deliberate', 'not-yet', 'unclassified')


def classify(raw):
    """(category, policy, subtype) for one verbatim analyzer reason."""
    for pattern, category, policy, subtype in LOWERING_RULES:
        if pattern.search(raw):
            return category, policy, subtype
    return 'other', 'unclassified', 'other'


def blockers_for(raw_analysis):
    """Every blocker in one analysis, with raw preserved beside the derivation.

    A lowering refusal only BLOCKS if the producer would have to emit that
    target, so the emit set gates it. Rejections and removals are inherently
    about the changed set and always count.
    """
    emit = (set(raw_analysis.get('patchable') or [])
            | set(raw_analysis.get('conditional') or []))
    out = []
    for rej in raw_analysis.get('rejections') or []:
        cat, pol, sub = REJECTION_CATEGORY.get(
            rej.get('category'), ('other', 'unclassified', 'other'))
        out.append({'target': rej.get('target'), 'raw': rej.get('reason'),
                    'source': 'rejection', 'category': cat, 'policy': pol,
                    'subtype': sub})
    for target, low in (raw_analysis.get('lowering') or {}).items():
        if target not in emit:
            continue
        for reason in low.get('unsupported') or []:
            cat, pol, sub = classify(reason)
            out.append({'target': target, 'raw': reason, 'source': 'lowering',
                        'category': cat, 'policy': pol, 'subtype': sub})
    for target in raw_analysis.get('removed') or []:
        cat, pol, sub = REMOVED
        out.append({'target': target, 'raw': 'member removed by the change',
                    'source': 'removed', 'category': cat, 'policy': pol,
                    'subtype': sub})
    return out, emit


def outcomes_for(raw_analysis):
    """THREE outcomes, never collapsed into one.

    Phase 0's mistake: the coverage verdict is not publishability. It is
    computed from unreachable/unknown/added targets and does not consider
    whether a representable target can be LOWERED, so it returns `accept` for
    patches the producer then refuses. Recording both separately is the only way
    to count that correctly without pretending the analyzer made a stronger
    claim than it did.
    """
    emit = (set(raw_analysis.get('patchable') or [])
            | set(raw_analysis.get('conditional') or []))
    unlowerable = sorted(
        t for t, low in (raw_analysis.get('lowering') or {}).items()
        if t in emit and (low.get('unsupported') or []))

    coverage = raw_analysis.get('verdict')            # accept | reject | inert
    producer = 'refused' if unlowerable else 'ok'
    publishable = coverage == 'accept' and producer == 'ok'

    if coverage == 'inert':
        terminal = 'inert'
    elif publishable:
        terminal = 'publishable'
    elif coverage != 'accept':
        terminal = 'coverage-rejected'
    else:
        terminal = 'producer-refused'

    return {
        'coverage_verdict': coverage,
        'producer_verdict': producer,
        'publishable': publishable,
        'outcome': terminal,
        'unlowerable_emit_targets': unlowerable,
        'representable': len(emit),
        'representable_and_lowerable': len(emit) - len(unlowerable),
    }
