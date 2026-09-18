#!/usr/bin/env python3
"""ASan paired run for REALAPP_MAOT_SELECTION_PRECOMPILER.

Arm A: control kernel (normal selection)
Arm B: select-all kernel, installation OFF   <- the minimal reproducer

Both kernels come from the same source and differ only by
MAOT_SELECT_ALL_NON_SDK at gen_kernel time -- selection is baked into the
kernel, so "same kernel with select-all off" is not constructible. That is a
real constraint on the control, recorded rather than glossed.
"""
import hashlib, os, subprocess, sys, time
FORK='/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
SRC='/Volumes/build/route-b/flutter/engine/src'
OUT=os.path.join(SRC,'out/maot_host')
ASAN=os.path.join(SRC,'out/maot_asan')
CLANGBIN=os.path.join(SRC,'flutter/buildtools/mac-arm64/clang/bin')
DART='/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart'
APP='/Users/mendell/shorebird/packages/shorebird_cli/bin/shorebird.dart'
PKGCFG='/Users/mendell/shorebird/.dart_tool/package_config.json'
NS='ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
WD='/private/tmp/claude-501/-Users-mendell-shorebird/541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/massdiag'

def sha(p):
    h=hashlib.sha256()
    with open(p,'rb') as f:
        for b in iter(lambda: f.read(1<<20), b''): h.update(b)
    return h.hexdigest()[:16]

ctl=os.path.join(WD,'app_ctl.dill')
if not os.path.exists(ctl):
    r=subprocess.run([DART,'--packages=%s'%os.path.join(FORK,'.dart_tool/package_config.json'),
        os.path.join(FORK,'pkg/vm/bin/gen_kernel.dart'),'--platform',
        os.path.join(OUT,'vm_platform_product.dill'),'--aot','--packages',PKGCFG,
        '-o',ctl,APP],capture_output=True,text=True,timeout=3600)
    assert r.returncode==0, r.stderr[-1200:]
allk=os.path.join(WD,'app_all.dill')
print('kernel sha256[:16]  control=%s  select-all=%s' % (sha(ctl), sha(allk)))

env=dict(os.environ)
# Dart's own handler traps the fault and aborts before ASan can report.
env['DART_NO_CRASH_HANDLER']='1'
env['ASAN_OPTIONS']='detect_leaks=0:symbolize=1:print_stacktrace=1:halt_on_error=1:abort_on_error=0'
sym=os.path.join(CLANGBIN,'llvm-symbolizer')
if os.path.exists(sym): env['ASAN_SYMBOLIZER_PATH']=sym

for tag, dill in (('A control (normal selection)', ctl),
                  ('B select-all, install OFF', allk)):
    t=time.time()
    r=subprocess.run([os.path.join(ASAN,'gen_snapshot'),'--snapshot_kind=app-aot-elf',
        '--elf=%s'%os.path.join(WD,'asan_%s.aot'%tag.split()[0]),
        '--maot_namespace=%s'%NS, dill],
        capture_output=True,text=True,timeout=10800,env=env)
    print('\n===== %s  rc=%d  %.0fs' % (tag, r.returncode, time.time()-t))
    err=r.stderr
    if 'ERROR: AddressSanitizer' in err or 'SUMMARY: AddressSanitizer' in err:
        i=err.index('ERROR: AddressSanitizer') if 'ERROR: AddressSanitizer' in err else 0
        for l in err[i:].splitlines()[:40]: print('   ', l[:165])
    else:
        for l in err.strip().splitlines()[-8:]: print('   ', l[:165])
