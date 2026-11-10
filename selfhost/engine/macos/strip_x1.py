#!/usr/bin/env python3
# cspell:words fstack
"""Copy an Apple SDK and make it usable by the engine's pinned clang 23.

1. Drop the arm64e.x1 targets from its .tbd stubs.
2. Drop __attribute__((stack_protector_ignore)) from os/trace_base.h: clang
   warns it is ignored under -fstack-protector-all (the engine's mac flag),
   and the engine builds with -Werror. It only exempts os_log's format buffer
   from the stack protector.

Xcode 27's SDK stubs list an arm64e.x1 architecture that the engine's pinned
lld (clang 23) cannot parse, so it rejects whole stub files. The engine links
arm64 and x86_64 only, which never use those entries.

usage: strip_x1.py <src.sdk> <dst.sdk>
"""
import os, re, shutil, subprocess, sys

src, dst = os.path.realpath(sys.argv[1]), sys.argv[2]
if os.path.islink(dst):
    os.remove(dst)
elif os.path.exists(dst):
    shutil.rmtree(dst)
# -c: APFS clone, so the copy costs no space until a file is rewritten.
subprocess.check_call(["cp", "-Rc", src, dst])
LIST = re.compile(r"\[([^\]\[]*)\]", re.S)
X1 = re.compile(r"^arm64e\.x1-[\w-]+$")
changed = empty = 0
for root, _, files in os.walk(dst):
    for f in files:
        if not f.endswith(".tbd"):
            continue
        p = os.path.join(root, f)
        if os.path.islink(p):
            continue
        s = open(p, encoding="utf-8").read()
        if "arm64e.x1" not in s:
            continue
        def fix(m):
            global empty
            items = [i.strip() for i in m.group(1).split(",")]
            if not any(X1.match(i) for i in items):
                return m.group(0)
            kept = [i for i in items if i and not X1.match(i)]
            if not kept:
                empty += 1
            return "[ " + ", ".join(kept) + " ]"
        t = LIST.sub(fix, s)
        if "arm64e.x1" in t:
            sys.exit(f"arm64e.x1 left in {p}")
        os.remove(p)  # break the clone before writing
        open(p, "w", encoding="utf-8").write(t)
        changed += 1
h = os.path.join(dst, "usr/include/os/trace_base.h")
attr = "__attribute__((stack_protector_ignore)) "
if os.path.isfile(h):
    t = open(h, encoding="utf-8").read()
    n = t.count(attr)
    if n:
        os.remove(h)
        open(h, "w", encoding="utf-8").write(t.replace(attr, ""))
    print(f"{h}: removed {n} stack_protector_ignore")
print(f"{dst}: rewrote {changed} stubs, {empty} target lists left empty")
