#!/usr/bin/env python3
"""Attribute the Gate A differences to a CAUSE, not to "Mutable-AOT".

Arms B and A differ in two independent ways at once -- a different kernel
(selection metadata) and a different call shape (#67 cell indirection, which
also refuses to inline the target). A two-arm diff cannot say which one moved
a declaration, so this adds the two ablations that separate them.

  A  k0, stock                      baseline
  C  k1, --maot_disable_call_indirection      kernel effect alone
  D  k1, indirection ON, --maot_allow_inlining_mutable   call shape without
                                                         the inlining refusal
  B  k1, indirection ON             production shape (already measured)

Diagnosis only.
"""
import collections, os, subprocess, sys

OUT = '/Volumes/build/route-b/flutter/engine/src/out/maot_host'
NS = 'ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e'
WD = ('/private/tmp/claude-501/-Users-mendell-shorebird/'
      '541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/sizemat')
ED = os.path.join(WD, 'edgediff')
RELEASE = ('a reachable caller holds a mutable indirect call whose release '
           'target ordinary AOT reachability would have discovered')

# The two mechanisms Mutable-AOT applies to a selected declaration are
# independent, so they get a 2x2, not a ladder. Arm E is the control that says
# whether the selection metadata does anything AT ALL on its own -- without it
# every difference below could still be the kernel rather than a mechanism.
#
#            inlining allowed      inlining refused (default)
#  ind OFF   E  (neither)          C  (inlining only)
#  ind ON    D  (indirection only) B  (production, both)
ARMS = {
    'C': (os.path.join(WD, 'k1.dill'), ['--maot_disable_call_indirection']),
    'D': (os.path.join(WD, 'k1.dill'), ['--maot_allow_inlining_mutable']),
    'E': (os.path.join(WD, 'k1.dill'), ['--maot_disable_call_indirection',
                                        '--maot_allow_inlining_mutable']),
}


def run(tag):
    dill, extra = ARMS[tag]
    aot = os.path.join(ED, '%s.aot' % tag)
    ret = os.path.join(ED, '%s.retained' % tag)
    edg = os.path.join(ED, '%s.edges' % tag)
    if not (os.environ.get('EDGEDIFF_REUSE') and os.path.exists(ret)):
        for p in (ret, edg):
            if os.path.exists(p):
                os.remove(p)
        r = subprocess.run(
            [os.path.join(OUT, 'gen_snapshot'), '--snapshot_kind=app-aot-elf',
             '--elf=%s' % aot, '--maot_namespace=%s' % NS,
             '--maot_disable_retention_roots',
             '--maot_dump_retained=%s' % ret,
             '--maot_dump_reach_edges=%s' % edg] + extra + [dill],
            capture_output=True, text=True, timeout=10800)
        if r.returncode != 0:
            print('%s SNAPSHOT rc=%d' % (tag, r.returncode))
            print('\n'.join(r.stderr.splitlines()[-12:]))
            sys.exit(1)
        for l in r.stderr.splitlines():
            if 'RELEASE_EDGES' in l:
                print('  %s: %s' % (tag, l.strip()))
    return load(tag)


def load(tag):
    e = [tuple(l.rstrip('\n').split('\t'))
         for l in open(os.path.join(ED, '%s.edges' % tag), errors='replace')]
    e = {x for x in e if len(x) == 3}
    r = {l.rstrip('\n') for l in
         open(os.path.join(ED, '%s.retained' % tag), errors='replace')
         if l.strip()}
    return e, r


ea, ra = load('A')
eb, rb = load('B')
ec, rc = run('C')
ed, rd = run('D')
ee, re_ = run('E')

RELEASE_K = RELEASE
print('\n%-4s %-46s %-10s %-10s' % ('arm', 'configuration', 'retained', 'edges'))
for tag, desc, r, e in (('A', 'k0 baseline kernel, stock', ra, ea),
                        ('E', 'k1: neither mechanism (control)', re_, ee),
                        ('C', 'k1: inlining refusal only', rc, ec),
                        ('D', 'k1: call indirection only', rd, ed),
                        ('B', 'k1: both (production)', rb, eb)):
    print('%-4s %-46s %-10d %-10d' % (tag, desc, len(r), len(e)))

print('\n=== EACH ARM AGAINST THE BASELINE ===')
print('%-4s %-46s %-8s %-8s' % ('arm', 'configuration', 'LOST', 'EXTRA'))
for tag, desc, r in (('E', 'neither mechanism (control)', re_),
                     ('C', 'inlining refusal only', rc),
                     ('D', 'call indirection only', rd),
                     ('B', 'both (production)', rb)):
    print('%-4s %-46s %-8d %-8d' % (tag, desc, len(ra - r), len(r - ra)))

print('\n=== THE 3 LOST: WHICH MECHANISM DROPS EACH ===')
print('%-6s %-6s %-6s %-6s  %s' % ('E', 'C', 'D', 'B', 'declaration'))
for d in sorted(ra - rb):
    print('%-6s %-6s %-6s %-6s  %s' % (
        'kept' if d in re_ else 'LOST', 'kept' if d in rc else 'LOST',
        'kept' if d in rd else 'LOST', 'kept' if d in rb else 'LOST', d[:86]))

print('\n=== THE 175 EXTRA: WHICH MECHANISM INTRODUCES THEM ===')
extra = rb - ra
print('present in E (neither mechanism)  = %d' % len(extra & re_))
print('present in C (inlining refusal)   = %d' % len(extra & rc))
print('present in D (call indirection)   = %d' % len(extra & rd))
print('present in B (production)         = %d' % len(extra))
rel_b = {t for c, t, k in eb if k == RELEASE_K}
print('\nof the %d reached in B by a release edge:' % len(extra & rel_b))
print('   also present with NO indirection at all (arm C) = %d' %
      len(extra & rel_b & rc))
print('   -> the release edge introduces %d declaration(s) the other arms lack'
      % len(extra & rel_b - rc - rd - re_))
