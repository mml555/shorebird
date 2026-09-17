#!/usr/bin/env python3
"""Task A -- ARM64_AOT_INSTANCE_DISPATCH_MATRIX.

One fixture per subject, one declaration per FINAL AOT ROUTE, all installed in
the same run so every route is judged against the same frozen program. Each
route is judged on routing identities, not behaviour alone.
"""
import json, os, shutil, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from judge_m5 import FROZEN, MOVING, STAGES

FORK='/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT='/Volumes/build/route-b/flutter/engine/src/out/maot_host'
DART='/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart'
M5='/Users/mendell/shorebird/selfhost/engine/mutable_aot/m5/lib'
SCRATCH=os.path.dirname(os.path.abspath(__file__))
NS='ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'

# subject -> (fixture, package, [(cell-name, key-prefix, decl-suffix, route)])
SUBJECTS = {
 'method': ('fixture_m5_disp_method.dart', 'm5dispmethod', [
    ('direct',    'direct',  'cls:Direct::method:v',    'static-call -> trampoline -> cell'),
    ('virtual',   'virtual', 'cls:Virt::method:v',      'dispatch-table -> trampoline -> cell'),
    ('interface', 'iface',   'cls:Ifc::method:v',       'dispatch-table -> trampoline -> cell'),
    ('super',     'super',   'cls:SuperBase::method:v', 'inline #67 cell indirection'),
 ], 'cls:Other::method:v', 'other'),
}

def _rows(decl):
    return [
      ('direct',    'direct',  'cls:Direct::'+decl,    'static-call -> trampoline -> cell'),
      ('virtual',   'virtual', 'cls:Virt::'+decl,      'dispatch-table -> trampoline -> cell'),
      ('interface', 'iface',   'cls:Ifc::'+decl,       'dispatch-table -> trampoline -> cell'),
      ('super',     'super',   'cls:SuperBase::'+decl, 'inline #67 cell indirection'),
    ]

for _subj, _pkg, _decl in (
        ('getter',   'm5dispgetter',   'get:v'),
        ('setter',   'm5dispsetter',   'set:v'),
        ('operator', 'm5dispoperator', 'op:+'),
        ('callable', 'm5dispcallable', 'method:call')):
    SUBJECTS[_subj] = ('fixture_m5_disp_%s.dart' % _subj, _pkg, _rows(_decl),
                       'cls:Other::' + _decl, 'other')


def entry_for(path, suffix):
    if not os.path.exists(path): return None
    j=json.load(open(path)); ents=j.get('entries', j if isinstance(j,list) else [])
    for e in ents:
        if e.get('declaration_id','').endswith('::'+suffix): return e
    return None


def run_subject(subject):
    fixture, pkg, cells, ctrl_decl, ctrl_prefix = SUBJECTS[subject]
    wd=tempfile.mkdtemp(prefix='A_%s_'%subject)
    lib=os.path.join(wd,'pkg','lib'); os.makedirs(lib)
    shutil.copy(os.path.join(M5,fixture), os.path.join(lib,fixture))
    tool=os.path.join(wd,'pkg','.dart_tool'); os.makedirs(tool)
    json.dump({'configVersion':2,'packages':[{'name':pkg,'rootUri':'file://%s/'%os.path.join(wd,'pkg'),'packageUri':'lib/','languageVersion':'3.9'}]},open(os.path.join(tool,'package_config.json'),'w'))
    dill=os.path.join(wd,'app.dill')
    k=subprocess.run([DART,'--packages=%s'%os.path.join(FORK,'.dart_tool/package_config.json'),
        os.path.join(FORK,'pkg/vm/bin/gen_kernel.dart'),'--platform',
        os.path.join(OUT,'vm_platform_product.dill'),'--aot','--packages',
        os.path.join(tool,'package_config.json'),'-o',dill,'package:%s/%s'%(pkg,fixture)],
        capture_output=True,text=True,timeout=1800)
    assert k.returncode==0, k.stderr[-1200:]
    s=subprocess.run([os.path.join(OUT,'gen_snapshot'),'--snapshot_kind=app-aot-elf',
        '--elf=%s'%os.path.join(wd,'a.aot'),'--maot_namespace=%s'%NS,
        '--maot_install_trampolines','--maot_verify_pinned_body_traversal',dill],
        capture_output=True,text=True,timeout=1800)
    trav=[l.strip() for l in s.stderr.splitlines() if 'PINNED_TRAVERSAL' in l]
    assert s.returncode==0, [l for l in s.stderr.splitlines() if 'si_addr' in l]
    dumps=os.path.join(wd,'dumps'); os.makedirs(dumps,exist_ok=True)
    r=subprocess.run([os.path.join(OUT,'dartaotruntime'),os.path.join(wd,'a.aot')],
        capture_output=True,text=True,timeout=900,
        env=dict(os.environ,MAOT_NAMESPACE=NS,MAOT_DUMP_DIR=dumps))
    kv={}
    for l in r.stdout.splitlines():
        if '=' in l:
            a,_,b=l.partition('='); kv[a]=b
    assert r.returncode==0, r.stderr[-800:]
    print('traversal:', trav[0].split('verdict=')[-1] if trav else 'NO VERDICT')

    results=[]
    ctrl={n: entry_for(os.path.join(dumps,'registry_%s.json'%n), ctrl_decl) for n in STAGES}
    for cell, prefix, decl, route in cells:
        st={n: entry_for(os.path.join(dumps,'registry_%s.json'%n), decl) for n in STAGES}
        fails=[]; n=0
        def chk(name, ok, detail=''):
            nonlocal n
            n+=1
            if not ok: fails.append(f'{name}{(" "+detail) if detail else ""}')
        if not all(st.values()):
            results.append((cell, route, 'BLOCKED', ['no registry entry for '+decl], 0)); continue
        b0,b2,b3 = kv.get(prefix+'.0',''), kv.get(prefix+'.v2',''), kv.get(prefix+'.v3','')
        chk('baseline OLD', b0.startswith('OLD'), b0)
        chk('v2 NEW', b2.startswith('NEW') and not b2.startswith('NEW2') and b2!=b0, f'{b0}->{b2}')
        chk('v3 NEW2', b3.startswith('NEW2') and b3!=b2, f'{b2}->{b3}')
        form=cell.capitalize() if cell!='interface' else 'Ifc'
        form={'direct':'Direct','virtual':'Virt','interface':'Ifc','super':'Super'}[cell]
        chk('install v2', kv.get('install.%s.v2'%form)=='0', str(kv.get('install.%s.v2'%form)))
        chk('install v3', kv.get('install.%s.v3'%form)=='0', str(kv.get('install.%s.v3'%form)))
        chk('version 1/-102/-103',
            (kv.get('version.%s.0'%form),kv.get('version.%s.v2'%form),kv.get('version.%s.v3'%form))==('1','-102','-103'),
            str((kv.get('version.%s.0'%form),kv.get('version.%s.v2'%form),kv.get('version.%s.v3'%form))))
        for f in FROZEN:
            vals=[st[x].get(f) for x in STAGES]
            chk('frozen '+f, len(set(vals))==1 and vals[0] not in (None,0), str(vals))
        for f in MOVING:
            vals=[st[x].get(f) for x in STAGES]
            chk('moves '+f, len(set(vals))==3 and all(v not in (None,0) for v in vals), str(vals))
        for x in STAGES:
            e=st[x]
            chk(f'[{x}] cell code is pinned body', e.get('dispatch_cell_code_matches_pinned_current_body') is True)
            chk(f'[{x}] cell fn is current impl', e.get('dispatch_cell_function_matches_current_impl') is True)
            chk(f'[{x}] no self-cycle', e.get('id_cell_impl_code')!=e.get('id_trampoline_code'))
            chk(f'[{x}] installable', e.get('installable') is True)
            chk(f'[{x}] escapes==0', e.get('optimizer_escapes')==0, str(e.get('optimizer_escapes')))
            chk(f'[{x}] no blocking', e.get('blocking_records') in ('<none>',None,'',[]), str(e.get('blocking_records')))
        if all(ctrl.values()):
            for f in FROZEN+MOVING:
                vals=[ctrl[x].get(f) for x in STAGES]
                chk('control unchanged '+f, len(set(vals))==1, str(vals))
        chk('control behaviour unchanged',
            kv.get(ctrl_prefix+'.0')==kv.get(ctrl_prefix+'.v2')==kv.get(ctrl_prefix+'.v3'),
            f"{kv.get(ctrl_prefix+'.0')}/{kv.get(ctrl_prefix+'.v2')}/{kv.get(ctrl_prefix+'.v3')}")
        results.append((cell, route, 'PASS' if not fails else 'BLOCKED', fails, n))
    return results


if __name__=='__main__':
    for subj in sys.argv[1:] or list(SUBJECTS):
        print('===== subject: %s' % subj)
        for cell, route, verdict, fails, n in run_subject(subj):
            print('  %-10s %-38s %-7s (%d checks)' % (cell, route, verdict, n))
            for f in fails: print('        FAILED:', f)
