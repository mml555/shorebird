#!/usr/bin/env python3
"""Stage 39 acceptance: diagnostics ON, diagnostics NOT serialized.

Same A/B subject and flags as Stage 37/38 so the delta is directly comparable.
"""
import collections, json, os, re, subprocess, sys
FORK='/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT='/Volumes/build/route-b/flutter/engine/src/out/maot_host'
READELF='/Volumes/build/route-b/flutter/engine/src/flutter/buildtools/mac-arm64/clang/bin/llvm-readelf'
PKG=os.path.join(FORK,'.dart_tool/package_config.json')
NS='ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
WD='/private/tmp/claude-501/-Users-mendell-shorebird/541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/sizemat'
S39=WD+'/s39'; os.makedirs(S39, exist_ok=True)
FLAGS=['--maot_disable_call_indirection','--maot_disable_retention_roots']
PROSE=[b'one warmed call site in this state observed successive',
       b'no install decision reads a slot-preserving record',
       b'MaotRegistry::StageReplacement refuses installation while']

def sections(aot):
    r=subprocess.run([READELF,'--sections',aot],capture_output=True,text=True)
    out={}
    for l in r.stdout.splitlines():
        m=re.match(r'\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+\S+\s+\S+\s+([0-9a-f]+)', l)
        if m: out[m.group(1)]=int(m.group(2),16)
    return out

def load(prof):
    j=json.load(open(prof)); meta=j['snapshot']['meta']
    f=meta['node_fields']; types=meta['node_types'][0]
    ti,si=f.index('type'),f.index('self_size'); n=len(f); nodes=j['nodes']
    by=collections.Counter(); cnt=collections.Counter()
    for k in range(0,len(nodes),n):
        t=types[nodes[k+ti]] if nodes[k+ti]<len(types) else str(nodes[k+ti])
        by[t]+=nodes[k+si]; cnt[t]+=1
    return by,cnt

def run(tag, dill, extra):
    aot=os.path.join(S39,'%s.aot'%tag); prof=os.path.join(S39,'%s.prof'%tag)
    dump=os.path.join(S39,'%s.registry.json'%tag)
    r=subprocess.run([os.path.join(OUT,'gen_snapshot'),'--snapshot_kind=app-aot-elf',
        '--elf=%s'%aot,'--maot_namespace=%s'%NS,
        '--write_v8_snapshot_profile_to=%s'%prof,
        '--maot_dump_registry_precompile=%s'%dump]+FLAGS+extra+[dill],
        capture_output=True,text=True,timeout=10800)
    assert r.returncode==0, r.stderr[-500:]
    by,cnt=load(prof)
    sel=elig=0; dec=0
    if os.path.exists(dump):
        j=json.load(open(dump)); ents=j.get('entries', j if isinstance(j,list) else [])
        for e in ents:
            if e.get('selected'):
                sel+=1
                if e.get('installable') is True: elig+=1
        dec=j.get('optimizer_decision_count', -1) if isinstance(j,dict) else -1
    blob=open(aot,'rb').read()
    hits={p.decode()[:34]: blob.count(p) for p in PROSE}
    return dict(tag=tag, aot=aot, size=os.path.getsize(aot), sec=sections(aot),
                by=by, cnt=cnt, sel=sel, elig=elig, dec=dec, hits=hits)

A=run('A', os.path.join(WD,'k0.dill'), [])
B=run('B', os.path.join(WD,'k1.dill'), ['--maot_allow_inlining_mutable'])
print('%-3s %-9s %-9s %-9s %-7s %-7s %-9s' % ('arm','total MB','.text MB','.rodata MB','sel','elig','decisions'))
for r in (A,B):
    print('%-3s %-9.2f %-9.2f %-9.2f %-7d %-7d %-9d' % (r['tag'], r['size']/1e6,
        r['sec'].get('.text',0)/1e6, r['sec'].get('.rodata',0)/1e6,
        r['sel'], r['elig'], r['dec']))
d=B['size']-A['size']
print('\nSTAGE39 selection-only delta = %+.2f MB (%+.1f%%)   [STAGE38 was +9.10 MB / +67.9%%]' % (d/1e6, 100*d/A['size']))
print('.rodata delta = %+.2f MB   .text delta = %+.2f MB' % (
  (B['sec'].get('.rodata',0)-A['sec'].get('.rodata',0))/1e6,
  (B['sec'].get('.text',0)-A['sec'].get('.text',0))/1e6))
print('\n--- object deltas ---')
for t in ('(RO) String','CanonicalString','Array','(RO) Instructions','Code','Function'):
    print('  %-20s bytes %+8.2f MB   count %+8d' % (t,
      (B['by'][t]-A['by'][t])/1e6, B['cnt'][t]-A['cnt'][t]))
print('\n--- DIAGNOSTIC_RECORDS_SERIALIZED ---')
tot=0
for k,v in B['hits'].items():
    print('  %-36s occurrences in snapshot: %d' % (k, v)); tot+=v
print('  TOTAL prose occurrences in B snapshot = %d  -> %s' % (tot, 'PASS' if tot==0 else 'FAIL'))
print('  evidence records still produced (B) = %d -> %s' % (B['dec'],
      'PASS' if B['dec']>0 else 'FAIL'))
