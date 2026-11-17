#!/usr/bin/env python3
# cspell:words xids cands cfun clib csuper
"""check_kept.py <route_b_snapshot_profile.json> <probes.tsv> <host results.tsv dir's results.tsv (result/results.tsv)> <out kept_check.tsv>

Reads a v8 snapshot profile the way the CLI's `RouteBSnapshotKept` does (a `Class` node's `functions_`
array, each `Function`'s `Code`, the `super_type_` chain; a `[Stub]` code is a lazy-compile stub) and
reports, for every typed or tear-off probe, whether the member has real code on the VM class the probe's
receiver has at run time: REAL, STUB, MISSING, or UNMAPPED (no VM class known for that runtime class).
`kept_in_profile` per key (written to the output's `.keys.tsv`) is REAL when every mapped probe is REAL.
"""
import collections, csv, json, re, sys
prof, probes_tsv, results_tsv, out = sys.argv[1:5]
gate = sys.argv[sys.argv.index('--gate') + 1] if '--gate' in sys.argv else None  # a members.tsv: its THROWS keys must be kept
d = json.load(open(prof))
meta = d['snapshot']['meta']; nodes = d['nodes']; edges = d['edges']; strings = d['strings']
nf = meta['node_fields']; ef = meta['edge_fields']
nt = meta['node_types'][0]; et = meta['edge_types'][0]
fT, fN, fC = nf.index('type'), nf.index('name'), nf.index('edge_count')
eT, eN, eTo = ef.index('type'), ef.index('name_or_index'), ef.index('to_node')
NF, EF = len(nf), len(ef)
cnt = len(nodes) // NF
first = [0] * (cnt + 1)
for i in range(cnt):
    first[i + 1] = first[i] + nodes[i * NF + fC]
tp = lambda i: nodes[i * NF + fT]
nm = lambda i: strings[nodes[i * NF + fN]]
tg = lambda e: edges[e * EF + eTo] // NF
prop = et.index('property')
def pr(e): return strings[edges[e * EF + eN]] if edges[e * EF + eT] == prop else None
CLASS, FUNC, ARR, CODE, TYPE, LIB = (nt.index(x) for x in ('Class', 'Function', 'Array', 'Code', 'Type', 'Library'))
real = {}
def has_real(f):
    if f not in real:
        real[f] = any(tp(tg(e)) == CODE and not nm(tg(e)).startswith('[Stub]') for e in range(first[f], first[f + 1]))
    return real[f]
def cls_of_type(t):
    if tp(t) != TYPE: return None
    for e in range(first[t], first[t + 1]):
        if tp(tg(e)) == CLASS: return tg(e)
cname, clib, cfun, csuper = {}, {}, {}, {}
for c in range(cnt):
    if tp(c) != CLASS: continue
    cname[c] = re.sub(r'@\d+$', '', nm(c)); clib[c] = ''; own = cfun[c] = {}
    for e in range(first[c], first[c + 1]):
        p, t = pr(e), tg(e)
        if p == 'library_' and tp(t) == LIB: clib[c] = nm(t)
        elif p == 'functions_' and tp(t) == ARR:
            for f in range(first[t], first[t + 1]):
                fn = tg(f)
                if tp(fn) == FUNC: own[nm(fn)] = own.get(nm(fn), True) and has_real(fn)
        elif p == 'super_type_':
            s = cls_of_type(t)
            if s is not None and s != c: csuper[c] = s
byname = collections.defaultdict(list)
for c, n in cname.items(): byname[n].append(c)
def resolve(c, member):
    seen = set(); cur = c
    while cur is not None and cur not in seen and len(seen) < 64:
        seen.add(cur)
        if member in cfun.get(cur, {}): return 'REAL' if cfun[cur][member] else 'STUB'
        cur = csuper.get(cur)
    return 'MISSING'
# runtime class label -> candidate VM class names (first one present in the profile with a dart: library wins)
VM = {
 ('list', 'growable'): ['_GrowableList'], ('list', 'filled_fixed'): ['_List'], ('list', 'const'): ['_ImmutableList'],
 ('list', 'unmodifiable'): ['_ImmutableList'], ('list', 'generate'): ['_GrowableList'], ('list', 'json'): ['_GrowableList'],
 ('iter', 'list'): ['_GrowableList'], ('iter', 'set'): ['_Set', '_CompactLinkedHashSet'], ('iter', 'generate'): ['_GeneratorIterable'],
 ('map', 'literal'): ['_Map', '_InternalLinkedHashMap'], ('map', 'json'): ['_Map', '_InternalLinkedHashMap'],
 ('map', 'const'): ['_ConstMap'], ('map', 'unmodifiable'): ['_UnmodifiableMap'],
 ('set', 'literal'): ['_Set', '_CompactLinkedHashSet'], ('set', 'const'): ['_ConstSet'],
 ('str', 'one_byte'): ['_OneByteString'], ('str', 'two_byte'): ['_TwoByteString'],
 ('int', 'smi'): ['_Smi'], ('int', 'mint'): ['_Mint'], ('dbl', 'double'): ['_Double'],
 ('num', 'smi'): ['_Smi'], ('num', 'mint'): ['_Mint'], ('num', 'double'): ['_Double'],
 ('dur', 'duration'): ['Duration'], ('bool', 'bool'): ['bool'],
 ('future', 'async_fn'): ['_Future'], ('future', 'value'): ['_Future'], ('future', 'completer'): ['_Future'], ('future', 'delayed'): ['_Future'],
 ('stream', 'from_iterable'): ['_GeneratedStreamImpl'], ('stream', 'value'): ['_GeneratedStreamImpl'],
 ('stream', 'as_broadcast'): ['_AsBroadcastStream'], ('timer', 'periodic_or_oneshot'): ['_Timer'],
 ('date', 'utc'): ['DateTime'], ('size', 'size'): ['Size'], ('offset', 'offset'): ['Offset'],
}
def member_name(sel):
    s = re.sub(r'^tearoff:', '', sel)
    return s
host = {r['probe']: r for r in csv.DictReader(open(results_tsv), delimiter='\t')}
rows = []
for l in open(probes_tsv):
    pid, typ, label, form, sel = l.rstrip('\n').split('\t')
    if 'dynamic' in form: continue
    fam = pid.split('__')[0].split('_')[0]
    m = member_name(sel)
    cands = VM.get((fam, label)) or VM.get((fam.replace('dbl', 'dbl'), label))
    if not cands:
        rows.append((pid, host[pid]['key'], label, form, m, '', 'UNMAPPED')); continue
    st = 'UNMAPPED'
    for cn in cands:
        ids = [c for c in byname.get(cn, []) if clib[c].startswith('dart:')]
        if ids:
            sts = {resolve(c, m) for c in ids}
            st = 'REAL' if sts == {'REAL'} else 'STUB' if 'STUB' in sts else 'MISSING'
            rows.append((pid, host[pid]['key'], label, form, m, cn, st)); break
    else:
        rows.append((pid, host[pid]['key'], label, form, m, cands[0], 'UNMAPPED'))
with open(out, 'w') as f:
    f.write('probe\tkey\truntime_class\tform\tmember\tvm_class\tin_profile\n')
    for r in rows: f.write('\t'.join(r) + '\n')
by = collections.defaultdict(list)
for r in rows: by[r[1]].append(r[6])
with open(out.replace('.tsv', '.keys.tsv'), 'w') as f:
    f.write('key\tkept_in_profile\treal\tstub\tmissing\tunmapped\n')
    for k, v in sorted(by.items()):
        c = collections.Counter(v)
        mapped = c['REAL'] + c['STUB'] + c['MISSING']
        s = 'REAL' if mapped and c['REAL'] == mapped else 'STUB' if c['STUB'] else 'MISSING' if c['MISSING'] else 'UNMAPPED'
        f.write(f"{k}\t{s}\t{c['REAL']}\t{c['STUB']}\t{c['MISSING']}\t{c['UNMAPPED']}\n")
print(collections.Counter(r[6] for r in rows))
if gate:
    target = {r['key'] for r in csv.DictReader(open(gate), delimiter='\t') if r['device_verdict'] == 'THROWS'}
    bad = [r for r in rows if r[1] in target and r[6] in ('MISSING', 'STUB')]
    ks = sorted({r[1] for r in bad})
    print(f'gate: {len(target)} THROWS keys; {len(ks)} keys still missing or stubbed on a mapped class')
    for k in ks:
        print('  ', k, ', '.join(sorted({f"{r[2]}:{r[3]}={r[6]}" for r in bad if r[1] == k})))
    sys.exit(3 if ks else 0)
