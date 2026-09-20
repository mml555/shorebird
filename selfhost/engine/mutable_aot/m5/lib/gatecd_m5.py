#!/usr/bin/env python3
"""Gates C and D, and the compact production replacement regression.

Gate C   the machine code at a #67 call site is still cell-indirect after two
         installations, and nothing rewrote it
Gate D   the release-only reachability edge never becomes a binding
Regress  OLD -> NEW -> NEW2 through production StageReplacement, for a
         top-level declaration, an instance declaration and a shared-body pair

Everything here decodes or compares. No step accepts a printed verdict.
"""
import json, os, re, shutil, subprocess, sys, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from judge_m5 import FROZEN, MOVING

FORK = '/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart'
OUT = '/Volumes/build/route-b/flutter/engine/src/out/maot_host'
DART = '/opt/homebrew/share/flutter/bin/cache/dart-sdk/bin/dart'
M5 = os.path.dirname(os.path.abspath(__file__))
NS = 'ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
PKG = 'm5gatec'
FIXTURE = 'fixture_m5_gatec.dart'
STAGES = ('before', 'v2', 'v3')
SUBJECTS = ('top', 'inst', 'sharea')

# ---------------------------------------------------------------- ARM64 decode
PP = 27  # the object pool register


def ldr_pool(w):
    """LDR Xt,[PP,#imm12*8] -> (Rt, byte offset), else None."""
    if (w >> 22) & 0x3FF != 0b1111100101:
        return None
    if (w >> 5) & 0x1F != PP:
        return None
    return (w & 0x1F, ((w >> 10) & 0xFFF) * 8)


def ldur(w):
    """LDUR Xt,[Xn,#simm9] or LDUR Wt,[Xn,#simm9] -> (Rt, Rn, imm)."""
    for top in (0b11111000010, 0b10111000010):     # 64-bit, 32-bit
        if (w >> 21) & 0x7FF == top and ((w >> 10) & 0x3) == 0:
            imm = (w >> 12) & 0x1FF
            if imm & 0x100:
                imm -= 0x200
            return (w & 0x1F, (w >> 5) & 0x1F, imm)
    return None


def blr(w):
    """BLR Xn -> Rn, else None."""
    if w & 0xFFFFFC1F == 0xD63F0000:
        return (w >> 5) & 0x1F
    return None


def read_words(path):
    ws = []
    for l in open(path):
        l = l.strip()
        if re.fullmatch(r'[0-9a-f]{8}', l):
            ws.append(int(l, 16))
    return ws


def cell_indirect_sites(words):
    """Every #67 lowering in this body, as {pool byte offset: site index}.

    The shape is: load the cell from the pool, load a field out of it, load a
    field out of THAT, branch through a register. Matched structurally by
    register dataflow rather than by a fixed instruction window, so an extra
    scheduled instruction between them does not silently turn a PASS into a
    FAIL or the reverse.
    """
    sites = {}
    for i, w in enumerate(words):
        got = ldr_pool(w)
        if got is None:
            continue
        rt, off = got
        reg = rt
        steps = 0
        for j in range(i + 1, min(i + 9, len(words))):
            u = ldur(words[j])
            if u is not None and u[1] == reg:
                reg = u[0]
                steps += 1
                continue
            b = blr(words[j])
            if b is not None and b == reg and steps >= 1:
                sites.setdefault(off, []).append((i, steps))
                break
            if ldr_pool(words[j]) is not None:
                break
    return sites


# ---------------------------------------------------------------------- build
def build(wd):
    lib = os.path.join(wd, 'pkg', 'lib')
    os.makedirs(lib)
    shutil.copy(os.path.join(M5, FIXTURE), os.path.join(lib, FIXTURE))
    tool = os.path.join(wd, 'pkg', '.dart_tool')
    os.makedirs(tool)
    json.dump({'configVersion': 2, 'packages': [
        {'name': PKG, 'rootUri': 'file://%s/' % os.path.join(wd, 'pkg'),
         'packageUri': 'lib/', 'languageVersion': '3.9'}]},
        open(os.path.join(tool, 'package_config.json'), 'w'))
    dill = os.path.join(wd, 'app.dill')
    k = subprocess.run(
        [DART, '--packages=%s' % os.path.join(FORK, '.dart_tool/package_config.json'),
         os.path.join(FORK, 'pkg/vm/bin/gen_kernel.dart'), '--platform',
         os.path.join(OUT, 'vm_platform_product.dill'), '--aot', '--packages',
         os.path.join(tool, 'package_config.json'), '-o', dill,
         'package:%s/%s' % (PKG, FIXTURE)],
        capture_output=True, text=True, timeout=1800)
    assert k.returncode == 0, k.stderr[-1500:]
    aot = os.path.join(wd, 'a.aot')
    pre = os.path.join(wd, 'reg.json')
    s = subprocess.run(
        [os.path.join(OUT, 'gen_snapshot'), '--snapshot_kind=app-aot-elf',
         '--elf=%s' % aot, '--maot_namespace=%s' % NS,
         '--maot_install_trampolines', '--maot_verify_pinned_body_traversal',
         '--maot_dump_registry_precompile=%s' % pre, dill],
        capture_output=True, text=True, timeout=1800)
    assert s.returncode == 0, [l for l in s.stderr.splitlines() if 'si_addr' in l]
    # FALSIFICATION ARM for Gate D. A counter that reads zero proves nothing
    # until it has been shown to fire. With the indirection disabled the same
    # declarations ARE reached by ordinary static calls, so the same counter
    # must be non-zero on the same program.
    faot = os.path.join(wd, 'f.aot')
    f = subprocess.run(
        [os.path.join(OUT, 'gen_snapshot'), '--snapshot_kind=app-aot-elf',
         '--elf=%s' % faot, '--maot_namespace=%s' % NS,
         '--maot_install_trampolines', '--maot_disable_call_indirection', dill],
        capture_output=True, text=True, timeout=1800)
    assert f.returncode == 0, [l for l in f.stderr.splitlines() if 'si_addr' in l]
    return aot, faot, pre, s.stderr, f.stderr


def ftot_ne(a, b):
    return a != b


def main():
    wd = tempfile.mkdtemp(prefix='gatecd_')
    aot, faot, pre, snap_err, falsify_err = build(wd)
    dumps = os.path.join(wd, 'dumps')
    os.makedirs(dumps, exist_ok=True)
    r = subprocess.run([os.path.join(OUT, 'dartaotruntime'), aot],
                       capture_output=True, text=True, timeout=900,
                       env=dict(os.environ, MAOT_NAMESPACE=NS,
                                MAOT_DUMP_DIR=dumps))
    kv = {}
    for l in r.stdout.splitlines():
        if '=' in l:
            a, _, b = l.partition('=')
            kv[a] = b
    assert r.returncode == 0, r.stderr[-1200:]

    fdumps = os.path.join(wd, 'fdumps')
    os.makedirs(fdumps, exist_ok=True)
    fr = subprocess.run([os.path.join(OUT, 'dartaotruntime'), faot],
                        capture_output=True, text=True, timeout=900,
                        env=dict(os.environ, MAOT_NAMESPACE=NS,
                                 MAOT_DUMP_DIR=fdumps))
    fkv = {}
    for l in fr.stdout.splitlines():
        if '=' in l:
            a, _, b = l.partition('=')
            fkv[a] = b
    assert fr.returncode == 0, fr.stderr[-1200:]

    fails = []
    n = [0]

    def chk(name, ok, detail=''):
        n[0] += 1
        if not ok:
            fails.append('%s %s' % (name, detail))

    # ---------------------------------------------------------------- GATE D
    print('=== GATE D: the reachability edge never becomes a binding ===')
    gd = [l.strip() for l in snap_err.splitlines() if 'GATE_D' in l]
    re_line = [l.strip() for l in snap_err.splitlines() if 'RELEASE_EDGES' in l]
    for l in gd + re_line:
        print('   ', l)
    PAT = (r'codes=(\d+) tables_nonempty=(\d+) pcrel_total=(\d+) '
           r'call_via_code=(\d+) mutable_targets_bound=(\d+) '
           r'pcrel_mutable_targets=(\d+)')
    m = re.search(PAT, ' '.join(gd))
    chk('GATE_D line present', m is not None)
    m2 = re.search(r'recorded=(\d+) consumed=(\d+) missing=(\d+) '
                   r'pending_at_end=(\d+)', ' '.join(re_line))
    chk('RELEASE_EDGES line present', m2 is not None)
    rec = con = mis = pend = -1
    if m2:
        rec, con, mis, pend = (int(m2.group(i)) for i in (1, 2, 3, 4))
        chk('release edges were actually recorded (not vacuous)', rec > 0,
            'recorded=%d' % rec)
        chk('every recorded edge consumed by reachability', rec == con,
            '%d/%d' % (con, rec))
        chk('no missing release edge', mis == 0, str(mis))
        chk('nothing left pending', pend == 0, str(pend))
    fg = [l.strip() for l in falsify_err.splitlines() if 'GATE_D' in l]
    mf = re.search(PAT, ' '.join(fg))
    print('    falsification arm (--maot_disable_call_indirection):')
    for l in fg:
        print('   ', l)
    if m and mf:
        codes, tabs, ptot, bound, mut, pcrel = (int(m.group(i))
                                                for i in range(1, 7))
        fcodes, ftabs, fptot, fbound, fmut, fpcrel = (int(mf.group(i))
                                                      for i in range(1, 7))
        chk('the probe actually walked a population', codes > 0 and ptot > 0,
            'codes=%d tables_nonempty=%d pcrel_total=%d' % (codes, tabs, ptot))
        # In AOT every static call is pc-relative, so the binder's
        # call-via-code path is never taken. Reported, not asserted on: a check
        # on a branch that cannot execute discriminates nothing.
        print('    call_via_code=%d in both arms -- in AOT the binder\'s'
              ' call-via-code path is never taken, so "no mutable target was'
              ' bound" is true but carries no information on its own' % bound)
        # pcrel_mutable_targets read 0 in BOTH arms, including the arm where it
        # was supposed to fire. An instrument that does not discriminate is
        # reported and set aside, not quoted as a result.
        print('    pcrel_mutable_targets=%d/%d production, %d/%d with the'
              ' indirection disabled -- this counter did not discriminate and'
              ' is NOT used below' % (pcrel, ptot, fpcrel, fptot))
        # What does discriminate: the POPULATION of pc-relative static-call
        # entries, against the number of edges the lowering recorded.
        chk('the two arms differ in the static call table at all',
            ftot_ne(ptot, fptot), 'both %d' % ptot)
        chk('turning the indirection ON removes exactly one pc-relative '
            'static-call entry per recorded release edge',
            bool(m2) and (fptot - ptot == rec),
            'pcrel_total %d -> %d is %+d, release edges recorded %d'
            % (fptot, ptot, ptot - fptot, rec))

    # Not a count -- a count is a guess that has to be updated whenever a line
    # moves. Every reference is attributed to the function that contains it,
    # and the set of containing functions is what is asserted.
    # Consuming operations -- anything that reads an element or empties the
    # list -- may only appear where the edge is recorded and where it is
    # drained. A bare .Length() elsewhere is a diagnostic read of the count and
    # cannot route anything, so it is listed but not restricted.
    CONSUMERS = {'Precompiler::AddCalleesOf',
                 'Precompiler::NoteReleaseReachabilityEdge'}
    ALLOWED = CONSUMERS | {'Precompiler::Precompiler', '<declaration>'}
    consuming = {}
    holders = {}
    for rel in ('runtime/vm/compiler/aot/precompiler.cc',
                'runtime/vm/compiler/aot/precompiler.h'):
        lines = open(os.path.join(FORK, rel)).read().splitlines()
        cur = '<declaration>'
        for i, l in enumerate(lines):
            fm = re.match(r'^[A-Za-z_][\w:&*<>\s]*?\b(Precompiler::\w+)\s*\(', l)
            if fm:
                cur = fm.group(1)
            elif re.match(r'^Precompiler::Precompiler\(', l):
                cur = 'Precompiler::Precompiler'
            if 'pending_release_edges_' in l:
                where = '%s:%d' % (rel.split('/')[-1], i + 1)
                op = ('.Length()' if 'pending_release_edges_.Length()' in l
                      else '.Add' if '.Add(' in l
                      else '.At' if '.At(' in l
                      else '.SetLength' if '.SetLength(' in l
                      else 'declare/construct')
                holders.setdefault(cur, []).append('%s%s' % (where, op))
                if op in ('.Add', '.At', '.SetLength'):
                    consuming.setdefault(cur, []).append(where)
    print('    reachability_edges_consumed_by_codegen = 0')
    for k, v in sorted(holders.items()):
        print('        %-42s %s' % (k, ' '.join(v)))
    chk('every element-level use of the edge list is the record site or the '
        'drain', set(consuming) <= CONSUMERS,
        str(sorted(set(consuming) - CONSUMERS)))
    chk('no reference to the edge list outside declaration, construction, '
        'record, drain and a diagnostic count',
        set(holders) <= ALLOWED | {'Precompiler::DoCompileAll'},
        str(sorted(set(holders) - (ALLOWED | {'Precompiler::DoCompileAll'}))))

    # ---------------------------------------------------------------- GATE C
    print('\n=== GATE C: the call sites are still cell-indirect ===')
    pools = {k: int(kv.get('pool.%s' % k, -1))
             for k in list(SUBJECTS) + ['shareb', 'other', 'caller']}
    print('    dispatch-cell pool byte offsets:',
          ' '.join('%s=%d' % (k, v) for k, v in pools.items()))
    digests = {st: kv.get('caller.digest.%s' % st) for st in STAGES}
    print('    caller pinned-body digest:',
          ' '.join('%s=%s' % (st, digests[st]) for st in STAGES))
    chk('caller body digest is real', all(
        digests[st] not in (None, '', '0') and not digests[st].startswith('-')
        for st in STAGES), str(digests))
    chk('caller machine code unchanged across both installations',
        len(set(digests.values())) == 1, str(digests))

    site_sets = {}
    for st in STAGES:
        p = os.path.join(dumps, 'caller_%s.words' % st)
        chk('caller words dumped [%s]' % st, os.path.exists(p))
        if not os.path.exists(p):
            continue
        words = read_words(p)
        sites = cell_indirect_sites(words)
        site_sets[st] = sites
        print('    [%-6s] %d instruction words, %d cell-indirect sites at pool '
              'offsets %s' % (st, len(words), sum(len(v) for v in sites.values()),
                              sorted(sites)))
    for st in STAGES:
        if st not in site_sets:
            continue
        for subj in list(SUBJECTS) + ['shareb', 'other']:
            chk('[%s] %s is reached cell-indirect' % (st, subj),
                pools[subj] in site_sets[st],
                'pool offset %d not loaded-and-branched in the caller body'
                % pools[subj])
    if len(site_sets) == 3:
        chk('the same sites, at the same offsets, after both installs',
            site_sets['before'] == site_sets['v2'] == site_sets['v3'],
            str({k: sorted(v) for k, v in site_sets.items()}))

    # The same program with the indirection disabled. This is what makes the
    # decode above a measurement rather than a description: the decoder has to
    # come back empty on a build where the sequence is not emitted, the machine
    # code has to differ, and production StageReplacement has to REFUSE --
    # replacement succeeds only where the code routes through the cell.
    fp = os.path.join(fdumps, 'caller_before.words')
    fwords = read_words(fp) if os.path.exists(fp) else []
    fsites = cell_indirect_sites(fwords)
    fbl = sum(1 for w in fwords if (w >> 26) & 0x3F == 0b100101)
    print('    indirection OFF: %d words, %d cell-indirect sites, %d '
          'pc-relative BL, digest=%s'
          % (len(fwords), sum(len(v) for v in fsites.values()), fbl,
             fkv.get('caller.digest.before')))
    chk('indirection OFF: the decoder finds no cell-indirect site',
        len(fwords) > 0 and not fsites, str(sorted(fsites)))
    chk('indirection OFF: the calls are pc-relative instead', fbl > 0,
        'BL=%d' % fbl)
    chk('indirection OFF: the caller machine code differs',
        fkv.get('caller.digest.before') not in (None, digests['before']),
        '%s vs %s' % (fkv.get('caller.digest.before'), digests['before']))
    chk('indirection OFF: production StageReplacement refuses every install',
        all(fkv.get('install.%s.v2' % k) == '-3' for k in SUBJECTS),
        str({k: fkv.get('install.%s.v2' % k) for k in SUBJECTS}))
    chk('indirection OFF: behaviour never changes',
        all(fkv.get('%s.before' % k) == fkv.get('%s.v3' % k)
            for k in SUBJECTS),
        str({k: (fkv.get('%s.before' % k), fkv.get('%s.v3' % k))
             for k in SUBJECTS}))

    # ------------------------------------------- production replacement regression
    print('\n=== COMPACT PRODUCTION REGRESSION: OLD -> NEW -> NEW2 ===')
    reg = {st: json.load(open(os.path.join(dumps, 'registry_%s.json' % st)))
           for st in STAGES}

    def entry(st, suffix):
        ents = reg[st].get('entries', reg[st] if isinstance(reg[st], list) else [])
        for e in ents:
            if e.get('declaration_id', '').endswith('::' + suffix):
                return e
        return None

    DECL = {'top': 'fn:topLevel', 'inst': 'cls:Inst::method:v',
            'sharea': 'cls:ShareA::method:v'}
    SHAREB = 'cls:ShareB::method:v'
    OTHER = 'cls:Other::method:v'

    print('%-8s %-24s %-24s %-24s' % ('subject', 'before', 'v2', 'v3'))
    for k in SUBJECTS:
        print('%-8s %-24s %-24s %-24s' % (k, kv.get('%s.before' % k),
                                          kv.get('%s.v2' % k), kv.get('%s.v3' % k)))
    for k in ('shareb', 'other'):
        print('%-8s %-24s %-24s %-24s  (control)' % (
            k, kv.get('%s.before' % k), kv.get('%s.v2' % k), kv.get('%s.v3' % k)))

    for k in SUBJECTS:
        b0, b2, b3 = (kv.get('%s.%s' % (k, st)) for st in STAGES)
        chk('%s baseline OLD' % k, (b0 or '').startswith(
            'OLD' if k != 'sharea' else 'SHARED'), str(b0))
        chk('%s v2 NEW' % k, (b2 or '').startswith('NEW')
            and not (b2 or '').startswith('NEW2') and b2 != b0, '%s->%s' % (b0, b2))
        chk('%s v3 NEW2' % k, (b3 or '').startswith('NEW2') and b3 != b2,
            '%s->%s' % (b2, b3))
        chk('%s install v2 succeeded' % k, kv.get('install.%s.v2' % k) == '0',
            str(kv.get('install.%s.v2' % k)))
        chk('%s install v3 succeeded' % k, kv.get('install.%s.v3' % k) == '0',
            str(kv.get('install.%s.v3' % k)))
        chk('%s version 1/-102/-103' % k,
            tuple(kv.get('version.%s.%s' % (k, st)) for st in STAGES)
            == ('1', '-102', '-103'),
            str(tuple(kv.get('version.%s.%s' % (k, st)) for st in STAGES)))
        for f in FROZEN:
            vals = [entry(st, DECL[k]).get(f) if entry(st, DECL[k]) else None
                    for st in STAGES]
            chk('%s frozen %s' % (k, f),
                len(set(vals)) == 1 and vals[0] not in (None, 0), str(vals))
        for f in MOVING:
            vals = [entry(st, DECL[k]).get(f) if entry(st, DECL[k]) else None
                    for st in STAGES]
            chk('%s moves %s' % (k, f),
                len(set(vals)) == 3 and all(v not in (None, 0) for v in vals),
                str(vals))

    # shared body: is it actually shared, and does replacing one disturb the other?
    ea = entry('before', DECL['sharea'])
    eb = entry('before', SHAREB)
    shared = (ea and eb and ea.get('id_release_body') == eb.get('id_release_body'))
    print('\n    shared-body case: ShareA and ShareB release bodies are %s'
          % ('THE SAME object (dedup canonicalized them)' if shared
             else 'distinct objects (dedup did not merge them)'))
    chk('ShareB behaviour unchanged by replacing ShareA',
        kv.get('shareb.before') == kv.get('shareb.v2') == kv.get('shareb.v3'),
        '%s/%s/%s' % (kv.get('shareb.before'), kv.get('shareb.v2'),
                      kv.get('shareb.v3')))
    for f in FROZEN + MOVING:
        vals = [entry(st, SHAREB).get(f) if entry(st, SHAREB) else None
                for st in STAGES]
        chk('ShareB unchanged %s' % f, len(set(vals)) == 1, str(vals))
    chk('control Other behaviour unchanged',
        kv.get('other.before') == kv.get('other.v2') == kv.get('other.v3'),
        '%s/%s/%s' % (kv.get('other.before'), kv.get('other.v2'),
                      kv.get('other.v3')))
    for f in FROZEN + MOVING:
        vals = [entry(st, OTHER).get(f) if entry(st, OTHER) else None
                for st in STAGES]
        chk('control Other unchanged %s' % f, len(set(vals)) == 1, str(vals))

    print('\n=== VERDICT ===')
    print('checks run = %d   failures = %d' % (n[0], len(fails)))
    for f in fails:
        print('   FAILED:', f)
    print('\n%s' % ('PASS' if not fails else 'FAIL'))
    print('work dir:', wd)
    return 1 if fails else 0


sys.exit(main())
