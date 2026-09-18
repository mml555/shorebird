#!/usr/bin/env python3
"""Replacement at scale, through the production StageReplacement path only.

400 declarations replaced per transaction (300 unique-body + 100 shared-body),
inside a large resident selected population. Identity stability is compared as
addresses across the baseline/V2/V3 registry dumps.
"""
import json, os, re, shutil, subprocess, sys, tempfile, time
FORK='/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT='/Volumes/build/route-b/flutter/engine/src/out/maot_host'
DART='/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart'
M5='/Users/mendell/shorebird/selfhost/engine/mutable_aot/m5/lib'
NS='ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
FROZEN=['id_declaration_function','id_declaration_current_code',
        'id_trampoline_code','id_trampoline_entry','id_dispatch_cell']
MOVING=['id_cell_impl_function','id_cell_impl_code','id_pinned_current_body']

wd=tempfile.mkdtemp(prefix='repl_')
lib=os.path.join(wd,'pkg','lib'); os.makedirs(lib)
shutil.copy(os.path.join(M5,'fixture_m5_replscale.dart'),
            os.path.join(lib,'fixture_m5_replscale.dart'))
tool=os.path.join(wd,'pkg','.dart_tool'); os.makedirs(tool)
json.dump({'configVersion':2,'packages':[{'name':'m5repl',
    'rootUri':'file://%s/'%os.path.join(wd,'pkg'),'packageUri':'lib/',
    'languageVersion':'3.9'}]},open(os.path.join(tool,'package_config.json'),'w'))
dill=os.path.join(wd,'app.dill')
t=time.time()
k=subprocess.run([DART,'--packages=%s'%os.path.join(FORK,'.dart_tool/package_config.json'),
    os.path.join(FORK,'pkg/vm/bin/gen_kernel.dart'),'--platform',
    os.path.join(OUT,'vm_platform_product.dill'),'--aot','--packages',
    os.path.join(tool,'package_config.json'),'-o',dill,
    'package:m5repl/fixture_m5_replscale.dart'],capture_output=True,text=True,
    timeout=3600, env=dict(os.environ, MAOT_SELECT_ALL_NON_SDK='1'))
assert k.returncode==0, k.stderr[-1500:]
print('kernel ok %.0fs' % (time.time()-t))

aot=os.path.join(wd,'a.aot'); pre=os.path.join(wd,'pre.json')
t=time.time()
s=subprocess.run([os.path.join(OUT,'gen_snapshot'),'--snapshot_kind=app-aot-elf',
    '--elf=%s'%aot,'--maot_namespace=%s'%NS,'--maot_install_trampolines',
    '--maot_verify_pinned_body_traversal','--maot_dump_trampoline_shape',
    '--maot_dump_registry_precompile=%s'%pre,dill],
    capture_output=True,text=True,timeout=10800)
print('snapshot rc=%d %.0fs %.1f MB' % (s.returncode, time.time()-t,
      os.path.getsize(aot)/1e6 if os.path.exists(aot) else -1))
for l in s.stderr.splitlines():
    if any(x in l for x in ('POST-DEDUP','PINNED_TRAVERSAL','BODY_PARTITION','si_addr')):
        print('  ', l.strip()[:160])
assert s.returncode==0
j=json.load(open(pre)); ents=j.get('entries', j if isinstance(j,list) else [])
sel=sum(1 for e in ents if e.get('selected'))
elig=sum(1 for e in ents if e.get('selected') and e.get('installable') is True)
print('  selected=%d eligible=%d refused=%d' % (sel, elig, sel-elig))

dumps=os.path.join(wd,'dumps'); os.makedirs(dumps,exist_ok=True)
t=time.time()
r=subprocess.run([os.path.join(OUT,'dartaotruntime'),aot],capture_output=True,
    text=True,timeout=1800,env=dict(os.environ,MAOT_NAMESPACE=NS,MAOT_DUMP_DIR=dumps))
print('runtime rc=%d %.0fs' % (r.returncode, time.time()-t))
kv={}
for l in r.stdout.splitlines():
    if '=' in l:
        a,_,b=l.partition('='); kv[a]=b
for key in ('probe.unique','probe.shared','probe.control','retained.impls',
            'v0.unique.OLD','v0.shared.OLDS','v0.control.CTL','v0.sample',
            'install.v2.ok','v2.unique.NEW','v2.shared.NEWS','v2.control.CTL','v2.sample',
            'install.v3.ok','v3.unique.NEW2','v3.shared.NEW2S','v3.control.CTL','v3.sample',
            'version.P0.0','version.P0.v2','version.P0.v3'):
    if key in kv: print('  %-20s %s' % (key, kv[key]))
if r.returncode!=0:
    print(r.stderr[-800:]); sys.exit(1)

def entry(stage, suffix):
    p=os.path.join(dumps,'registry_%s.json'%stage)
    if not os.path.exists(p): return None
    jj=json.load(open(p)); ee=jj.get('entries', jj if isinstance(jj,list) else [])
    for e in ee:
        if e.get('declaration_id','').endswith('::'+suffix): return e
    return None

print('\n--- identity stability across the transaction ---')
reps=[('unique P0','cls:P0::method:v'), ('unique P299','cls:P299::method:v'),
      ('shared S0','cls:S0::method:v'), ('shared S99','cls:S99::method:v'),
      ('control C0','cls:C0::method:v')]
allok=True
for label, suf in reps:
    st={n: entry(n, suf) for n in ('before','v2','v3')}
    if not all(st.values()):
        print('  %-12s MISSING DUMP ENTRY' % label); allok=False; continue
    froz=[f for f in FROZEN if len({st[n].get(f) for n in ('before','v2','v3')})!=1]
    is_ctl = label.startswith('control')
    mov=[f for f in MOVING if len({st[n].get(f) for n in ('before','v2','v3')})!=(1 if is_ctl else 3)]
    selfcyc=[n for n in ('before','v2','v3')
             if st[n].get('id_cell_impl_code')==st[n].get('id_trampoline_code')]
    ok = not froz and not mov and not selfcyc
    allok = allok and ok
    print('  %-12s frozen_moved=%s  impl_%s=%s  self_cycle=%s  %s' % (
        label, froz or 'none', 'unchanged' if is_ctl else 'advanced_twice',
        mov or 'ok', selfcyc or 'none', 'PASS' if ok else 'FAIL'))
    if label=='unique P0':
        for n in ('before','v2','v3'):
            print('      %-6s implFunction=%s implCode=%s pinnedBody=%s' % (n,
                st[n].get('id_cell_impl_function'), st[n].get('id_cell_impl_code'),
                st[n].get('id_pinned_current_body')))
print('\nidentity stability: %s' % ('PASS' if allok else 'FAIL'))
