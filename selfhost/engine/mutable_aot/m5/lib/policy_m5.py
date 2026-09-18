#!/usr/bin/env python3
"""Production selection policy v1 -- A/B/C on one representative application.

Subject: pkg/vm/bin/gen_kernel.dart. Root application package = `vm`;
front_end/kernel/etc are dependencies and are NOT selected in v1.

  A  normal selection (pragma only)   install OFF
  B  root-package policy              install OFF
  C  root-package policy              install ON

Runtime workload is gen_kernel compiling a file -- real, repeatable work
rather than launch-only. Five repetitions, median and range.
"""
import json, os, re, statistics, subprocess, sys, time
FORK='/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT='/Volumes/build/route-b/flutter/engine/src/out/maot_host'
DART='/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart'
NS='ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
WD='/private/tmp/claude-501/-Users-mendell-shorebird/541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/policy'
os.makedirs(WD, exist_ok=True)
APP=os.path.join(FORK,'pkg/vm/bin/gen_kernel.dart')
PKG=os.path.join(FORK,'.dart_tool/package_config.json')
ROOT={'MAOT_SELECT_ALL_NON_SDK':'1','MAOT_SELECT_URI_PREFIX':'package:vm/'}
REPS_BUILD=3; REPS_RUN=5

src=os.path.join(WD,'work.dart')
open(src,'w').write("import 'dart:math';\nvoid main(){var s=0;for(var i=0;i<50;i++){s+=sqrt(i.toDouble()).round();}print(s);}\n")

def med(ts): return (statistics.median(ts), min(ts), max(ts))

def arm(tag, envx, install):
    dill=os.path.join(WD,'%s.dill'%tag); kts=[]
    for _ in range(REPS_BUILD):
        t=time.time()
        r=subprocess.run([DART,'--packages=%s'%PKG,
            os.path.join(FORK,'pkg/vm/bin/gen_kernel.dart'),'--platform',
            os.path.join(OUT,'vm_platform_product.dill'),'--aot','--packages',PKG,
            '-o',dill,APP],capture_output=True,text=True,timeout=3600,
            env=dict(os.environ, **envx))
        assert r.returncode==0, r.stderr[-900:]
        kts.append(time.time()-t)
    aot=os.path.join(WD,'%s.aot'%tag); pre=os.path.join(WD,'%s.json'%tag); sts=[]; last=None
    for _ in range(REPS_BUILD):
        cmd=[os.path.join(OUT,'gen_snapshot'),'--snapshot_kind=app-aot-elf',
             '--elf=%s'%aot,'--maot_namespace=%s'%NS,
             '--maot_dump_registry_precompile=%s'%pre]
        if install:
            cmd+=['--maot_install_trampolines','--maot_verify_pinned_body_traversal',
                  '--maot_dump_trampoline_shape']
        cmd.append(dill)
        t=time.time()
        r=subprocess.run(cmd,capture_output=True,text=True,timeout=10800)
        assert r.returncode==0, [l for l in r.stderr.splitlines() if 'si_addr' in l]
        sts.append(time.time()-t); last=r
    sel=elig=0; reasons={}
    if os.path.exists(pre):
        j=json.load(open(pre)); ents=j.get('entries', j if isinstance(j,list) else [])
        for e in ents:
            if not e.get('selected'): continue
            sel+=1
            if e.get('installable') is True: elig+=1
            else:
                w=str(e.get('first_escape_reason') or e.get('blocking_records') or '?')
                reasons[w]=reasons.get(w,0)+1
    inst=dist=None; part=trav=''
    for l in last.stderr.splitlines():
        m=re.search(r'POST-DEDUP trampolines: installed=(\d+) distinct=(\d+)', l)
        if m: inst,dist=int(m.group(1)),int(m.group(2))
        if 'BODY_PARTITION' in l: part=l.strip()
        if 'PINNED_TRAVERSAL' in l: trav=l.strip()
    # runtime workload
    rts=[]; ok=True
    for _ in range(REPS_RUN):
        od=os.path.join(WD,'w_%s.dill'%tag)
        if os.path.exists(od): os.remove(od)
        t=time.time()
        q=subprocess.run([os.path.join(OUT,'dartaotruntime'),aot,'--platform',
            os.path.join(OUT,'vm_platform_product.dill'),'--aot','--packages',PKG,
            '-o',od,src],capture_output=True,text=True,timeout=900,
            env=dict(os.environ,MAOT_NAMESPACE=NS))
        rts.append(time.time()-t)
        ok = ok and q.returncode==0 and os.path.exists(od) and os.path.getsize(od)>0
    return dict(tag=tag, k=med(kts), s=med(sts), size=os.path.getsize(aot)/1e6,
                sel=sel, elig=elig, ref=sel-elig, reasons=reasons, inst=inst,
                dist=dist, part=part, trav=trav, rt=med(rts), rt_ok=ok)

rows=[arm('A', {}, False), arm('B', ROOT, False), arm('C', ROOT, True)]
print('%-3s %-20s %-20s %-9s %-7s %-7s %-6s %-7s %-22s' % (
  'arm','kernel s med[rng]','snap s med[rng]','snap MB','sel','elig','ref','inst','runtime s med[rng]'))
for r in rows:
    print('%-3s %-20s %-20s %-9.2f %-7d %-7d %-6d %-7s %s  ok=%s' % (
      r['tag'], '%.1f [%.1f-%.1f]'%r['k'], '%.1f [%.1f-%.1f]'%r['s'], r['size'],
      r['sel'], r['elig'], r['ref'], r['inst'],
      '%.2f [%.2f-%.2f]'%r['rt'], r['rt_ok']))
A,B,C = rows
print('\n--- derived ---')
print('selection-only size delta  B-A = %+.2f MB (%+.1f%%)' % (B['size']-A['size'], 100*(B['size']-A['size'])/A['size']))
print('trampoline size delta      C-B = %+.2f MB (%+.1f%%)' % (C['size']-B['size'], 100*(C['size']-B['size'])/B['size']))
print('total policy size delta    C-A = %+.2f MB (%+.1f%%)' % (C['size']-A['size'], 100*(C['size']-A['size'])/A['size']))
if C['inst']: print('bytes per installed decl   = %.0f' % ((C['size']-A['size'])*1e6/C['inst']))
print('snapshot time  C-A = %+.1f%%' % (100*(C['s'][0]-A['s'][0])/A['s'][0]))
print('kernel time    C-A = %+.1f%%' % (100*(C['k'][0]-A['k'][0])/A['k'][0]))
print('runtime        C-A = %+.1f%%' % (100*(C['rt'][0]-A['rt'][0])/A['rt'][0]))
for r in rows:
    if r['reasons']:
        print('\narm %s refusals:' % r['tag'])
        for w,n in sorted(r['reasons'].items(), key=lambda kv:-kv[1])[:5]:
            print('   %-6d %s' % (n, w[:95]))
    if r['part']: print('arm %s %s' % (r['tag'], r['part']))
    if r['trav']: print('arm %s %s' % (r['tag'], r['trav']))
