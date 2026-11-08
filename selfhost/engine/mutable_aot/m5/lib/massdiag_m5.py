#!/usr/bin/env python3
"""Mass-selection serialization crash: population identity, then bisect.

Step 1/2: ONE failing run emitting every population count together, plus a
deterministic hash of the selected declaration sequence, so nothing is
reasoned across two runs.

Step 3: --maot_limit_selected ladder on the SAME kernel to separate
"population threshold" from "one specific declaration".
"""
import hashlib, json, os, re, subprocess, sys, tempfile, time

FORK='/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT='/Volumes/build/route-b/flutter/engine/src/out/maot_host'
DART='/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart'
APP='/Users/mendell/shorebird/packages/shorebird_cli/bin/shorebird.dart'
PKGCFG='/Users/mendell/shorebird/.dart_tool/package_config.json'
NS='ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
WD='/private/tmp/claude-501/-Users-mendell-shorebird/541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/massdiag'
os.makedirs(WD, exist_ok=True)
DILL=os.path.join(WD,'app_all.dill')


def build_kernel():
    if os.path.exists(DILL):
        print('reusing kernel', DILL); return
    t=time.time()
    r=subprocess.run([DART,'--packages=%s'%os.path.join(FORK,'.dart_tool/package_config.json'),
        os.path.join(FORK,'pkg/vm/bin/gen_kernel.dart'),'--platform',
        os.path.join(OUT,'vm_platform_product.dill'),'--aot','--packages',PKGCFG,
        '-o',DILL,APP], capture_output=True,text=True,timeout=3600,
        env=dict(os.environ, MAOT_SELECT_ALL_NON_SDK='1'))
    assert r.returncode==0, r.stderr[-1500:]
    print('kernel built in %.0fs' % (time.time()-t))


def snap(tag, limit=None, extra=()):
    pre=os.path.join(WD,'reg_%s.json'%tag)
    cmd=[os.path.join(OUT,'gen_snapshot'),'--snapshot_kind=app-aot-elf',
         '--elf=%s'%os.path.join(WD,'a_%s.aot'%tag),'--maot_namespace=%s'%NS,
         '--maot_install_trampolines','--maot_verify_pinned_body_traversal',
         '--maot_dump_trampoline_shape','--maot_dump_registry_precompile=%s'%pre]
    if limit is not None: cmd.append('--maot_limit_selected=%d'%limit)
    cmd += list(extra); cmd.append(DILL)
    t=time.time()
    r=subprocess.run(cmd,capture_output=True,text=True,timeout=7200)
    return r, pre, time.time()-t


def counts(r, pre):
    d={'selected':0,'eligible':0,'refused':0,'installed':None,'distinct':None,
       'bodies':None,'nonleaf':None,'order_sha':None,'reasons':{}}
    if os.path.exists(pre):
        j=json.load(open(pre)); ents=j.get('entries', j if isinstance(j,list) else [])
        ids=[]
        for e in ents:
            if not e.get('selected'): continue
            d['selected']+=1; ids.append(e.get('declaration_id',''))
            if e.get('installable') is True: d['eligible']+=1
            else:
                d['refused']+=1
                w=str(e.get('first_escape_reason') or e.get('blocking_records') or '?')
                d['reasons'][w]=d['reasons'].get(w,0)+1
        d['order_sha']=hashlib.sha256('\n'.join(ids).encode()).hexdigest()[:16]
        d['ids']=ids
    for l in r.stderr.splitlines():
        m=re.search(r'POST-DEDUP trampolines: installed=(\d+) distinct=(\d+)', l)
        if m: d['installed'],d['distinct']=int(m.group(1)),int(m.group(2))
        m=re.search(r'PINNED_TRAVERSAL bodies=(\d+).*non_leaf_bodies=(\d+)', l)
        if m: d['bodies'],d['nonleaf']=int(m.group(1)),int(m.group(2))
    return d


build_kernel()
print('\n===== STEP 1/2: one failing run, all population counters together')
r, pre, secs = snap('full')
c = counts(r, pre)
print('  snapshot rc=%d  %.1fs' % (r.returncode, secs))
print('  selected  = %d' % c['selected'])
print('  eligible  = %d' % c['eligible'])
print('  refused   = %d' % c['refused'])
print('  installed = %s' % c['installed'])
print('  distinct  = %s' % c['distinct'])
print('  pinned bodies = %s   non-leaf = %s' % (c['bodies'], c['nonleaf']))
print('  selected-order sha256[:16] = %s' % c['order_sha'])
if c['reasons']:
    print('  refusal reasons:')
    for w,n in sorted(c['reasons'].items(), key=lambda kv:-kv[1])[:8]:
        print('      %-6d %s' % (n, w[:100]))
for l in r.stderr.splitlines():
    if 'si_addr' in l: print('  fault:', l.strip())
json.dump(c.get('ids',[]), open(os.path.join(WD,'selected_ids.json'),'w'))

print('\n===== STEP 3: population ladder on the SAME kernel')
print('%-8s %-8s %-11s %-9s %s' % ('N','result','installed','secs','fault/verdict'))
results={}
for n in [1,64,512,1024,2048,4096,None]:
    tag='n%s'%(n if n is not None else 'full')
    r2,pre2,s2 = snap(tag, limit=n)
    c2 = counts(r2, pre2)
    ok = r2.returncode==0
    note=''
    if not ok:
        f=[l.strip() for l in r2.stderr.splitlines() if 'si_addr' in l]
        note=f[0][:70] if f else 'rc=%d'%r2.returncode
    else:
        t=[l for l in r2.stderr.splitlines() if 'PINNED_TRAVERSAL' in l]
        note=t[0].split('verdict=')[-1].strip() if t else ''
    results[n]=ok
    print('%-8s %-8s %-11s %-9.1f %s' % (n if n is not None else 'full',
          'ok' if ok else 'CRASH', c2['installed'], s2, note))
    sys.stdout.flush()
json.dump({str(k):v for k,v in results.items()}, open(os.path.join(WD,'ladder.json'),'w'))
