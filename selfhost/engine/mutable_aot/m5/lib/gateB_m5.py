#!/usr/bin/env python3
"""Gate B -- runnable real application under mass selection.

Subject: pkg/vm/bin/gen_kernel.dart, the Dart front-end driver. A real,
large application (whole CFE + kernel libraries) that runs standalone and does
verifiable work, unlike shorebird_cli which needs an install tree it cannot
find here. That substitution is an app-configuration constraint, not a MAOT
result.

Configuration: MAOT_SELECT_ALL_NON_SDK=1, installation ON.
"""
import os, re, subprocess, sys, time
FORK='/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT='/Volumes/build/route-b/flutter/engine/src/out/maot_host'
DART='/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart'
NS='ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
WD='/private/tmp/claude-501/-Users-mendell-shorebird/541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/massdiag'
APP=os.path.join(FORK,'pkg/vm/bin/gen_kernel.dart')
PKG=os.path.join(FORK,'.dart_tool/package_config.json')

dill=os.path.join(WD,'gk.dill')
t=time.time()
r=subprocess.run([DART,'--packages=%s'%PKG,os.path.join(FORK,'pkg/vm/bin/gen_kernel.dart'),
    '--platform',os.path.join(OUT,'vm_platform_product.dill'),'--aot','--packages',PKG,
    '-o',dill,APP],capture_output=True,text=True,timeout=3600,
    env=dict(os.environ, MAOT_SELECT_ALL_NON_SDK='1'))
if r.returncode!=0:
    print('KERNEL FAIL:', r.stderr.strip().splitlines()[-4:]); sys.exit(1)
print('kernel ok  %.0fs  %.1f MB' % (time.time()-t, os.path.getsize(dill)/1e6))

aot=os.path.join(WD,'gk.aot'); pre=os.path.join(WD,'gk_reg.json')
t=time.time()
s=subprocess.run([os.path.join(OUT,'gen_snapshot'),'--snapshot_kind=app-aot-elf',
    '--elf=%s'%aot,'--maot_namespace=%s'%NS,'--maot_install_trampolines',
    '--maot_verify_pinned_body_traversal','--maot_dump_trampoline_shape',
    '--maot_dump_registry_precompile=%s'%pre, dill],
    capture_output=True,text=True,timeout=10800)
print('snapshot rc=%d  %.0fs  %.1f MB' % (s.returncode, time.time()-t,
      os.path.getsize(aot)/1e6 if os.path.exists(aot) else -1))
for l in s.stderr.splitlines():
    if any(k in l for k in ('POST-DEDUP','PINNED_TRAVERSAL','BODY_PARTITION','si_addr')):
        print('  ', l.strip()[:160])
if s.returncode!=0: sys.exit(1)

import json
j=json.load(open(pre)); ents=j.get('entries', j if isinstance(j,list) else [])
sel=sum(1 for e in ents if e.get('selected'))
elig=sum(1 for e in ents if e.get('selected') and e.get('installable') is True)
print('  selected=%d eligible=%d refused=%d' % (sel, elig, sel-elig))

# RUNTIME: the artifact must launch and do real work.
src=os.path.join(WD,'hello.dart')
open(src,'w').write("void main() { print('hello'); }\n")
outdill=os.path.join(WD,'hello.dill')
if os.path.exists(outdill): os.remove(outdill)
t=time.time()
q=subprocess.run([os.path.join(OUT,'dartaotruntime'),aot,
    '--platform',os.path.join(OUT,'vm_platform_product.dill'),
    '--aot','--packages',PKG,'-o',outdill,src],
    capture_output=True,text=True,timeout=900,
    env=dict(os.environ, MAOT_NAMESPACE=NS))
print('\nruntime rc=%d  %.0fs' % (q.returncode, time.time()-t))
if q.returncode!=0:
    print('  stderr:', q.stderr.strip()[-600:])
else:
    ok=os.path.exists(outdill) and os.path.getsize(outdill)>0
    print('  produced %s (%d bytes) -> %s' % (os.path.basename(outdill),
          os.path.getsize(outdill) if ok else 0, 'REAL WORK DONE' if ok else 'NO OUTPUT'))
