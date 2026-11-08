#!/usr/bin/env python3
"""Stage 35 -- policy v2: baseline-retained root-package declarations only.

  A  normal build                      install OFF
  B  policy v2                         install OFF
  C  policy v2                         install ON

Policy v2 = root-package ownership AND baseline retention. The retention half
needs no new selection logic: materialization already keeps only functions in
functions_to_retain_, so suppressing the seeding AddFunction/AddTypesOf is
sufficient for selection to CONSUME retention instead of CAUSING it.

The neutrality proof is a set comparison against arm A's retained set, not an
inference from similar sizes.
"""
import json, os, re, statistics, subprocess, sys, time
FORK='/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT='/Volumes/build/route-b/flutter/engine/src/out/maot_host'
DART='/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart'
NS='ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
WD='/private/tmp/claude-501/-Users-mendell-shorebird/541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/policy2'
os.makedirs(WD, exist_ok=True)
APP=os.path.join(FORK,'pkg/vm/bin/gen_kernel.dart')
PKG=os.path.join(FORK,'.dart_tool/package_config.json')
ROOT={'MAOT_SELECT_ALL_NON_SDK':'1','MAOT_SELECT_URI_PREFIX':'package:vm/'}
src=os.path.join(WD,'work.dart')
open(src,'w').write("void main(){print('ok');}\n")

def arm(tag, envx, install, v2):
    dill=os.path.join(WD,'%s.dill'%tag)
    r=subprocess.run([DART,'--packages=%s'%PKG,
        os.path.join(FORK,'pkg/vm/bin/gen_kernel.dart'),'--platform',
        os.path.join(OUT,'vm_platform_product.dill'),'--aot','--packages',PKG,
        '-o',dill,APP],capture_output=True,text=True,timeout=3600,
        env=dict(os.environ, **envx))
    assert r.returncode==0, r.stderr[-900:]
    aot=os.path.join(WD,'%s.aot'%tag); pre=os.path.join(WD,'%s.json'%tag)
    ret=os.path.join(WD,'%s.retained.txt'%tag)
    cmd=[os.path.join(OUT,'gen_snapshot'),'--snapshot_kind=app-aot-elf',
         '--elf=%s'%aot,'--maot_namespace=%s'%NS,
         '--maot_dump_registry_precompile=%s'%pre,
         '--maot_dump_retained=%s'%ret]
    if v2: cmd.append('--maot_disable_retention_roots')
    if install:
        cmd+=['--maot_install_trampolines','--maot_verify_pinned_body_traversal',
              '--maot_dump_trampoline_shape']
    cmd.append(dill)
    t=time.time()
    s=subprocess.run(cmd,capture_output=True,text=True,timeout=10800)
    assert s.returncode==0, [l for l in s.stderr.splitlines() if 'si_addr' in l]
    sel=elig=0; ids=[]
    if os.path.exists(pre):
        j=json.load(open(pre)); ents=j.get('entries', j if isinstance(j,list) else [])
        for e in ents:
            if not e.get('selected'): continue
            sel+=1; ids.append(e.get('declaration_id',''))
            if e.get('installable') is True: elig+=1
    inst=dist=None; part=trav=''
    for l in s.stderr.splitlines():
        m=re.search(r'POST-DEDUP trampolines: installed=(\d+) distinct=(\d+)', l)
        if m: inst,dist=int(m.group(1)),int(m.group(2))
        if 'BODY_PARTITION' in l: part=l.strip()
        if 'PINNED_TRAVERSAL' in l: trav=l.strip()
    retained=set()
    if os.path.exists(ret):
        retained={l.strip() for l in open(ret, errors='replace') if l.strip()}
    od=os.path.join(WD,'w_%s.dill'%tag)
    if os.path.exists(od): os.remove(od)
    q=subprocess.run([os.path.join(OUT,'dartaotruntime'),aot,'--platform',
        os.path.join(OUT,'vm_platform_product.dill'),'--aot','--packages',PKG,
        '-o',od,src],capture_output=True,text=True,timeout=900,
        env=dict(os.environ,MAOT_NAMESPACE=NS))
    ok = q.returncode==0 and os.path.exists(od) and os.path.getsize(od)>0
    return dict(tag=tag, size=os.path.getsize(aot)/1e6, sel=sel, elig=elig,
                ref=sel-elig, inst=inst, dist=dist, part=part, trav=trav,
                retained=retained, ids=ids, run_ok=ok, secs=time.time()-t)

A=arm('A', {}, False, False)
B=arm('B', ROOT, False, True)
C=arm('C', ROOT, True, True)
print('%-3s %-9s %-8s %-8s %-6s %-8s %-9s %s' % (
  'arm','snap MB','sel','elig','ref','inst','retained','workload'))
for r in (A,B,C):
    print('%-3s %-9.2f %-8d %-8d %-6d %-8s %-9d %s' % (
      r['tag'], r['size'], r['sel'], r['elig'], r['ref'], r['inst'],
      len(r['retained']), 'ok' if r['run_ok'] else 'FAIL'))
print('\n--- tree-shaking neutrality ---')
for r in (B,C):
    extra = r['retained'] - A['retained']
    print('arm %s: retained_not_in_baseline = %d  %s' % (
        r['tag'], len(extra), 'PASS' if len(extra)==0 else 'FAIL'))
    for e in list(extra)[:5]: print('      +', e[:120])
print('\n--- size ---')
print('B-A = %+.2f MB (%+.1f%%)   selection only' % (B['size']-A['size'], 100*(B['size']-A['size'])/A['size']))
print('C-B = %+.2f MB (%+.1f%%)   trampolines'    % (C['size']-B['size'], 100*(C['size']-B['size'])/B['size']))
print('C-A = %+.2f MB (%+.1f%%)   total policy'   % (C['size']-A['size'], 100*(C['size']-A['size'])/A['size']))
if C['inst']: print('per installed declaration = %.0f bytes' % ((C['size']-B['size'])*1e6/C['inst']))
for r in (C,):
    if r['part']: print(r['part'])
    if r['trav']: print(r['trav'])
json.dump({'A':A['size'],'B':B['size'],'C':C['size'],'sel':C['sel']},
          open(os.path.join(WD,'summary.json'),'w'))
