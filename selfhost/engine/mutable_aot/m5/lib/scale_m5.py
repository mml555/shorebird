#!/usr/bin/env python3
"""Where does serialization stop working as the selected population grows?

One kernel, built once. Only --maot_limit_selected varies, so population size
is the single independent variable. Each point records the snapshot result and
the traversal verdict, so a failure is characterised rather than just counted.
"""
import json, os, re, shutil, subprocess, sys, tempfile, time
FORK='/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT='/Volumes/build/route-b/flutter/engine/src/out/maot_host'
DART='/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart'
M5='/Users/mendell/shorebird/selfhost/engine/mutable_aot/m5/lib'
NS='ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'

wd=tempfile.mkdtemp(prefix='scale_')
lib=os.path.join(wd,'pkg','lib'); os.makedirs(lib)
shutil.copy(os.path.join(M5,'fixture_m5_scale.dart'), os.path.join(lib,'fixture_m5_scale.dart'))
tool=os.path.join(wd,'pkg','.dart_tool'); os.makedirs(tool)
json.dump({'configVersion':2,'packages':[{'name':'m5scale','rootUri':'file://%s/'%os.path.join(wd,'pkg'),'packageUri':'lib/','languageVersion':'3.9'}]},open(os.path.join(tool,'package_config.json'),'w'))
dill=os.path.join(wd,'app.dill')
t=time.time()
k=subprocess.run([DART,'--packages=%s'%os.path.join(FORK,'.dart_tool/package_config.json'),
    os.path.join(FORK,'pkg/vm/bin/gen_kernel.dart'),'--platform',
    os.path.join(OUT,'vm_platform_product.dill'),'--aot','--packages',
    os.path.join(tool,'package_config.json'),'-o',dill,'package:m5scale/fixture_m5_scale.dart'],
    capture_output=True,text=True,timeout=3600)
assert k.returncode==0, k.stderr[-1500:]
print('kernel ok in %.0fs' % (time.time()-t))

print('%-7s %-9s %-10s %-12s %-7s %s' % ('N','snapshot','installed','bodies/nonleaf','secs','verdict'))
for n in [1,2,4,8,16,32,64,128,256,512]:
    t=time.time()
    r=subprocess.run([os.path.join(OUT,'gen_snapshot'),'--snapshot_kind=app-aot-elf',
        '--elf=%s'%os.path.join(wd,'a_%d.aot'%n),'--maot_namespace=%s'%NS,
        '--maot_install_trampolines','--maot_limit_selected=%d'%n,
        # Without this the installed= line is never printed, and a flat PASS
        # column would say nothing about how large a population was actually
        # built. The population is the variable under test.
        '--maot_dump_trampoline_shape',
        '--maot_verify_pinned_body_traversal',dill],
        capture_output=True,text=True,timeout=3600)
    secs=time.time()-t
    inst=''
    for l in r.stderr.splitlines():
        m=re.search(r'POST-DEDUP trampolines: installed=(\d+) distinct=(\d+)', l)
        if m: inst='%s/%s'%(m.group(1),m.group(2))
    trav=[l for l in r.stderr.splitlines() if 'PINNED_TRAVERSAL' in l]
    bodies=''
    if trav:
        m2=re.search(r'bodies=(\d+).*non_leaf_bodies=(\d+)', trav[0])
        if m2: bodies='%s/%s'%(m2.group(1),m2.group(2))
    note=''
    if r.returncode!=0:
        sig=[l.strip() for l in r.stderr.splitlines() if 'si_addr' in l]
        note='rc=%d %s' % (r.returncode, sig[0][:60] if sig else r.stderr.strip().splitlines()[-1][:60] if r.stderr.strip() else '')
    elif trav:
        note=trav[0].split('verdict=')[-1].strip()
    print('%-7d %-9s %-10s %-12s %-7.1f %s' % (n, 'ok' if r.returncode==0 else 'FAIL', inst or '<none>', bodies or '<none>', secs, note))
    sys.stdout.flush()
    if r.returncode!=0:
        print('  first failure at N=%d -- stderr tail:' % n)
        for l in r.stderr.strip().splitlines()[-6:]:
            print('   ', l.strip()[:150])
        break
