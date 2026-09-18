#!/usr/bin/env python3
"""Gate A -- clean scale baselines, plus the installed/pinned-body partition.

All earlier timings are contaminated by the ungated diagnostic and are retired.
Three arms separate selection/precompiler cost from trampoline installation
cost; three repetitions each, reported as median with range.

  A. normal selection,          install OFF
  B. SELECT_ALL_NON_SDK=1,      install OFF
  C. SELECT_ALL_NON_SDK=1,      install ON
"""
import json, os, re, statistics, subprocess, sys, time
FORK='/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT='/Volumes/build/route-b/flutter/engine/src/out/maot_host'
DART='/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart'
APP='/Users/mendell/shorebird/packages/shorebird_cli/bin/shorebird.dart'
PKGCFG='/Users/mendell/shorebird/.dart_tool/package_config.json'
NS='ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
WD='/private/tmp/claude-501/-Users-mendell-shorebird/541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/massdiag'
REPS=3

def kernel(tag, env_extra):
    dill=os.path.join(WD,'gA_%s.dill'%tag)
    ts=[]
    for i in range(REPS):
        t=time.time()
        r=subprocess.run([DART,'--packages=%s'%os.path.join(FORK,'.dart_tool/package_config.json'),
            os.path.join(FORK,'pkg/vm/bin/gen_kernel.dart'),'--platform',
            os.path.join(OUT,'vm_platform_product.dill'),'--aot','--packages',PKGCFG,
            '-o',dill,APP],capture_output=True,text=True,timeout=3600,
            env=dict(os.environ, **env_extra))
        assert r.returncode==0, r.stderr[-800:]
        ts.append(time.time()-t)
    return dill, ts

def snap(tag, dill, install):
    aot=os.path.join(WD,'gA_%s.aot'%tag); pre=os.path.join(WD,'gA_%s.json'%tag)
    ts=[]; last=None
    for i in range(REPS):
        cmd=[os.path.join(OUT,'gen_snapshot'),'--snapshot_kind=app-aot-elf',
             '--elf=%s'%aot,'--maot_namespace=%s'%NS,
             '--maot_dump_registry_precompile=%s'%pre]
        if install:
            cmd += ['--maot_install_trampolines','--maot_verify_pinned_body_traversal',
                    '--maot_dump_trampoline_shape']
        cmd.append(dill)
        t=time.time()
        r=subprocess.run(cmd,capture_output=True,text=True,timeout=7200)
        assert r.returncode==0, [l for l in r.stderr.splitlines() if 'si_addr' in l] or r.returncode
        ts.append(time.time()-t); last=r
    return aot, pre, ts, last

def stat(ts):
    return '%.1f  [%.1f-%.1f]' % (statistics.median(ts), min(ts), max(ts))

ARMS=[('A', {}, False), ('B', {'MAOT_SELECT_ALL_NON_SDK':'1'}, False),
      ('C', {'MAOT_SELECT_ALL_NON_SDK':'1'}, True)]
rows=[]
for tag, envx, install in ARMS:
    dill, kts = kernel(tag, envx)
    aot, pre, sts, last = snap(tag, dill, install)
    sel=elig=ref=0
    if os.path.exists(pre):
        j=json.load(open(pre)); ents=j.get('entries', j if isinstance(j,list) else [])
        for e in ents:
            if not e.get('selected'): continue
            sel+=1
            if e.get('installable') is True: elig+=1
            else: ref+=1
    inst=dist=bodies=nonleaf=None; part=''
    for l in last.stderr.splitlines():
        m=re.search(r'POST-DEDUP trampolines: installed=(\d+) distinct=(\d+)', l)
        if m: inst,dist=int(m.group(1)),int(m.group(2))
        m=re.search(r'PINNED_TRAVERSAL bodies=(\d+).*non_leaf_bodies=(\d+)', l)
        if m: bodies,nonleaf=int(m.group(1)),int(m.group(2))
        if 'BODY_PARTITION' in l: part=l.strip()
    rows.append(dict(tag=tag, kernel_s=stat(kts), snap_s=stat(sts),
        kernel_mb=os.path.getsize(dill)/1e6, snap_mb=os.path.getsize(aot)/1e6,
        sel=sel, elig=elig, ref=ref, inst=inst, dist=dist,
        bodies=bodies, nonleaf=nonleaf, part=part))

print('%-4s %-16s %-16s %-9s %-9s %-7s %-7s %-6s %-7s %-7s' % (
      'arm','kernel s (med[rng])','snap s (med[rng])','kern MB','snap MB',
      'sel','elig','ref','inst','bodies'))
for r in rows:
    print('%-4s %-16s %-16s %-9.1f %-9.1f %-7s %-7s %-6s %-7s %-7s' % (
      r['tag'], r['kernel_s'], r['snap_s'], r['kernel_mb'], r['snap_mb'],
      r['sel'], r['elig'], r['ref'], r['inst'], r['bodies']))
print()
for r in rows:
    if r['sel']:
        print('arm %s: eligible+refused == selected : %s (%d+%d==%d)' % (
            r['tag'], 'PASS' if r['elig']+r['ref']==r['sel'] else 'FAIL',
            r['elig'], r['ref'], r['sel']))
    if r['inst'] is not None:
        print('arm %s: installed==distinct : %s' % (
            r['tag'], 'PASS' if r['inst']==r['dist'] else 'FAIL'))
    if r['part']: print('arm %s: %s' % (r['tag'], r['part']))
