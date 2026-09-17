#!/usr/bin/env python3
"""Task C -- real-application population gate.

Subject: shorebird_cli (208 files, ~36.6k lines, 45 direct deps) -- a real
Dart application that can be both snapshotted and RUN on the host.

Arm A: normal selection, MAOT installation OFF   (control)
Arm B: MAOT_SELECT_ALL_NON_SDK=1, installation ON

selected / eligible / installed / refused are reported SEPARATELY. A refused
declaration is never folded into a denominator to make a ratio look better.
"""
import json, os, re, shutil, subprocess, sys, tempfile, time

FORK='/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT='/Volumes/build/route-b/flutter/engine/src/out/maot_host'
DART='/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart'
APP='/Users/mendell/shorebird/packages/shorebird_cli/bin/shorebird.dart'
PKGCFG='/Users/mendell/shorebird/.dart_tool/package_config.json'
NS='ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
WD=tempfile.mkdtemp(prefix='realapp_')


def kernel(tag, env_extra):
    dill=os.path.join(WD,'app_%s.dill'%tag)
    env=dict(os.environ, **env_extra)
    t=time.time()
    r=subprocess.run([DART,'--packages=%s'%os.path.join(FORK,'.dart_tool/package_config.json'),
        os.path.join(FORK,'pkg/vm/bin/gen_kernel.dart'),'--platform',
        os.path.join(OUT,'vm_platform_product.dill'),'--aot','--packages',PKGCFG,
        '-o',dill,APP], capture_output=True,text=True,timeout=3600,env=env)
    if r.returncode!=0:
        print('  KERNEL FAIL:', r.stderr.strip().splitlines()[-3:]); return None,0
    return dill, time.time()-t


def snapshot(tag, dill, install):
    aot=os.path.join(WD,'app_%s.aot'%tag)
    pre=os.path.join(WD,'reg_%s.json'%tag)
    cmd=[os.path.join(OUT,'gen_snapshot'),'--snapshot_kind=app-aot-elf',
         '--elf=%s'%aot,'--maot_namespace=%s'%NS,
         '--maot_dump_registry_precompile=%s'%pre]
    if install:
        cmd += ['--maot_install_trampolines','--maot_verify_pinned_body_traversal',
                '--maot_dump_trampoline_shape']
    cmd.append(dill)
    t=time.time()
    r=subprocess.run(cmd,capture_output=True,text=True,timeout=7200)
    return aot, pre, r, time.time()-t


def report(tag, dill, install, ktime):
    aot, pre, r, stime = snapshot(tag, dill, install)
    print('  snapshot rc=%d  %.1fs' % (r.returncode, stime))
    if r.returncode!=0:
        for l in r.stderr.splitlines():
            if 'si_addr' in l or 'FAIL' in l: print('    ', l.strip()[:140])
        tail=r.stderr.strip().splitlines()[-4:]
        for l in tail: print('    ', l.strip()[:140])
        return
    print('  snapshot size = %.1f MB' % (os.path.getsize(aot)/1e6))
    print('  kernel time   = %.1fs' % ktime)
    sel=elig=ref=0; reasons={}
    if os.path.exists(pre):
        j=json.load(open(pre)); ents=j.get('entries', j if isinstance(j,list) else [])
        for e in ents:
            if not e.get('selected'): continue
            sel+=1
            if e.get('installable') is True: elig+=1
            else:
                ref+=1
                why=str(e.get('first_escape_reason') or e.get('blocking_records') or '?')
                reasons[why]=reasons.get(why,0)+1
    inst=dist=None
    for l in r.stderr.splitlines():
        m=re.search(r'POST-DEDUP trampolines: installed=(\d+) distinct=(\d+)', l)
        if m: inst,dist=int(m.group(1)),int(m.group(2))
    trav=[l.strip() for l in r.stderr.splitlines() if 'PINNED_TRAVERSAL' in l]
    print('  selected=%d  eligible=%d  refused=%d' % (sel, elig, ref))
    if ref:
        print('  refusal reasons (top):')
        for w,c in sorted(reasons.items(), key=lambda kv:-kv[1])[:6]:
            print('      %-6d %s' % (c, w[:100]))
    if inst is not None:
        print('  installed=%d  distinct=%d  %s' % (inst, dist,
              'MATCH' if inst==dist else 'IDENTITY COLLAPSE'))
        print('  installed vs eligible: %s' % ('MATCH' if inst==elig else
              'MISMATCH (installed=%d eligible=%d)'%(inst,elig)))
    if trav: print('  %s' % trav[0])
    q=subprocess.run([os.path.join(OUT,'dartaotruntime'),aot,'--version'],
        capture_output=True,text=True,timeout=300,
        env=dict(os.environ,MAOT_NAMESPACE=NS))
    out=(q.stdout+q.stderr).strip().replace('\n',' | ')[:160]
    print('  runtime rc=%d | %s' % (q.returncode, out))


print('===== ARM A: normal selection, installation OFF (control)')
d,kt = kernel('ctl', {})
if d: report('ctl', d, False, kt)
print()
print('===== ARM B: MAOT_SELECT_ALL_NON_SDK=1, installation ON')
d,kt = kernel('all', {'MAOT_SELECT_ALL_NON_SDK':'1'})
if d: report('all', d, True, kt)
