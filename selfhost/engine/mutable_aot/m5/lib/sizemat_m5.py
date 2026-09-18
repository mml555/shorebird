#!/usr/bin/env python3
"""Size-driver ablation. Call indirection OFF and roots OFF in EVERY arm, so
reachability stays ~baseline and size is not confounded by the 22k->2k collapse.

  A  selection OFF   P1 normal   inlining normal
  B  selection ON    P1 OFF      inlining restriction OFF
  C  selection ON    P1 ON       inlining restriction OFF
  D  selection ON    P1 ON       inlining restriction ON
"""
import json, os, re, subprocess, sys
FORK='/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT='/Volumes/build/route-b/flutter/engine/src/out/maot_host'
DART='/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart'
READELF='/Volumes/build/route-b/flutter/engine/src/flutter/buildtools/mac-arm64/clang/bin/llvm-readelf'
PKG=os.path.join(FORK,'.dart_tool/package_config.json')
NS='ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
WD='/private/tmp/claude-501/-Users-mendell-shorebird/541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/sizemat'
os.makedirs(WD, exist_ok=True)
APP=os.path.join(FORK,'pkg/vm/bin/gen_kernel.dart')
SEL={'MAOT_SELECT_ALL_NON_SDK':'1','MAOT_SELECT_URI_PREFIX':'package:vm/'}
BASEFLAGS=['--maot_disable_call_indirection','--maot_disable_retention_roots']
src=os.path.join(WD,'work.dart'); open(src,'w').write("void main(){print('ok');}\n")

def kernel(tag, envx):
    d=os.path.join(WD,'%s.dill'%tag)
    if not os.path.exists(d):
        r=subprocess.run([DART,'--packages=%s'%PKG,
            os.path.join(FORK,'pkg/vm/bin/gen_kernel.dart'),'--platform',
            os.path.join(OUT,'vm_platform_product.dill'),'--aot','--packages',PKG,
            '-o',d,APP],capture_output=True,text=True,timeout=3600,
            env=dict(os.environ, **envx))
        assert r.returncode==0, r.stderr[-900:]
    return d

def sections(aot):
    r=subprocess.run([READELF,'--sections',aot],capture_output=True,text=True)
    out={}
    for l in r.stdout.splitlines():
        m=re.match(r'\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+\S+\s+\S+\s+([0-9a-f]+)', l)
        if m: out[m.group(1)]=int(m.group(2),16)
    return out

ARMS=[
 ('A sel:OFF P1:norm inl:norm', {},                                        []),
 ('B sel:ON  P1:OFF  inl:OFF',  dict(SEL, MAOT_P1_CLEAR_MUTABLE_CONSTANTS='0'),
                                                    ['--maot_allow_inlining_mutable']),
 ('C sel:ON  P1:ON   inl:OFF',  dict(SEL),          ['--maot_allow_inlining_mutable']),
 ('D sel:ON  P1:ON   inl:ON',   dict(SEL),          []),
]
rows=[]
for i,(label, envx, extra) in enumerate(ARMS):
    ktag='k%d'%i
    dill=kernel(ktag, envx)
    aot=os.path.join(WD,'a%d.aot'%i); pre=os.path.join(WD,'p%d.json'%i)
    ret=os.path.join(WD,'r%d.txt'%i)
    r=subprocess.run([os.path.join(OUT,'gen_snapshot'),'--snapshot_kind=app-aot-elf',
        '--elf=%s'%aot,'--maot_namespace=%s'%NS,'--maot_dump_trampoline_shape',
        '--maot_dump_registry_precompile=%s'%pre,'--maot_dump_retained=%s'%ret]
        +BASEFLAGS+extra+[dill],capture_output=True,text=True,timeout=10800)
    assert r.returncode==0, [l for l in r.stderr.splitlines() if 'si_addr' in l]
    sec=sections(aot)
    sel=0
    if os.path.exists(pre):
        j=json.load(open(pre)); ents=j.get('entries', j if isinstance(j,list) else [])
        sel=sum(1 for e in ents if e.get('selected'))
    nret=sum(1 for _ in open(ret)) if os.path.exists(ret) else -1
    pool=None
    for l in r.stderr.splitlines():
        m=re.search(r'materialized_pool_len=(\d+)', l)
        if m: pool=int(m.group(1))
    od=os.path.join(WD,'o%d.dill'%i)
    if os.path.exists(od): os.remove(od)
    q=subprocess.run([os.path.join(OUT,'dartaotruntime'),aot,'--platform',
        os.path.join(OUT,'vm_platform_product.dill'),'--aot','--packages',PKG,'-o',od,src],
        capture_output=True,text=True,timeout=900,env=dict(os.environ,MAOT_NAMESPACE=NS))
    ok=q.returncode==0 and os.path.exists(od) and os.path.getsize(od)>0
    rows.append(dict(label=label, total=os.path.getsize(aot), text=sec.get('.text',0),
                     rodata=sec.get('.rodata',0), sel=sel, ret=nret, pool=pool, ok=ok))
    print('%-28s total=%8.2fMB text=%8.2fMB rodata=%8.2fMB sel=%-6d ret=%-7d pool=%-7s %s' % (
        label, rows[-1]['total']/1e6, rows[-1]['text']/1e6, rows[-1]['rodata']/1e6,
        sel, nret, pool, 'ok' if ok else 'FAIL'))
    sys.stdout.flush()
A=rows[0]
print('\n--- deltas vs A ---')
for r in rows[1:]:
    print('%-28s total %+8.2fMB (%+6.1f%%)  text %+8.2fMB (%+6.1f%%)  rodata %+8.2fMB (%+6.1f%%)' % (
        r['label'], (r['total']-A['total'])/1e6, 100*(r['total']-A['total'])/A['total'],
        (r['text']-A['text'])/1e6, 100*(r['text']-A['text'])/A['text'],
        (r['rodata']-A['rodata'])/1e6, 100*(r['rodata']-A['rodata'])/A['rodata']))
print('\n--- incremental ---')
for a,b in ((0,1),(1,2),(2,3)):
    x,y=rows[a],rows[b]
    print('%-28s -> %-28s total %+8.2fMB text %+8.2fMB rodata %+8.2fMB' % (
        x['label'][:2], y['label'][:2], (y['total']-x['total'])/1e6,
        (y['text']-x['text'])/1e6, (y['rodata']-x['rodata'])/1e6))
