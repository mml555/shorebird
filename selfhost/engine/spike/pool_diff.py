#!/usr/bin/env python3
"""Spike A differ: judge object-pool cross-build identity on PATCH RELEVANCE.

Usage: pool_diff.py <base.jsonl> <patch.jsonl>

Reports the five metrics the spike is judged on:
  (a) % of base entries keyed (a key = deterministic structural identity)
  (b) unkeyed frequency by entry class
  (c) whether unkeyed entries MOVE between the builds
  (d) base entries with no unique match in the patch build (and vice versa)
  (e) collision rate among patch-relevant (i.e. non-interchangeable) entries

Keying:
  - immediates: (type, imm)
  - functions/closures: fully-qualified name + token position
  - arrays (incl. ArgumentsDescriptors): length + element strings
  - everything else: the ToCString text (strings are canonicalized objects,
    so identical text = identical object = interchangeable)
Entries whose key collides with a DIFFERENT underlying object would mislink;
entries whose key collides because the objects are literally identical are
interchangeable and any consistent mapping is correct. The distinction is:
within one build, same key + same full record = interchangeable; same key +
different record = a REAL collision.
"""
import json
import sys
from collections import Counter, defaultdict


def load(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def key(e):
    # patchable is part of the key: it is a property of the SLOT, and the
    # builder legitimately holds the same canonical object in one patchable
    # and one unpatchable slot (measured: every apparent "collision" in the
    # first run was exactly this bit).
    p = (e["type"], e.get("patchable"))
    if "imm" in e:
        # type 2 = kNativeFunction: the value is the gen_snapshot process's
        # own (ASLR'd) address for the native trampoline — nondeterministic in
        # the DUMP but relocated at snapshot load, so it carries no cross-build
        # identity. Key by type alone; multiplicity matching covers the rest.
        if e["type"] == 2:
            return ("native", p)
        return ("imm", p, e["imm"])
    if "fq" in e:
        return ("fn", p, e["fq"], e.get("tok"))
    if "elems" in e:
        # cid distinguishes _List from _ImmutableList with equal contents.
        return ("arr", p, e.get("cid"), e.get("len"), tuple(e["elems"]))
    return ("obj", p, e.get("cid"), e.get("s"))


def record(e):
    """Full identity record — two entries with equal records are the same
    object for mapping purposes (interchangeable)."""
    return json.dumps({k: v for k, v in e.items() if k != "i"}, sort_keys=True)


def klass(e):
    s = e.get("s", "")
    if "imm" in e:
        return "immediate"
    if "fq" in e:
        return "function/closure"
    if "elems" in e:
        return "array/argdesc"
    if s.startswith("Code("):
        return "code"
    if s.startswith("SubtypeTestCache"):
        return "subtype-test-cache"
    if s.startswith("TypeArguments"):
        return "type-arguments"
    if s.startswith("Type:"):
        return "type"
    if s.startswith("Field"):
        return "field"
    return "other/string"


def analyze(base, patch):
    bkeys, pkeys = defaultdict(list), defaultdict(list)
    for e in base:
        bkeys[key(e)].append(e)
    for e in patch:
        pkeys[key(e)].append(e)

    real_collisions = []   # same key, DIFFERENT records within the base build
    interchangeable = 0    # same key, identical records (multiplicity)
    unique = 0
    for k, es in bkeys.items():
        if len(es) == 1:
            unique += 1
        elif len({record(e) for e in es}) == 1:
            interchangeable += len(es)
        else:
            real_collisions.append((k, es))

    unmatched_base = {k: es for k, es in bkeys.items() if k not in pkeys}
    unmatched_patch = {k: es for k, es in pkeys.items() if k not in bkeys}

    moved = mult_mismatch = 0
    for k, es in bkeys.items():
        if k in pkeys:
            if len(pkeys[k]) != len(es):
                mult_mismatch += 1
            elif len(es) == 1 and es[0]["i"] != pkeys[k][0]["i"]:
                moved += 1

    n = len(base)
    print(f"base entries: {n}, patch entries: {len(patch)}")
    print(f"(a) uniquely keyed: {unique} ({unique * 100 // n}%); "
          f"interchangeable duplicates: {interchangeable}; "
          f"REAL intra-build collisions: {len(real_collisions)}")
    if real_collisions:
        print("(e) collision detail (same key, different records):")
        for k, es in real_collisions[:10]:
            cls = Counter(klass(e) for e in es)
            print(f"    {k[:2]}... x{len(es)}  classes={dict(cls)}")
    print(f"(c) uniquely-keyed entries that MOVED index: {moved}; "
          f"keys whose multiplicity changed: {mult_mismatch}")
    print(f"(d) base keys with NO match in patch: {len(unmatched_base)}; "
          f"patch keys new vs base: {len(unmatched_patch)}")
    for label, um in (("base-only", unmatched_base),
                      ("patch-only", unmatched_patch)):
        for k, es in list(um.items())[:8]:
            e = es[0]
            print(f"    {label}: [{klass(e)}] {e.get('s', e.get('imm'))!r:.100}")
    print("(b) unkeyed-class histogram among non-unique keys:")
    hist = Counter()
    for k, es in bkeys.items():
        if len(es) > 1:
            hist[klass(es[0])] += len(es)
    for cls, count in hist.most_common():
        print(f"    {cls:24} {count}")
    return len(real_collisions)


if __name__ == "__main__":
    base, patch = load(sys.argv[1]), load(sys.argv[2])
    sys.exit(1 if analyze(base, patch) else 0)
