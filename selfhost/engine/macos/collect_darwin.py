#!/usr/bin/env python3
# cspell:words dsts
"""Stage the macOS shard's outputs in the CDN overlay layout.

Reads shorebird/ci/shards/macos.json and compose.json, runs each compose step
whose shards all built, and copies every artifact to <out>/<dst> with $engine
filled in:

  flutter_infra_release/flutter/<engine>/...         as the shard names it
  download.shorebird.dev/shorebird/<engine>/...      for its shorebird/ dsts

engine_stamp.json is left out: the release already carries the one the Linux
build stamped, and both describe the same commit.

compose.json still lists FlutterMacOS.framework.dSYM.zip and
Flutter.framework.dSYM.zip, which create_macos_framework.py and
create_ios_framework.py no longer write: the dSYMs now ship inside the release
framework.zip and the iOS xcframework, and stock engines have no such files
either. They are reported as "not produced", not MISSING.

The engine is named after build_shard.py's engine commit (HEAD, or the commit
bin/internal/engine.version pins when HEAD only repins it). Only status lines
after the last "--- engine <commit>" line count, and that line must name the
same commit, so nothing built for another engine is staged.

iOS builds from shorebird-flutter 255fd850 on (shorebird_use_interpreter off,
no updater on iOS). Earlier commits fail their iOS shards or start the updater
on iOS; don't publish iOS from them.

usage: collect_darwin.py <out dir>   (prints what it staged and what it skipped)
"""
import json
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_shard import engine_commit, read_status, same_commit  # noqa: E402

W = os.environ.get("SHOREBIRD_ENGINE_DIR", os.path.expanduser("~/shorebird-engine"))
ROOT = os.path.join(W, "flutter")
SRC = os.path.join(ROOT, "engine", "src")
OUT_SRC = os.path.join(SRC, "out")
CI = os.path.join(ROOT, "shorebird", "ci")
NOT_PRODUCED = {"FlutterMacOS.framework.dSYM.zip", "Flutter.framework.dSYM.zip"}


def ok_shards(engine):
    """Shards built OK for `engine`, read from logs/shards.status."""
    path = os.path.join(W, "logs", "shards.status")
    if not os.path.exists(path):
        sys.exit(f"no {path}: run build_shard.py first")
    commit, ok = read_status()
    if not same_commit(commit, engine):
        sys.exit(f"{path} has no shards built for engine {engine} (last engine line: {commit}); "
                 "run build_shard.py at this commit first")
    return ok


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
    # A self-built engine is named after the commit it was built from.
    engine = engine_commit()
    shards = json.load(open(os.path.join(CI, "shards", "macos.json")))
    compose = json.load(open(os.path.join(CI, "compose.json")))
    ok = ok_shards(engine)
    lines = []
    for name, shard in shards.items():
        if name not in ok:
            lines.append(f"skip shard {name} (not built)")
            continue
        for a in shard.get("artifacts", []):
            lines.append(stage(os.path.join(OUT_SRC, a["src"]), a["dst"], engine, out,
                               zip_dir=a.get("zip", False)))
    for name, step in compose.items():
        req = step.get("requires", [])
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
