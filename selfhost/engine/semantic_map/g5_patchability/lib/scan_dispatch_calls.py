#!/usr/bin/env python3
"""Classify every Dart-to-Dart call site in a release AOT by REDIRECTABILITY.

SM1-G5 asks whether the exact release can mechanically determine that a
NON-INLINED declaration nevertheless has stale AOT call sites. It can, at the
level of call-site shape, because the two shapes are distinguishable in the
shipped text and only one of them is redirected when a replacement body is
attached to a function:

  POOL_INDIRECT   ldr  x0,  [x27, #imm]     ; x27 = PP, the object pool
                  ldur x30, [x0, #off]      ; entry point out of that Code
                  blr  x30
      The callee's Code object is reached through the object pool, which is
      what --patchable_static_calls arranges. Attaching a body redirects it.

  DISPATCH_TABLE  ldur xN, [recv, #-1]      ; header word
                  ubfx xN, xN, #12, #20     ; class id
                  add/mov xLR, xN, #sel     ; selector offset (mov when 0)
                  ldr  x30, [x21, xLR, lsl #3]   ; x21 = DISPATCH_TABLE_REG
                  blr  x30
      The entry point is read out of the dispatch table, indexed by the
      RECEIVER'S CLASS ID. It never consults the callee's pool entry, so
      attaching a body to the target function does not redirect it.

Register roles are not inferred from the disassembly: constants_arm64.h:144-145
defines PP = R27 and DISPATCH_TABLE_REG = R21, and
FlowGraphCompiler::EmitDispatchTableCall (flow_graph_compiler_arm64.cc) emits
exactly the AddImmediate(LR, cid_reg, offset) + Call([R21, LR, UXTX, Scaled])
pair this matches.

usage: scan_dispatch_calls.py <aot> [--objdump PATH] [--symbol NAME ...]
"""
import re
import subprocess
import sys
from collections import defaultdict

OBJDUMP = '/opt/homebrew/opt/llvm/bin/llvm-objdump'

SYM = re.compile(r'^([0-9a-f]+) <(.+)>:$')
INSN = re.compile(r'^\s*([0-9a-f]+):\s+(.*)$')
# ldr x30, [x21, xN, lsl #3] -- the dispatch-table load.
DISPATCH = re.compile(r'^ldr\s+(x\d+|lr),\s*\[x21,\s*(x\d+|lr)(,\s*lsl\s*#3)?\]')
# ldr xR, [x27, #imm] -- an object-pool load.
POOL = re.compile(r'^ldr\s+(x\d+),\s*\[x27(?:,\s*#(0x[0-9a-f]+|\d+))?\]')
# ldur xR, [xS, #off] -- entry point out of a Code object.
ENTRY = re.compile(r'^ldur\s+(x\d+|lr),\s*\[(x\d+),\s*#(0x[0-9a-f]+|\d+)\]')
BLR = re.compile(r'^blr\s+(x\d+|lr)$')
# add/mov that forms the selector index.
ADDSEL = re.compile(r'^add\s+(x\d+|lr),\s*(x\d+),\s*#(0x[0-9a-f]+|\d+)')
MOVSEL = re.compile(r'^mov\s+(x\d+|lr),\s*(x\d+)$')


def norm(r):
    return 'x30' if r == 'lr' else r


def main():
    args = sys.argv[1:]
    aot = args[0]
    objdump = OBJDUMP
    wanted = []
    i = 1
    while i < len(args):
        if args[i] == '--objdump':
            objdump = args[i + 1]; i += 2
        elif args[i] == '--symbol':
            wanted.append(args[i + 1]); i += 2
        else:
            i += 1

    out = subprocess.run(
        [objdump, '-d', '--no-show-raw-insn', aot],
        capture_output=True, text=True)
    if out.returncode != 0:
        print(f'objdump failed: {out.stderr.strip()[:200]}', file=sys.stderr)
        return 2

    sym = None
    window = []                        # recent (addr, text) for backtracking
    per_sym = defaultdict(lambda: {'DISPATCH_TABLE': [], 'POOL_INDIRECT': []})
    totals = defaultdict(int)

    for line in out.stdout.splitlines():
        m = SYM.match(line.strip())
        if m:
            sym = m.group(2)
            window = []
            continue
        m = INSN.match(line)
        if not m or sym is None:
            continue
        addr, text = m.group(1), m.group(2).strip()
        window.append((addr, text))
        if len(window) > 8:
            window.pop(0)

        b = BLR.match(text)
        if not b:
            continue
        called = norm(b.group(1))

        # Walk back for whichever load produced the called register.
        kind = sel = None
        for _, prev in reversed(window[:-1]):
            d = DISPATCH.match(prev)
            if d and norm(d.group(1)) == called:
                kind = 'DISPATCH_TABLE'
                idx = norm(d.group(2))
                # Recover the selector offset: an add gives it explicitly, a
                # mov means offset 0 (AddImmediate degenerates to a move).
                for _, p2 in reversed(window[:-1]):
                    a = ADDSEL.match(p2)
                    if a and norm(a.group(1)) == idx:
                        sel = int(a.group(3), 0); break
                    v = MOVSEL.match(p2)
                    if v and norm(v.group(1)) == idx:
                        sel = 0; break
                break
            e = ENTRY.match(prev)
            if e and norm(e.group(1)) == called:
                base = e.group(2)
                for _, p2 in reversed(window[:-1]):
                    q = POOL.match(p2)
                    if q and q.group(1) == base:
                        kind = 'POOL_INDIRECT'
                        sel = int(q.group(2), 0) if q.group(2) else 0
                        break
                break
        if kind:
            per_sym[sym][kind].append((addr, sel))
            totals[kind] += 1

    print(f'release: {aot}')
    print(f'  POOL_INDIRECT  call sites: {totals["POOL_INDIRECT"]}'
          '   (redirected when a body is attached)')
    print(f'  DISPATCH_TABLE call sites: {totals["DISPATCH_TABLE"]}'
          '   (NOT redirected: indexed by receiver class id)')
    syms_with_dispatch = [s for s, v in per_sym.items() if v['DISPATCH_TABLE']]
    print(f'  functions containing at least one dispatch-table call: '
          f'{len(syms_with_dispatch)}')

    if wanted:
        print()
        print('  per requested symbol:')
        for name in wanted:
            v = per_sym.get(name)
            if v is None:
                print(f'    {name:16} <no such symbol, or no classified call>')
                continue
            for kind in ('DISPATCH_TABLE', 'POOL_INDIRECT'):
                for addr, sel in v[kind]:
                    extra = (f'selector_offset={sel}' if kind == 'DISPATCH_TABLE'
                             else f'pool_offset={hex(sel)}')
                    print(f'    {name:16} {addr}  {kind:15} {extra}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
