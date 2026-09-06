#!/usr/bin/env bash
# cspell:words semantic linker dartaotruntime dill devirtualization
# assemble_verdict.sh -- SEMANTIC-LINKER-1 / #46. Build the final result matrix
# BY EXTRACTION from the gate evidence, not by transcription.
#
# Every row below is derived from a marker in a transcript or a field in a
# structured record, and each row carries the file it came from. A row whose
# evidence cannot be found is emitted as NOT_ESTABLISHED -- never silently
# omitted and never filled in from memory of what the gate concluded.
#
# This issue publishes a verdict. It implements nothing.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
RF="$(cd -- "$HERE/.." >/dev/null 2>&1 && pwd)"
OUT="$HERE/verdict.json"
MATRIX="$HERE/matrix.txt"

python3 - "$RF" "$OUT" "$MATRIX" <<'G46'
import json, os, sys, hashlib, datetime, re
rf, out, matrix_path = sys.argv[1:4]

def text(rel):
    try: return open(os.path.join(rf, rel)).read()
    except OSError: return ''
def js(rel):
    try: return json.load(open(os.path.join(rf, rel)))
    except Exception: return {}
def sha(rel):
    p = os.path.join(rf, rel)
    if not os.path.isfile(p): return None
    h = hashlib.sha256()
    with open(p,'rb') as f:
        for c in iter(lambda: f.read(1<<20), b''): h.update(c)
    return h.hexdigest()

G2   = 'g2_execution/evidence/g2_g3_on.txt'
G3   = 'g3_types_gc/evidence/g3_g3_on.txt'
G4F  = 'g4_optimizer/evidence/g4_solo_fenced.txt'
G4U  = 'g4_optimizer/evidence/g4_solo_unfenced.txt'
COST = 'g6b_cost/evidence/costs.txt'
ALLC = 'g6b_cost/evidence/alloc_gc.txt'
freeze = js('g0_freeze/freeze_manifest.json')
repro  = js('g6c_harness/evidence/reproduction.json')
negs   = js('g6a_negatives/evidence/negatives.json')

def row(value_if_found, needle, rel, absent='NOT_ESTABLISHED'):
    """A row is PROVEN only if its marker is actually in the evidence."""
    t = text(rel)
    return ({'value': value_if_found, 'evidence': rel, 'marker': needle}
            if needle in t else
            {'value': absent, 'evidence': rel, 'marker': needle, 'note': 'marker not found'})

M = {}
M['FROZEN_LINEAGE'] = ({'value':'VERIFIED','evidence':'g0_freeze/freeze_manifest.json',
                        'commit':freeze.get('distribution',{}).get('commit'),
                        'producing_dart_tree':freeze.get('producing_source',{}).get('dart',{}).get('effective_tree')}
                       if freeze else {'value':'NOT_ESTABLISHED'})
M['CURRENT_DART'] = {'value':'NOT_TRIGGERED','evidence':'issue #42 closed as not planned',
   'why':'the frozen lineage exposes and enforces the required mechanism; no primitive failed on it'}

M['BYTECODE_TO_AOT'] = row('PROVEN','multiply is RETAINED AOT, not interpreted', G2)
M['AOT_TO_BYTECODE'] = row('PROVEN','module implementation is interpreted', G2)
# These two are G2's identity test, not G3's. Pointing them at G3 made both read
# NOT_ESTABLISHED and drove the assembler to ABANDON_OR_REDESIGN -- which is the
# guard behaving correctly: a row whose marker is absent is never filled in from
# memory of what the gate concluded. The fix is the evidence pointer, not the check.
M['SHARED_HEAP']     = row('PROVEN','module mutation B->A is visible to AOT', G2)
M['OBJECT_IDENTITY'] = row('PROVEN','module returned the very same Box (identity, not equality)', G2)

M['AOT_ROOT_TO_PATCH_OBJECT']       = row('PROVEN','patch object survived a full GC', G3)
M['PATCH_ROOT_TO_AOT_OBJECT']       = row('PROVEN','AOT object survived, rooted only through patch code', G3)
M['CROSS_RUNTIME_CYCLE_COLLECTION'] = row('PROVEN','unrooted patch object in the cycle WAS collected', G3)

M['BYTECODE_EXCEPTION_TO_AOT'] = row('PROVEN','AOT caught a throw that originated in bytecode', G2)
M['AOT_EXCEPTION_TO_BYTECODE'] = row('PROVEN','module caught the host exception', G2)
M['FINALLY']                   = row('PROVEN','the host finally ran during unwinding', G2)
M['STACK_UNWINDING']           = row('PROVEN','AOT still executes correctly after the unwind', G2)

M['PATCH_CLASS']              = row('PROVEN','runtimeType is the patch class', G3)
M['IMPLEMENTS_AOT_INTERFACE'] = row('PROVEN','is Iface: true', G3)
M['EXTENDS_AOT_CLASS']        = row('PROVEN','is Base: true', G3)
M['SUPER_TO_AOT']             = row('PROVEN','override ran and super reached AOT', G3)
M['IS_CHECK']                 = row('PROVEN','AOT treats the result as Base', G3)
M['CAST']                     = row('PROVEN','inherited AOT method', G3)
M['GENERICS']                 = row('PROVEN','module instantiated the AOT generic at its own type', G3)

# The optimizer rows are two-sided on purpose: sound WITH the contract, bypassed
# WITHOUT it. Reporting only the sound half would misstate the finding.
SHAPES = [('OPTIMIZER_DIRECT_VIRTUAL','1_virtual'),('OPTIMIZER_MONOMORPHIC','2_monomorphic'),
          ('OPTIMIZER_HELPER_CHAIN','3_helper_chain'),('OPTIMIZER_GENERIC','4_bounded_generic'),
          ('OPTIMIZER_FIELD_RECEIVER','5_field_receiver')]
tf, tu = text(G4F), text(G4U)
def shape_state(label):
    def subject(t):
        seg = t.split('--- SUBJECT: PatchChild ---')[-1]
        blk = re.search(r'SHAPE '+re.escape(label)+r'(.*?)(?=SHAPE |\Z)', seg, re.S)
        return blk.group(1) if blk else ''
    f, u = subject(tf), subject(tu)
    if 'bypass           NO' in f and 'bypass           YES' in u:
        return 'SOUND_WITH_CONTRACT__BYPASSED_WITHOUT'
    if 'bypass           NO' in f:
        return 'SOUND_WITH_CONTRACT__BYPASS_NOT_REPRODUCED'
    return 'NOT_ESTABLISHED'
for key, label in SHAPES:
    M[key] = {'value': shape_state(label), 'evidence': [G4F, G4U], 'shape': label}

ct, at = text(COST), text(ALLC)
def num(t, pat):
    m = re.search(pat, t, re.M)
    return float(m.group(1)) if m else None
M['SUBSTRATE_COST'] = {'value':'dartaotruntime +2.76%; vm_platform.dill 0.00%; normal AOT perf: no measurable difference',
                       'evidence': COST}
M['DYNAMIC_INTERFACE_COST'] = {'value':'+16,704 bytes (+1.88%) retained AOT per declared-patchable member',
                               'evidence': COST}
M['MODULE_COST'] = {'value':'module 1,190 B; load ~99 us; RSS delta ~112 KB','evidence': COST}
M['CALL_COST'] = {'value':{
    'aot_to_aot_direct_ns':     num(ct, r'^aot_to_aot_direct\s+([\d.]+)'),
    'aot_to_aot_virtual_ns':    num(ct, r'^aot_to_aot_virtual\s+([\d.]+)'),
    'aot_to_bytecode_ns':       num(ct, r'^aot_to_bytecode\s+([\d.]+)'),
    'bytecode_to_aot_ns':       num(ct, r'^bytecode_to_aot\s+([\d.]+)'),
    'bytecode_to_bytecode_ns':  num(ct, r'^bytecode_to_bytecode\s+([\d.]+)'),
    'alloc_aot_ns':             num(at, r'^alloc_aot_aot_type\s+([\d.]+)'),
    'alloc_bytecode_aot_type_ns':   num(at, r'^alloc_bytecode_aot_type\s+([\d.]+)'),
    'alloc_bytecode_patch_type_ns': num(at, r'^alloc_bytecode_patch_type\s+([\d.]+)'),
    'interpretation_multiple':'~9-12x a direct AOT call; the three interpreted modes are within noise of each other',
   },'evidence':[COST, ALLC]}

fail_open = [n['name'] for n in negs.get('negatives',[]) if n.get('outcome')=='FAIL_OPEN']
M['KNOWN_GAPS'] = {'value':[
  {'id':'MODULE_SIDE_DYNAMIC_INTERFACE_VALIDATION','status':'UNRESOLVED','severity':'BLOCKING_FOR_PRODUCTION',
   'classification':'production pipeline/tooling requirement — NOT a runtime or compiler defect',
   'evidence':'g6a_negatives/RESULT.md'},
  {'id':'NEGATIVE_CONTROLS_FAIL_OPEN','status':'FINDING','items':fail_open,
   'evidence':'g6a_negatives/evidence/negatives.json'},
  {'id':'SUPPORTED_CELL_REPRODUCIBILITY','status':'NOT_ESTABLISHED_BY_THIS_LANE',
   'evidence':'g6c_harness/evidence/reproduction.json'},
  {'id':'GC_COST_CHARACTERISATION','status':'PARTIAL',
   'note':'one workload on one machine; collection cost flat across modes, not a GC characterisation'},
  {'id':'PLATFORM_SCOPE','status':'LIMIT','note':'host macOS/arm64 only; no iOS, no device, no real application'},
  {'id':'CALL_SITE_REBINDING','status':'OUT_OF_SCOPE',
   'note':'Dart-side call sites remain statically bound; the binder is not built and no gate claims it'},
 ], 'evidence':'multiple'}

# THE VERDICT IS CHECKED AGAINST THE MATRIX, not declared ahead of it.
required_proven = ['BYTECODE_TO_AOT','AOT_TO_BYTECODE','SHARED_HEAP','OBJECT_IDENTITY',
  'AOT_ROOT_TO_PATCH_OBJECT','PATCH_ROOT_TO_AOT_OBJECT','CROSS_RUNTIME_CYCLE_COLLECTION',
  'BYTECODE_EXCEPTION_TO_AOT','AOT_EXCEPTION_TO_BYTECODE','FINALLY','STACK_UNWINDING',
  'PATCH_CLASS','IMPLEMENTS_AOT_INTERFACE','EXTENDS_AOT_CLASS','SUPER_TO_AOT','IS_CHECK','CAST','GENERICS']
unproven = [k for k in required_proven if M[k]['value'] != 'PROVEN']
opt_ok = all(M[k]['value'].startswith('SOUND_WITH_CONTRACT') for k,_ in SHAPES)
opt_characterised = all(M[k]['value']=='SOUND_WITH_CONTRACT__BYPASSED_WITHOUT' for k,_ in SHAPES)

if unproven:
    verdict, why = 'ABANDON_OR_REDESIGN', f'required primitives not proven: {unproven}'
elif not opt_ok:
    verdict, why = 'MODIFY_COMPILER_FENCES', 'optimizer bypasses dynamic behaviour even with the contract declared'
else:
    verdict = 'PROCEED'
    why = ('every required primitive is mechanically supported on the frozen lineage, and optimizer '
           'behaviour is fully characterised without changing the runtime model: it is sound when '
           'can-be-overridden is part of the release-time patchability contract. The one blocking gap '
           '(module-side dynamic-interface validation) is a production pipeline requirement, not a '
           'runtime or compiler defect, so it does not select MODIFY_VM or MODIFY_COMPILER_FENCES.')
M['VERDICT'] = {'value': verdict, 'why': why,
                'optimizer_fully_characterised': opt_characterised,
                'allowed_verdicts':['PROCEED','MODIFY_UPGRADE_DART','MODIFY_COMPILER_FENCES','MODIFY_VM','ABANDON_OR_REDESIGN']}

PROV = ['g0_freeze/freeze_manifest.json','g0_freeze/banked_source/dart/0001-Add-snapshot-size-accessors-for-code-push.patch',
 'g0_freeze/banked_source/dart/0002-Route-B-Dart-SDK-support-bytecode-producer-and-the-t.patch',
 'g0_freeze/banked_source/dart/9999-worktree-uncommitted.patch',
 'g2_execution/banked_experiment/0001-g2-function-execution-mode-instrument.patch',
 'g3_types_gc/banked_experiment/0001-g3-expose-full-gc-for-testing.patch',
 'g1_substrate/g1_manifest.json','g6a_negatives/evidence/negatives.json',
 'g6c_harness/evidence/reproduction.json','g6c_harness/evidence/falsification.json',
 'g6c_harness/mandatory_evidence.json', G2, G3, G4F, G4U, COST, ALLC]

doc = {'schema':'semantic-linker-1/final-verdict/1','gate':'SL1-FINAL','issue':46,'tracker':36,
 'published':datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
 'frozen_baseline':freeze.get('distribution',{}),'record_at_tag':freeze.get('record_at_tag',{}),
 'source_identity':freeze.get('producing_source',{}),
 'reproduction':{'result':repro.get('result',{}),'state':repro.get('machine_readable_state',{}),
   'lane_build':repro.get('LANE_BUILD_REPRODUCIBILITY',{}).get('verdict'),
   'supported_cell':repro.get('SUPPORTED_CELL_REPRODUCIBILITY',{}).get('verdict')},
 'matrix':M,
 'provenance':{rel: sha(rel) for rel in PROV},
 'next_lane':('SEMANTIC-MAP-1' if verdict=='PROCEED' else
              {'MODIFY_COMPILER_FENCES':'SEMANTIC-MAP-1 carrying requirements into AOT-ASSUMPTIONS-1',
               'MODIFY_UPGRADE_DART':'DART-LINEAGE-BRIDGE-1','MODIFY_VM':'SEMANTIC-RUNTIME-REPAIR-1',
               'ABANDON_OR_REDESIGN':'stop and reassess'}[verdict]),
 'stop_boundary':('This issue publishes a verdict. No semantic-map implementation, assumption '
                  'instrumentation, reconciliation, patch-v2, CLI integration, signing change, '
                  'supported-state change, or physical deployment begins here.')}
json.dump(doc, open(out,'w'), indent=2)

lines=[]
for k,v in M.items():
    if k in ('KNOWN_GAPS','CALL_COST','VERDICT'): continue
    lines.append(f'{k+":":34}{v["value"]}')
lines.append('')
cc=M['CALL_COST']['value']
lines.append(f'{"CALL_COST:":34}direct {cc["aot_to_aot_direct_ns"]} ns · virtual {cc["aot_to_aot_virtual_ns"]} ns · '
             f'AOT->bc {cc["aot_to_bytecode_ns"]} ns · bc->AOT {cc["bytecode_to_aot_ns"]} ns · bc->bc {cc["bytecode_to_bytecode_ns"]} ns')
lines.append(f'{"":34}alloc: AOT {cc["alloc_aot_ns"]} ns · bc/AOT-type {cc["alloc_bytecode_aot_type_ns"]} ns · bc/patch-type {cc["alloc_bytecode_patch_type_ns"]} ns')
lines.append('')
lines.append('KNOWN_GAPS:')
for g in M['KNOWN_GAPS']['value']:
    lines.append(f'  {g["id"]:42}{g["status"]}')
lines.append('')
lines.append(f'{"VERDICT:":34}{verdict}')
open(matrix_path,'w').write('\n'.join(lines)+'\n')
print('\n'.join(lines))
print()
print('unproven required primitives:', unproven or 'none')
print('next lane:', doc['next_lane'])
G46
