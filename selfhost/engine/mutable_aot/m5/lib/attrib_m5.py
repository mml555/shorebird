#!/usr/bin/env python3
"""Stage 38 -- object-level attribution of the .rodata delta.

Arms A (selection OFF) and B (selection ON, P1 OFF, inlining restriction OFF)
from the Stage 37 matrix, so the delta measured is the one that matters and
nothing else varies. Call indirection and retention roots OFF in both.
"""
import collections, json, os, subprocess, sys
FORK='/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT='/Volumes/build/route-b/flutter/engine/src/out/maot_host'
NS='ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
WD='/private/tmp/claude-501/-Users-mendell-shorebird/541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/sizemat'
FLAGS=['--maot_disable_call_indirection','--maot_disable_retention_roots']

def profile(tag, dill, extra):
    prof=os.path.join(WD,'prof_%s.json'%tag)
    if not os.path.exists(prof):
        r=subprocess.run([os.path.join(OUT,'gen_snapshot'),'--snapshot_kind=app-aot-elf',
            '--elf=%s'%os.path.join(WD,'prof_%s.aot'%tag),'--maot_namespace=%s'%NS,
            '--write_v8_snapshot_profile_to=%s'%prof]+FLAGS+extra+[dill],
            capture_output=True,text=True,timeout=10800)
        if r.returncode!=0:
            print('snapshot rc=%d'%r.returncode, r.stderr.strip()[-400:]); sys.exit(1)
    return prof

def load(prof):
    j=json.load(open(prof))
    meta=j['snapshot']['meta']
    fields=meta['node_fields']; types=meta['node_types'][0]
    ti=fields.index('type'); si=fields.index('self_size'); ni=fields.index('name')
    n=len(fields); nodes=j['nodes']; strings=j['strings']
    by=collections.Counter(); cnt=collections.Counter()
    names=collections.defaultdict(collections.Counter)
    for k in range(0,len(nodes),n):
        t=types[nodes[k+ti]] if nodes[k+ti] < len(types) else str(nodes[k+ti])
        sz=nodes[k+si]
        by[t]+=sz; cnt[t]+=1
        nm=strings[nodes[k+ni]] if nodes[k+ni] < len(strings) else ''
        if sz: names[t][nm[:70]]+=sz
    return by, cnt, names

pa=profile('A', os.path.join(WD,'k0.dill'), [])
pb=profile('B', os.path.join(WD,'k1.dill'), ['--maot_allow_inlining_mutable'])
ba,ca,na = load(pa)
bb,cb,nb = load(pb)
total_a=sum(ba.values()); total_b=sum(bb.values())
print('profiled total  A=%.2f MB   B=%.2f MB   delta=%+.2f MB' % (
    total_a/1e6, total_b/1e6, (total_b-total_a)/1e6))
delta={t: bb[t]-ba.get(t,0) for t in set(bb)|set(ba)}
ranked=sorted(delta.items(), key=lambda kv:-kv[1])
tot_delta=sum(v for v in delta.values() if v>0)
print('\n%-26s %10s %10s %12s %9s %9s %7s' % (
      'object type','bytes A','bytes B','delta','count A','count B','avg B'))
cum=0
for t,d in ranked[:14]:
    if d<=0: break
    cum+=d
    avg = bb[t]/cb[t] if cb[t] else 0
    print('%-26s %10.2f %10.2f %12.2f %9d %9d %7.0f   cum=%.0f%%' % (
        t, ba.get(t,0)/1e6, bb[t]/1e6, d/1e6, ca.get(t,0), cb[t], avg,
        100*cum/(total_b-total_a) if total_b!=total_a else 0))
print('\ntop contributors cover %.0f%% of the measured delta' % (100*cum/(total_b-total_a)))
# Drill into the single biggest contributor by object name.
big=ranked[0][0]
print('\n--- biggest contributor %r, by object name (B) ---' % big)
for nm,sz in nb[big].most_common(12):
    print('   %10.2f MB  %s' % (sz/1e6, nm if nm else '<no name>'))
