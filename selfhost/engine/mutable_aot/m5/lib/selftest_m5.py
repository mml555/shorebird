#!/usr/bin/env python3
"""Falsify the acceptance judgement against deliberately corrupted evidence.

Every mutation below encodes one of the PM's hard stop conditions. If the
judge still returns PASS for any of them, the matrix result means nothing.
"""
import copy, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from judge_m5 import judge, FROZEN, MOVING, STAGES

SCRATCH = os.path.dirname(os.path.abspath(__file__))
real = json.load(open(os.path.join(SCRATCH, 'evidence_setter.json')))
stages, beta, kv = real['stages'], real['beta'], real['kv']

n, fails = judge(stages, beta, kv)
print(f'unmutated setter evidence: {n} checks, {len(fails)} failures')
assert not fails, fails

MUTATIONS = []

# Hard stop: "installation reports success but execution remains OLD".
def m_stale(s, b, k):
    k = dict(k); k['alpha.v2'] = k['alpha.0']; return s, b, k
MUTATIONS.append(('false success: v2 still OLD', m_stale))

# Hard stop: "v2 works but v3 exposes stale body/version pinning".
def m_v3_stale(s, b, k):
    k = dict(k); k['alpha.v3'] = k['alpha.v2']; return s, b, k
MUTATIONS.append(('v3 repeats v2', m_v3_stale))

# Hard stop: "StageReplacement refuses".
def m_refuse(s, b, k):
    k = dict(k); k['install.v3'] = '-1'; return s, b, k
MUTATIONS.append(('install v3 refused', m_refuse))

# Hard stop: "descriptor advances without the cell/body advancing".
for f in MOVING:
    def m_frozen_impl(s, b, k, f=f):
        s = copy.deepcopy(s); s['v3'][f] = s['v2'][f]; return s, b, k
    MUTATIONS.append((f'implementation {f} did not advance at v3',
                      m_frozen_impl))

# Hard stop: a frozen routing object moved.
for f in FROZEN:
    def m_moved(s, b, k, f=f):
        s = copy.deepcopy(s); s['v2'][f] = (s['v2'][f] or 0) + 16; return s, b, k
    MUTATIONS.append((f'frozen {f} moved at v2', m_moved))

# Hard stop: "production installation puts the trampoline into cell.implCode".
def m_selfcycle(s, b, k):
    s = copy.deepcopy(s); s['v2']['id_cell_impl_code'] = s['v2']['id_trampoline_code']
    return s, b, k
MUTATIONS.append(('self-cycle: cell code == trampoline', m_selfcycle))

# Hard stop: optimizer decision degraded.
def m_escape(s, b, k):
    s = copy.deepcopy(s); s['v2']['optimizer_escapes'] = 1; return s, b, k
MUTATIONS.append(('optimizer_escapes > 0', m_escape))

def m_block(s, b, k):
    s = copy.deepcopy(s); s['v2']['blocking_records'] = 'dynamic/Unknown'
    return s, b, k
MUTATIONS.append(('blocking record present', m_block))

# Hard stop: "replacing Alpha changes Beta".
def m_beta(s, b, k):
    b = copy.deepcopy(b); b['v2']['id_cell_impl_code'] = (b['v2']['id_cell_impl_code'] or 0) + 16
    return s, b, k
MUTATIONS.append(('cross-wiring: unrelated declaration moved', m_beta))

def m_beta_behaviour(s, b, k):
    k = dict(k); k['beta.after'] = 'CHANGED'; return s, b, k
MUTATIONS.append(('cross-wiring: unrelated behaviour changed', m_beta_behaviour))

# Degenerate evidence: identity fields absent entirely.
def m_absent(s, b, k):
    s = copy.deepcopy(s)
    for st in STAGES:
        for f in FROZEN + MOVING:
            s[st].pop(f, None)
    return s, b, k
MUTATIONS.append(('identity fields absent from dump', m_absent))

bad = 0
for name, mut in MUTATIONS:
    s2, b2, k2 = mut(stages, beta, kv)
    _, f2 = judge(s2, b2, k2)
    ok = len(f2) > 0
    print(f'  {"DETECTED" if ok else "MISSED  "}  {name}')
    if not ok:
        bad += 1
print(f'\n{len(MUTATIONS)} mutations, {bad} undetected')
raise SystemExit(1 if bad else 0)
