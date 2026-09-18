#!/usr/bin/env python3
"""MAOT_DIAGNOSTICS_DISABLED_NO_WORK.

With relocation tracing off the provenance/classification path must not
execute -- not merely stay silent. Asserting "it did not run" requires a
number that exists when it is switched off, so the count is reported
unconditionally, once per relocation pass.
"""
import os, re, subprocess, sys
OUT='/Volumes/build/route-b/flutter/engine/src/out/maot_host'
NS='ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
WD='/private/tmp/claude-501/-Users-mendell-shorebird/541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/massdiag'
DILL=os.path.join(WD,'app_all.dill')

def run(extra):
    r=subprocess.run([os.path.join(OUT,'gen_snapshot'),'--snapshot_kind=app-aot-elf',
        '--elf=%s'%os.path.join(WD,'hyg.aot'),'--maot_namespace=%s'%NS]+extra+[DILL],
        capture_output=True,text=True,timeout=7200)
    ns=[int(m.group(1)) for m in
        re.finditer(r'DIAG_CLASSIFICATIONS n=(\d+)', r.stderr)]
    return r.returncode, ns

rc_off, off = run([])
rc_on,  on  = run(['--maot_trace_serializer'])
print('trace OFF rc=%d classifications=%s' % (rc_off, off))
print('trace ON  rc=%d classifications=%s' % (rc_on, on[:2] if on else on))
ok_off = bool(off) and max(off) == 0
ok_on  = bool(on) and max(on) > 0
print('\ntrace OFF -> classifications == 0 : %s' % ('PASS' if ok_off else 'FAIL'))
print('trace ON  -> classifications  > 0 : %s' % ('PASS' if ok_on else 'FAIL'))
print('MAOT_DIAGNOSTICS_DISABLED_NO_WORK: %s' %
      ('PASS' if (ok_off and ok_on and rc_off==0) else 'FAIL'))
sys.exit(0 if (ok_off and ok_on and rc_off==0) else 1)
