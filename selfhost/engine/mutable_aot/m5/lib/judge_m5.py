#!/usr/bin/env python3
"""The acceptance judgement, separated so it can be falsified.

A suite that returns PASS on every row the first time it runs has not been
shown to discriminate. This module holds the judgement as a pure function of
(baseline, v2, v3, beta-stages, behaviour), so a self-test can feed it
deliberately corrupted evidence and require it to FAIL.
"""

FROZEN = ['id_declaration_function', 'id_declaration_current_code',
          'id_trampoline_code', 'id_trampoline_entry', 'id_dispatch_cell',
          'id_release_body']
MOVING = ['id_cell_impl_function', 'id_cell_impl_code',
          'id_pinned_current_body']
STAGES = ('before', 'v2', 'v3')


def judge(stages, beta, kv):
    """Return (checks_run, failures)."""
    fails = []
    n = 0

    def chk(name, ok, detail=''):
        nonlocal n
        n += 1
        if not ok:
            fails.append(f'{name}{(" " + detail) if detail else ""}')

    a0 = kv.get('alpha.0', '')
    a2 = kv.get('alpha.v2', '')
    a3 = kv.get('alpha.v3', '')
    # Three distinct observations in order. Checked as a sequence, not as a
    # disjunction: an earlier version of this accepted any row whose v2 read
    # NEW-ALPHA and never looked at v3 at all.
    chk('behaviour baseline is OLD', a0.startswith('OLD'), a0)
    chk('behaviour v2 is NEW and differs from baseline',
        a2.startswith('NEW') and not a2.startswith('NEW2') and a2 != a0,
        f'{a0}->{a2}')
    chk('behaviour v3 is NEW2 and differs from v2',
        a3.startswith('NEW2') and a3 != a2, f'{a2}->{a3}')

    chk('StageReplacement v2 success', kv.get('install.v2') == '0',
        str(kv.get('install.v2')))
    chk('StageReplacement v3 success', kv.get('install.v3') == '0',
        str(kv.get('install.v3')))
    chk('version 1 -> PATCH_CODE v2 -> PATCH_CODE v3',
        (kv.get('version.0'), kv.get('version.v2'), kv.get('version.v3'))
        == ('1', '-102', '-103'),
        f"{kv.get('version.0')}/{kv.get('version.v2')}/{kv.get('version.v3')}")

    for f in FROZEN:
        vals = [stages[s].get(f) for s in STAGES]
        chk(f'frozen {f}',
            len(set(vals)) == 1 and vals[0] not in (None, 0), str(vals))
    for f in MOVING:
        vals = [stages[s].get(f) for s in STAGES]
        chk(f'moves twice {f}',
            len(set(vals)) == 3 and all(v not in (None, 0) for v in vals),
            str(vals))

    for s in STAGES:
        e = stages[s]
        chk(f'[{s}] cell code is pinned body',
            e.get('dispatch_cell_code_matches_pinned_current_body') is True)
        chk(f'[{s}] cell fn is current impl',
            e.get('dispatch_cell_function_matches_current_impl') is True)
        chk(f'[{s}] no self-cycle: cell code != trampoline',
            e.get('id_cell_impl_code') not in (None,)
            and e.get('id_cell_impl_code') != e.get('id_trampoline_code'))
        chk(f'[{s}] installable', e.get('installable') is True)
        chk(f'[{s}] optimizer_escapes == 0',
            e.get('optimizer_escapes') == 0, str(e.get('optimizer_escapes')))
        chk(f'[{s}] blocking_records none',
            e.get('blocking_records') in ('<none>', None, '', []),
            str(e.get('blocking_records')))

    if beta and all(beta.get(s) for s in STAGES):
        for f in FROZEN + MOVING:
            vals = [beta[s].get(f) for s in STAGES]
            chk(f'unrelated declaration unchanged {f}',
                len(set(vals)) == 1, str(vals))
    else:
        chk('unrelated declaration present in dumps', False, 'missing')
    chk('unrelated behaviour unchanged',
        kv.get('beta.0') is not None and kv.get('beta.0') == kv.get('beta.after'),
        f"{kv.get('beta.0')} -> {kv.get('beta.after')}")
    return n, fails
