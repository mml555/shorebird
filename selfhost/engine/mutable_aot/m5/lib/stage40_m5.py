#!/usr/bin/env python3
"""Stage 40 gates A and B. Retention roots OFF throughout."""
import json, os, re, subprocess, sys
FORK='/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT='/Volumes/build/route-b/flutter/engine/src/out/maot_host'
PKG=os.path.join(FORK,'.dart_tool/package_config.json')
NS='ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
WD='/private/tmp/claude-501/-Users-mendell-shorebird/541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/sizemat'
S40=WD+'/s40'; os.makedirs(S40, exist_ok=True)
src=os.path.join(S40,'work.dart'); open(src,'w').write("void main(){print('ok');}\n")

def run(tag, dill, extra):
    aot=os.path.join(S40,'%s.aot'%tag); ret=os.path.join(S40,'%s.txt'%tag)
    pre=os.path.join(S40,'%s.json'%tag)
    r=subprocess.run([os.path.join(OUT,'gen_snapshot'),'--snapshot_kind=app-aot-elf',
        '--elf=%s'%aot,'--maot_namespace=%s'%NS,'--maot_dump_retained=%s'%ret,
        '--maot_dump_registry_precompile=%s'%pre]+extra+[dill],
        capture_output=True,text=True,timeout=10800)
    if r.returncode!=0:
        print('%s SNAPSHOT rc=%d'%(tag,r.returncode),
              [l for l in r.stderr.splitlines() if 'si_addr' in l][:1]); sys.exit(1)
    retained={l.strip() for l in open(ret,errors='replace') if l.strip()} if os.path.exists(ret) else set()
    sel=elig=0
    if os.path.exists(pre):
        j=json.load(open(pre)); ents=j.get('entries', j if isinstance(j,list) else [])
        for e in ents:
            if e.get('selected'):
                sel+=1
                if e.get('installable') is True: elig+=1
    edges=''
    for l in r.stderr.splitlines():
        if 'RELEASE_EDGES' in l: edges=l.strip()
    od=os.path.join(S40,'o_%s.dill'%tag)
    if os.path.exists(od): os.remove(od)
    q=subprocess.run([os.path.join(OUT,'dartaotruntime'),aot,'--platform',
        os.path.join(OUT,'vm_platform_product.dill'),'--aot','--packages',PKG,'-o',od,src],
        capture_output=True,text=True,timeout=900,env=dict(os.environ,MAOT_NAMESPACE=NS))
    ok=q.returncode==0 and os.path.exists(od) and os.path.getsize(od)>0
    return dict(tag=tag, size=os.path.getsize(aot), retained=retained, sel=sel,
                elig=elig, edges=edges, ok=ok)

# A: plain kernel.  B: policy kernel, indirection ON (default), roots OFF.
A=run('A', os.path.join(WD,'k0.dill'), ['--maot_disable_retention_roots'])
B=run('B', os.path.join(WD,'k1.dill'), ['--maot_disable_retention_roots'])
print('%-3s %-9s %-9s %-8s %-8s %s' % ('arm','MB','retained','sel','elig','workload'))
for r in (A,B):
    print('%-3s %-9.2f %-9d %-8d %-8d %s' % (r['tag'], r['size']/1e6,
          len(r['retained']), r['sel'], r['elig'], 'ok' if r['ok'] else 'FAIL'))
print('\n--- GATE A: baseline preservation ---')
lost=A['retained']-B['retained']; extra=B['retained']-A['retained']
print('LOST  = |BASELINE - MAOT| = %d   -> %s' % (len(lost), 'PASS' if not lost else 'FAIL'))
for e in list(lost)[:8]: print('      -', e[:110])
print('EXTRA = |MAOT - BASELINE| = %d' % len(extra))
import collections
def bucket(n):
    if n.startswith('dart:'): return 'dart: (SDK)'
    if n.startswith('package:'): return 'package:'+n.split('/')[0][8:]
    if n.startswith('file:'): return 'file: (entry)'
    return 'other'
for k,v in collections.Counter(bucket(n) for n in extra).most_common(8):
    print('        %-26s %d' % (k,v))
print('\n--- GATE B: edge accounting ---')
print('  A: %s' % (A['edges'] or '<none emitted>'))
print('  B: %s' % (B['edges'] or '<none emitted>'))
