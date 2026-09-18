#!/usr/bin/env python3
"""Ablation: which MAOT semantic layer collapses baseline reachability?

All arms use the SAME selected kernel and have retention roots OFF, so the
only variable is which MAOT effect is suppressed. The baseline and the
roots-ON control bracket the range.
"""
import json, os, subprocess, sys
FORK='/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT='/Volumes/build/route-b/flutter/engine/src/out/maot_host'
PKG=os.path.join(FORK,'.dart_tool/package_config.json')
NS='ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
WD='/private/tmp/claude-501/-Users-mendell-shorebird/541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/policy2'
SEL=os.path.join(WD,'B.dill'); PLAIN=os.path.join(WD,'A.dill')
src=os.path.join(WD,'work.dart')
OFF=['--maot_disable_retention_roots']

ARMS=[
 ('baseline (plain kernel)',        PLAIN, []),
 ('selected, roots ON  (control)',  SEL,   []),
 ('selected, roots OFF',            SEL,   OFF),
 ('  + call-indirection OFF',       SEL,   OFF+['--maot_disable_call_indirection']),
 ('  + allow inlining mutable',     SEL,   OFF+['--maot_allow_inlining_mutable']),
 ('  + escape detection OFF',       SEL,   OFF+['--maot_disable_escape_detection']),
 ('  + constant backstop OFF',      SEL,   OFF+['--maot_disable_constant_backstop']),
]
print('%-32s %-9s %-8s %-9s %s' % ('arm','snap MB','selected','retained','workload'))
sets={}
for i,(label, dill, extra) in enumerate(ARMS):
    aot=os.path.join(WD,'ab%d.aot'%i); pre=os.path.join(WD,'ab%d.json'%i)
    ret=os.path.join(WD,'ab%d.txt'%i)
    r=subprocess.run([os.path.join(OUT,'gen_snapshot'),'--snapshot_kind=app-aot-elf',
        '--elf=%s'%aot,'--maot_namespace=%s'%NS,
        '--maot_dump_registry_precompile=%s'%pre,'--maot_dump_retained=%s'%ret]
        +extra+[dill],capture_output=True,text=True,timeout=10800)
    if r.returncode!=0:
        print('%-32s SNAPSHOT rc=%d' % (label, r.returncode)); continue
    sel=0
    if os.path.exists(pre):
        j=json.load(open(pre)); ents=j.get('entries', j if isinstance(j,list) else [])
        sel=sum(1 for e in ents if e.get('selected'))
    s=set()
    if os.path.exists(ret): s={l.strip() for l in open(ret,errors='replace') if l.strip()}
    sets[label]=s
    od=os.path.join(WD,'ab_out.dill')
    if os.path.exists(od): os.remove(od)
    q=subprocess.run([os.path.join(OUT,'dartaotruntime'),aot,'--platform',
        os.path.join(OUT,'vm_platform_product.dill'),'--aot','--packages',PKG,'-o',od,src],
        capture_output=True,text=True,timeout=900,env=dict(os.environ,MAOT_NAMESPACE=NS))
    ok = q.returncode==0 and os.path.exists(od) and os.path.getsize(od)>0
    print('%-32s %-9.2f %-8d %-9d %s' % (label, os.path.getsize(aot)/1e6, sel,
          len(s), 'ok' if ok else 'FAIL rc=%d'%q.returncode))
    sys.stdout.flush()
base=sets.get('baseline (plain kernel)', set())
print('\n--- LOST relative to baseline ---')
for label,s in sets.items():
    if label.startswith('baseline'): continue
    lost=base-s; gained=s-base
    print('%-32s lost=%-7d gained=%-6d' % (label, len(lost), len(gained)))
json.dump({k:sorted(v) for k,v in sets.items()}, open(os.path.join(WD,'ablate_sets.json'),'w'))
