#!/usr/bin/env python3
"""Measure what each source dispatch form lowers to in final AOT code.

Classification is read off the emitted instructions, not from source syntax:

  #67 cell indirection : ldr cell from PP; ldur cell[0]; ldur fn.entry; blr
  switchable call      : ldp x30,x5,[PP+off]; blr x30
  dispatch table       : ldr from THR dispatch-table base, indexed; blr
  direct pc-relative   : bl <fixed offset>
"""
import json, os, re, shutil, subprocess, sys, tempfile

FORK='/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT='/Volumes/build/route-b/flutter/engine/src/out/maot_host'
DART='/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart'
CLANG='/Volumes/build/route-b/flutter/engine/src/flutter/buildtools/mac-arm64/clang/bin/clang'
OBJ='/Volumes/build/route-b/flutter/engine/src/flutter/buildtools/mac-arm64/clang/bin/llvm-objdump'
M5='/Users/mendell/shorebird/selfhost/engine/mutable_aot/m5/lib'
SCRATCH=os.path.dirname(os.path.abspath(__file__))
NS='ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
DUMP='/tmp/maot_caller_code.txt'


def disasm(words, tag):
    sp=os.path.join(SCRATCH,'lw_%s.s'%tag)
    with open(sp,'w') as f:
        f.write('.text\n.globl _f\n_f:\n')
        for w in words.split(): f.write('  .long 0x%s\n'%w)
    op=sp[:-2]+'.o'
    subprocess.run([CLANG,'-c','-target','arm64-apple-macos','-o',op,sp],check=True,
                   capture_output=True)
    r=subprocess.run([OBJ,'-d','--no-show-raw-insn',op],capture_output=True,text=True)
    return r.stdout


def classify(text):
    """Return (route, evidence-line)."""
    lines=[l.strip() for l in text.splitlines()]
    joined='\n'.join(lines)
    # #67 cell indirection: two chained ldur off a pool-loaded object then blr.
    m=re.search(r'ldr\s+(x\d+), \[x27[^\]]*\]\s*\n\s*\d+:\s*ldur\s+\1, \[\1, #0x17\]', joined)
    if re.search(r'ldur\s+x\d+, \[x\d+, #0x17\]', joined) and re.search(r'ldur\s+x30, \[x\d+, #0x7\]', joined):
        return 'cell-indirection(#67)', 'ldur cell[0x17] -> ldur entry[0x7] -> blr'
    if re.search(r'ldur\s+x\d+, \[x\d+, #0x1f\]', joined) and re.search(r'br\s+x16', joined):
        return 'trampoline(cell[0x1f])', 'ldur cell[0x1f] -> br'
    if re.search(r'ldp\s+x30, x5, \[x\d+\]', joined):
        return 'switchable-call', 'ldp x30,x5,[PP+off] -> blr x30'
    if re.search(r'ldr\s+x\d+, \[x2[16], #0x[0-9a-f]+\]\s*\n\s*\d+:\s*ldr\s+x\d+, \[x\d+, x\d+, lsl #3\]', joined):
        return 'dispatch-table', 'indexed load from dispatch table -> blr'
    if re.search(r'ldr\s+x\d+, \[x\d+, x\d+, lsl #3\]', joined):
        return 'dispatch-table', 'indexed table load -> blr'
    bl=[l for l in lines if re.match(r'^\d+:\s+bl\s', l)]
    if bl:
        return 'direct-pc-relative', bl[-1]
    return 'UNCLASSIFIED', joined[-200:]


def survey(fixture, pkg, sites):
    wd=tempfile.mkdtemp(prefix='lower_')
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
    if k.returncode: print('KERNEL FAIL\n'+k.stderr[-1500:]); return
    if os.path.exists(DUMP): os.remove(DUMP)
    s=subprocess.run([os.path.join(OUT,'gen_snapshot'),'--snapshot_kind=app-aot-elf',
        '--elf=%s'%os.path.join(wd,'a.aot'),'--maot_namespace=%s'%NS,
        '--maot_install_trampolines','--maot_dump_caller_code=site', dill],
        capture_output=True,text=True,timeout=1800)
    print('snapshot rc',s.returncode)
    if s.returncode: 
        for l in s.stderr.splitlines():
            if 'si_addr' in l: print('  ',l.strip())
        return
    txt=open(DUMP).read() if os.path.exists(DUMP) else ''
    blocks=re.findall(r'\[stage=([^\]]+)\] (\S+) size=(\d+)\n\[words\]([0-9a-f ]+)\n', txt)
    last={}
    for stage,name,size,words in blocks:
        last[name]=words
    for want in sites:
        hits=[n for n in last if n.endswith(want)]
        if not hits:
            print('  %-14s NOT EMITTED (name not found)'%want); continue
        route,ev=classify(disasm(last[hits[0]], want))
        print('  %-14s -> %-24s %s' % (want, route, ev[:70]))


if __name__ == '__main__':
    print('=== method subject: source form -> final AOT routing ===')
    survey('fixture_m5_lower_method.dart','m5lowermethod',
           ['_siteDirect','_siteVirtual','_siteIface','_siteSuper','_callSuper'])
