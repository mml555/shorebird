#!/usr/bin/env python3
# cspell:words dsts
"""Stage the macOS shard's outputs in the CDN overlay layout.

Reads shorebird/ci/shards/macos.json and compose.json, skips iOS (it does not
build against our Dart at 3a565f27), runs each compose step whose shards all
built, and copies every artifact to <out>/<dst> with $engine filled in:

  flutter_infra_release/flutter/<engine>/...         as the shard names it
  download.shorebird.dev/shorebird/<engine>/...      for its shorebird/ dsts

engine_stamp.json is left out: the release already carries the one the Linux
build stamped, and both describe the same commit.

compose.json still lists FlutterMacOS.framework.dSYM.zip, which
create_macos_framework.py no longer writes: the dSYM now ships inside the
release framework.zip, and stock engines have no such file either. It is
reported as "not produced", not MISSING.

usage: collect_darwin.py <out dir>   (prints what it staged and what it skipped)
"""
import json
import os
import shutil
import subprocess
import sys

W = os.environ.get("SHOREBIRD_ENGINE_DIR", os.path.expanduser("~/shorebird-engine"))
ROOT = os.path.join(W, "flutter")
SRC = os.path.join(ROOT, "engine", "src")
OUT_SRC = os.path.join(SRC, "out")
CI = os.path.join(ROOT, "shorebird", "ci")
NOT_PRODUCED = {"FlutterMacOS.framework.dSYM.zip"}


def ok_shards():
    """Shards whose last line in logs/shards.status is OK (build_shard.py's format)."""
    path = os.path.join(W, "logs", "shards.status")
    if not os.path.exists(path):
        sys.exit(f"no {path}: run build_shard.py first")
    last = {}
    for line in open(path):
        parts = line.split()
        if len(parts) >= 4 and parts[2].endswith(":"):
            last[parts[2].rstrip(":")] = parts[3]
    return {n for n, state in last.items() if state == "OK"}


def place(dst_rel, engine, out):
    dst_rel = dst_rel.replace("$engine", engine)
    if dst_rel.startswith("shorebird/"):
        dst_rel = "download.shorebird.dev/" + dst_rel
    path = os.path.join(out, dst_rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    return dst_rel, path


def stage(src, dst_rel, engine, out, zip_dir=False):
    rel, path = place(dst_rel, engine, out)
    if rel.endswith("/engine_stamp.json"):
        return f"skip {rel} (release has the Linux stamp)"
    if not os.path.exists(src):
        if os.path.basename(src) in NOT_PRODUCED:
            return f"skip {rel} (not produced by this engine's scripts)"
        return f"MISSING {src}"
    if zip_dir:
        # dart-sdk/ at the top of the archive, symlinks kept, as the Linux one.
        if os.path.exists(path):
            os.remove(path)
        subprocess.check_call(["zip", "-qry", path, os.path.basename(src)],
                              cwd=os.path.dirname(src))
    else:
        shutil.copy2(src, path)
    return f"staged {rel}"


def main():
    out = os.path.abspath(sys.argv[1])
    # A self-built engine is named after the commit it was built from
    # (bin/internal/engine.version there still names the upstream pin).
    engine = subprocess.check_output(["git", "-C", ROOT, "rev-parse", "HEAD"], text=True).strip()
    shards = json.load(open(os.path.join(CI, "shards", "macos.json")))
    compose = json.load(open(os.path.join(CI, "compose.json")))
    ok = ok_shards()
    lines = []
    for name, shard in shards.items():
        if name.startswith("ios"):
            continue
        if name not in ok:
            lines.append(f"skip shard {name} (not built)")
            continue
        for a in shard.get("artifacts", []):
            lines.append(stage(os.path.join(OUT_SRC, a["src"]), a["dst"], engine, out,
                               zip_dir=a.get("zip", False)))
    for name, step in compose.items():
        req = step.get("requires", [])
        if any(r.startswith("ios") for r in req):
            continue
        if not all(r in ok for r in req):
            lines.append(f"skip compose {name} (needs {', '.join(r for r in req if r not in ok)})")
            continue
        # A compose dst is relative to out/ (default out/release); its
        # artifacts are relative to out/release.
        dst = os.path.join(OUT_SRC, step.get("dst", "release"))
        os.makedirs(dst, exist_ok=True)
        args = ["python3", step["script"], "--dst", dst, *step.get("flags", [])]
        for flag, val in step.get("path_args", {}).items():
            args += [flag, os.path.join(OUT_SRC, val)]
        subprocess.check_call(args, cwd=SRC)
        base = os.path.join(OUT_SRC, "release")
        for a in step.get("artifacts", []):
            lines.append(stage(os.path.join(base, a["src"]), a["dst"], engine, out))
    print("\n".join(lines))
    return 1 if any(l.startswith("MISSING") for l in lines) else 0


if __name__ == "__main__":
    sys.exit(main())
