#!/usr/bin/env python3
"""Classify a Route B post-attach trace. One question, mechanically.

Exit codes, deliberately distinct so a chained caller cannot confuse them:
    0  Function::unchecked_entry_point_ moved to InterpretCall
    1  it did not move
    2  refused to classify (wrong format version, unparseable)
    3  undecided (a deciding field is missing)

    classify_routeb_trace.py <dlc.vmcode.routeb.trace> [--dsym <DWARF/App>]

WHY THIS IS A SCRIPT. The v1 trace was misread twice from the same hex: once by
comparing a Code accessor against a Function field, and once by treating an
address difference as a VM anomaly when it was a measurement defect. Eyeballing
addresses is how both happened. This does the comparison the same way every time
and refuses the cases it cannot decide.

IT REFUSES v1 RECORDS. In v1, `uep_*` meant Code::UncheckedEntryPoint(); in v2 it
means Function::unchecked_entry_point_. Comparing across that boundary produces
confident nonsense, so a v1 line is rejected rather than best-effort parsed.
"""
import argparse
import re
import subprocess
import sys

# The one field that decides this run. Named here so the decision cannot drift
# into prose: the failing call site loads Function::unchecked_entry_point_, so
# that is the field whose transition matters, not the normal entry point.
DECIDING = ('fn_uep_post', 'interpret_call_ep')

UNSET = -1


def parse(line):
    out = {}
    for k, v in re.findall(r'(\w+)=(\S+)', line):
        try:
            out[k] = int(v, 16) if v.startswith('0x') else int(v)
        except ValueError:
            out[k] = v
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('trace')
    ap.add_argument('--dsym', help='DWARF/App from the SAME release, for symbol mapping')
    args = ap.parse_args()

    lines = [l for l in open(args.trace).read().splitlines() if l.startswith('rbtrace')]
    if not lines:
        sys.exit('no rbtrace records in %s' % args.trace)
    if len(lines) > 1:
        print('note: %d records; classifying the last' % len(lines))
    t = parse(lines[-1])

    if t.get('v') != 2:
        # Exit 2, distinct from 1. A caller chaining on the exit code must be able
        # to tell "refused to classify" from "classified as did-not-move"; sharing
        # a code would turn a tooling refusal into a substantive result.
        print('REFUSED: trace format v=%s. v1 recorded Code accessors under the '
              'uep_ names, so its values are not comparable with v2 Function '
              'fields. Re-run with a v2 engine.' % t.get('v'), file=sys.stderr)
        return 2

    print('target        : %s %s' % (t.get('lib'), t.get('sel')))
    print('rc            : %s   attach_entered=%s attach_returned=%s'
          % (t.get('rc'), t.get('attach_entered'), t.get('attach_returned')))
    print('function      : 0x%x' % t.get('fn', 0))
    print()
    print('FUNCTION fields (what the call instruction loads)')
    print('  entry_point_            0x%-12x -> 0x%x'
          % (t.get('fn_ep_pre', 0), t.get('fn_ep_post', 0)))
    print('  unchecked_entry_point_  0x%-12x -> 0x%x'
          % (t.get('fn_uep_pre', 0), t.get('fn_uep_post', 0)))
    print('CODE values (kept separate on purpose; v1 mislabelled these)')
    print('  Code                    0x%-12x -> 0x%x'
          % (t.get('code_pre', 0), t.get('code_post', 0)))
    print('  Code::EntryPoint        0x%-12x -> 0x%x'
          % (t.get('code_ep_pre', 0), t.get('code_ep_post', 0)))
    print('  Code::UncheckedEntry    0x%-12x -> 0x%x'
          % (t.get('code_uep_pre', 0), t.get('code_uep_post', 0)))
    print('same-run InterpretCall  : 0x%x' % t.get('interpret_call_ep', 0))

    # Caller-pool fields are UNAVAILABLE unless a caller was deliberately passed.
    # -1 is the initialiser precisely so "not asked" cannot read as "measured 0".
    print()
    if t.get('caller_resolved', UNSET) == UNSET:
        print('caller identity : NOT MEASURED (no caller supplied). These fields are '
              'unavailable, not a zero result — draw nothing from them.')
    else:
        print('caller identity : resolved=%s pool_functions=%s matches_target=%s '
              'other_fn=0x%x'
              % (t.get('caller_resolved'), t.get('caller_pool_functions'),
                 t.get('caller_pool_matches_target'),
                 t.get('caller_pool_other_fn', 0)))

    if args.dsym:
        # The slide comes from the trace itself: fn_ep_pre must be the target's
        # own entry, so subtracting its file address yields the load address.
        syms = subprocess.run(['nm', '-n', args.dsym], capture_output=True,
                              text=True).stdout
        want = str(t.get('sel', '')).split('#')[-1]
        hits = [(int(a, 16), n) for a, ty, n in
                (l.split(None, 2) + ['', ''] for l in syms.splitlines() if l.strip())
                if ty == 't' and n.strip() == want]
        if hits:
            slide = t.get('fn_ep_pre', 0) - hits[0][0]
            print()
            print('slide (from fn_ep_pre - dSYM %s) : 0x%x' % (want, slide))
            for a, n in hits:
                print('  %-28s file 0x%-8x -> 0x%x' % (n.strip(), a, a + slide))
        else:
            print()
            print('note: %r not found as a text symbol in the dSYM; skipping mapping'
                  % want)

    # IDENTITY VERDICT, mechanical, and only when the caller was actually asked.
    # Reported before the field verdict because once the field question is settled
    # this is the live one.
    print()
    print('=' * 60)
    cres = t.get('caller_resolved', UNSET)
    if cres != UNSET:
        seen = t.get('caller_pool_functions', UNSET)
        matches = t.get('caller_pool_matches_target', UNSET)
        other = t.get('caller_pool_other_fn', 0)
        fn = t.get('fn', 0)
        if cres == 0 or seen in (UNSET, 0):
            print('IDENTITY UNDECIDED — caller_resolved=%s pool_functions=%s.'
                  % (cres, seen))
            print('Fix the measurement. Do NOT infer a mismatch from an empty scan:')
            print('an unresolved caller and a caller with no pooled Functions are')
            print('different failures and neither is evidence about identity.')
            return 3
        if matches and matches > 0:
            print('IDENTITY MATCHES: the caller\'s pool holds the patched Function.')
            print('  patched fn 0x%x found among %d pooled Function(s)' % (fn, seen))
            print()
            print('Object identity is DISPROVEN as the cause. The contradiction moves')
            print('to how the call loads or observes that object at run time.')
            return 0
        print('IDENTITY MISMATCH: the caller dispatches through a DIFFERENT Function.')
        print('  patched fn      0x%x' % fn)
        print('  caller pool has 0x%x (and %d pooled Function(s), 0 matching)'
              % (other, seen))
        print()
        print('CAUSE FOUND: ResolvePatchTarget patched one Function object while the')
        print('caller dispatches through another representation of the same target.')
        return 1

    post, expect = t.get(DECIDING[0]), t.get(DECIDING[1])
    if post is None or expect is None or post == 0 or expect == 0:
        print('UNDECIDED — %s or %s missing. Fix instrumentation before reasoning.'
              % DECIDING)
        return 3
    if post == expect:
        print('DECIDED: Function::unchecked_entry_point_ DID move to InterpretCall.')
        print('  0x%x == 0x%x' % (post, expect))
        print()
        print('AttachBytecode changed the exact field the kUnchecked call reads. The')
        print('contradiction is therefore NOT in the field transition, and the next')
        print('experiment is the deliberate caller/pool Function-identity comparison.')
        return 0
    print('DECIDED: Function::unchecked_entry_point_ did NOT move to InterpretCall.')
    print('  0x%x != 0x%x' % (post, expect))
    print()
    print('The contradiction is inside SetInstructionsSafe / Function state. Stop')
    print('here: caller identity is not implicated and must not be investigated yet.')
    return 1


if __name__ == '__main__':
    sys.exit(main())
