#!/usr/bin/env python3
# cspell:words dartvm
"""Build the macOS engine shard (shorebird/ci/shards/macos.json) from a synced checkout.

Runs every gn_ninja and shell step, skips clang_tidy, and keeps going past a
failed shard so one broken configuration doesn't cost the rest of the night.
Writes "<date> <time> <shard>: STARTED" to logs/shards.status when a shard
starts and ": OK" or ": FAILED ..." when it ends. The last line per shard
decides its state, so a shard re-run that fails or is interrupted no longer
counts as built (collect_darwin.py reads the same file). Before building it
appends "--- engine <commit>" whenever the checkout's engine commit differs
from the last such line, and only lines after the last one count, so a shard
built for an earlier engine is built again. The engine commit is the one
bin/internal/engine.version names when that is an ancestor of HEAD and nothing
the build reads (ENGINE_INPUTS) changed since, so a commit that only repins
engine.version to the engine it sits on keeps the shards built; otherwise it
is HEAD.

Each framework's Info.plist names the engine in its FlutterEngine key, which
copy_info_plist.py fills from `git rev-parse HEAD` when it runs. Ninja reruns
that action only when the plist template changes, so an incremental build kept
the commit of the out dir's first build (255fd850 shipped stamped 3a565f27 and
feb1d3cc). Before each gn_ninja step the stamped plists in that out dir are
removed, so the build writes them again. While it runs, its pid
is in logs/build.pid, which watchdog.sh and anything queued behind the build
wait on; it refuses to start while another build holds that file.

Run it with env.sh sourced (bootstrap.sh does the setup).

usage: build_shard.py [--jobs N] [--pending | shard ...]
       build_shard.py --left
  --pending   build every shard with no OK line for the checkout's engine commit
  --left      print the shards not built for it (watchdog.sh) and exit
"""
import argparse
import atexit
import datetime
import json
import os
import subprocess
import sys

W = os.environ.get("SHOREBIRD_ENGINE_DIR", os.path.expanduser("~/shorebird-engine"))
ROOT = os.path.join(W, "flutter")
SRC = os.path.join(ROOT, "engine", "src")
SHARDS = os.path.join(ROOT, "shorebird", "ci", "shards", "macos.json")
LOGS = os.path.join(W, "logs")
STATUS = os.path.join(LOGS, "shards.status")

# Most useful for the macOS CI jobs first.
ORDER = [
    "mac-arm64", "mac-arm64-debug", "android", "ios", "ios-debug",
    "ios-profile", "mac-arm64-profile", "mac-x64", "mac-x64-debug",
    "mac-x64-profile",
]


def stamped_plists(out_dir):
    """Generated framework Info.plists under out_dir that carry a FlutterEngine
    stamp. A plist that cannot be read is listed too, so a caller checking
    stamps sees it fail instead of passing it unread."""
    found = []
    for top, dirs, files in os.walk(out_dir):
        # obj/ and gen/ hold intermediates, never a framework's plist.
        if top == out_dir:
            dirs[:] = [d for d in dirs if d not in ("obj", "gen")]
        in_framework = any(part.endswith(".framework")
                           for part in os.path.relpath(top, out_dir).split(os.sep))
        if "Info.plist" not in files or not in_framework:
            continue
        path = os.path.join(top, "Info.plist")
        try:
            with open(path, "rb") as f:
                stamped = b"<key>FlutterEngine</key>" in f.read()
        except OSError:
            stamped = True
        if stamped:
            found.append(path)
    return found


def plist_engine(path):
    """The FlutterEngine value of a plist, or None."""
    r = subprocess.run(["plutil", "-extract", "FlutterEngine", "raw", "-o", "-", path],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def now():
    return datetime.datetime.now().strftime("%F %T")


# What the shard builds read from the checkout. A commit that changes none of
# these builds the same engine as its parent.
ENGINE_INPUTS = ["engine", "DEPS", "shorebird/ci"]


def git(*args):
    return subprocess.run(["git", "-C", ROOT, *args], capture_output=True, text=True)


def engine_commit():
    """The commit this checkout's engine is named after (see the module doc)."""
    r = git("rev-parse", "--verify", "HEAD")
    head = r.stdout.strip()
    if r.returncode != 0 or not head:
        sys.exit(f"{ROOT} is not a git checkout")
    try:
        pinned = open(os.path.join(ROOT, "bin", "internal", "engine.version")).read().strip()
    except OSError:
        return head
    if pinned != head and len(pinned) == 40 \
            and git("merge-base", "--is-ancestor", pinned, head).returncode == 0 \
            and git("diff", "--quiet", pinned, head, "--", *ENGINE_INPUTS).returncode == 0:
        return pinned
    return head


def same_commit(marked, engine):
    """A hand-written marker may abbreviate the commit."""
    return bool(marked) and len(marked) >= 7 and engine.startswith(marked)


def read_status():
    """(commit named by the last "--- engine" line or None, OK shards after it)."""
    commit, last = None, {}
    if os.path.exists(STATUS):
        for line in open(STATUS):
            parts = line.split()
            if line.startswith("--- engine ") and len(parts) >= 3:
                commit, last = parts[2], {}
            elif len(parts) >= 4 and parts[2].endswith(":"):
                last[parts[2].rstrip(":")] = parts[3]
    return commit, {n for n, state in last.items() if state == "OK"}



def read_waivers():
    """{shard: waived export symbols} for the shards' latest runs after the
    last "--- engine" line, from "OK with waived exports ..." and the
    separate "WAIVED exports ..." lines."""
    waivers = {}
    if os.path.exists(STATUS):
        for line in open(STATUS):
            parts = line.split()
            if line.startswith("--- engine "):
                waivers = {}
            elif len(parts) >= 4 and parts[2].endswith(":"):
                shard, rest = parts[2].rstrip(":"), parts[3:]
                if rest[0] == "STARTED" or rest[0] == "FAILED":
                    waivers.pop(shard, None)
                elif rest[:2] == ["WAIVED", "exports"]:
                    waivers[shard] = set(rest[2:])
                elif rest[:4] == ["OK", "with", "waived", "exports"]:
                    waivers[shard] = set(rest[4:])
    return {k: v for k, v in waivers.items() if v}

def status(line):
    print(line, flush=True)
    # Opened per line, so a file replaced mid-run still gets every result.
    with open(STATUS, "a") as f:
        f.write(line + "\n")


def claim_pid_file():
    path = os.path.join(LOGS, "build.pid")
    try:
        other = int(open(path).read().strip())
        os.kill(other, 0)
        if other != os.getpid():
            sys.exit(f"another build is running (pid {other} in {path})")
    except (FileNotFoundError, ValueError, ProcessLookupError):
        pass
    except PermissionError:
        sys.exit(f"pid in {path} belongs to another user's process")
    with open(path, "w") as f:
        f.write(f"{os.getpid()}\n")

    def release():
        try:
            if int(open(path).read().strip()) == os.getpid():
                os.remove(path)
        except (OSError, ValueError):
            pass
    atexit.register(release)


def gn_args_for(step):
    args = list(step["gn_args"])
    # Upstream builds the x64 macOS engine on arm64 with the prebuilt Dart SDK,
    # which is private. Without it the build runs its Dart tools on a host
    # dartvm, and an arm64 dartvm for an x64 target runs Dart's x64 simulator,
    # which aborts ("simulator_x64.cc: unimplemented code"). Build those host
    # tools as x64 instead; they run under Rosetta.
    if "--mac" in args and "--mac-cpu=x64" in args \
            and not any(a.startswith("--gn-args=host_cpu") for a in args):
        args.append('--gn-args=host_cpu="x64"')
    # The 32-bit Android build (--android with no --android-cpu) pulls in
    # create_macos_analyze_snapshots on a mac host, but Dart only defines
    # analyze_snapshot for 64-bit targets, so gn stops with "Unresolved
    # dependencies". Turn the tool on for that build.
    if "--android" in args and not any(a.startswith("--android-cpu") for a in args):
        args.append("--gn-args=build_analyze_snapshot=true")
    return args


def link_et_dart(log):
    """flutter/bin/et runs on prebuilts/macos-arm64/dart-sdk, which
    download_dart_sdk: False leaves out. Point it at the arm64 Dart SDK the
    mac-arm64 shard built (out/host_release_arm64)."""
    link = os.path.join(SRC, "flutter", "prebuilts", "macos-arm64", "dart-sdk")
    if os.path.exists(os.path.join(link, "bin", "dart")):
        return True
    if os.path.exists(link) and not os.path.islink(link):
        log.write(f"{link} exists but has no bin/dart; remove it and re-run\n")
        return False
    built = os.path.join(SRC, "out", "host_release_arm64", "dart-sdk")
    if not os.path.isfile(os.path.join(built, "bin", "dart")):
        log.write(f"et needs a Dart SDK: build the mac-arm64 shard first ({built} is missing)\n")
        return False
    os.makedirs(os.path.dirname(link), exist_ok=True)
    if os.path.islink(link):
        os.remove(link)
    os.symlink(os.path.relpath(built, os.path.dirname(link)), link)
    log.write(f"linked {link} -> {built}\n")
    return True


def verify_exported(log, waived, built_out):
    """Upstream's exported-symbol check (testing/symbols/verify_exported.dart)
    over every release build in out/. built_out is the out dir the shard's
    previous gn_ninja step built: the check must have looked at that build.

    It fails the shard unless the only problems are unexpected exports, from
    built_out, that --waive-export names one by one, and the script finished
    and counted exactly those failures. Returns (rc, waived symbols seen)."""
    # The script checks ios_*_release and android_*_release builds on macOS
    # (host_* only on Linux). Anything else would pass with nothing checked.
    if not built_out or "_release" not in built_out or \
            not built_out.startswith(("ios_", "android_")):
        log.write(f"verify_exported: the build before this step (got {built_out!r}) is not one "
                  "it checks on macOS, so it would pass with nothing checked\n")
        return 1, set()
    if not link_et_dart(log):
        return 1, set()
    dart = os.path.join(SRC, "flutter", "prebuilts", "macos-arm64", "dart-sdk", "bin", "dart")
    out = os.path.join(SRC, "out")
    cmd = [dart, "--packages=flutter/.dart_tool/package_config.json",
           "flutter/testing/symbols/verify_exported.dart",
           out, os.path.join(SRC, "flutter", "buildtools")]
    log.write(f"[{now()}] $ {' '.join(cmd)}\n")
    log.flush()
    p = subprocess.run(cmd, cwd=SRC, capture_output=True, text=True)
    text = p.stdout + p.stderr
    log.write(text if not text or text.endswith("\n") else text + "\n")
    mine = os.path.join(out, built_out) + os.sep
    lines = text.splitlines()
    if any(l.startswith("SKIPPING: " + mine) for l in lines):
        log.write(f"verify_exported skipped out/{built_out}, which this shard just built\n")
        return 1, set()
    if p.returncode == 0:
        return 0, set()
    # It can be waived only if the script ran to the end ("Failing checks: N" with
    # exit status N), every one of the N failures is an "exports unexpected
    # symbols" list for built_out, and every symbol listed is waived. A crash,
    # any other error, or a failure in another build fails as before.
    counted = [l for l in lines if l.startswith("Failing checks: ")]
    blocks, unexpected, other, in_list = 0, set(), [], False
    for line in lines:
        if line.startswith("ERROR:"):
            in_list = (line.startswith("ERROR: " + mine)
                       and line.endswith(" exports unexpected symbols:"))
            if in_list:
                blocks += 1
            else:
                other.append(line)
        elif in_list and line.startswith(" ") and line.strip():
            unexpected.add(line.split()[-1])
        else:
            in_list = False
    n = int(counted[-1].split()[-1]) if len(counted) == 1 and counted[0].split()[-1].isdigit() else -1
    if n < 1 or p.returncode != n % 256 or blocks != n or other:
        log.write(f"verify_exported failed in a way no waiver covers (exit {p.returncode}, "
                  f"failing checks {n if n >= 0 else 'not reported'}, unexpected-export lists {blocks}, "
                  f"other errors {len(other)})\n")
        return 1, set()
    if not unexpected or not unexpected <= waived:
        if unexpected - waived:
            log.write(f"not waived: {' '.join(sorted(unexpected - waived))}\n")
        return 1, set()
    log.write(f"WAIVED unexpected exports: {' '.join(sorted(unexpected))}\n")
    return 0, unexpected

def run(cmd, log, **kw):
    log.write(f"[{now()}] $ {' '.join(cmd) if isinstance(cmd, list) else cmd}\n")
    log.flush()
    return subprocess.run(cmd, cwd=SRC, stdout=log, stderr=subprocess.STDOUT, **kw).returncode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--pending", action="store_true")
    ap.add_argument("--left", action="store_true")
    ap.add_argument("--waive-export", action="append", default=[], metavar="SYMBOL",
                    help="let verify_exported pass when this exact symbol (Mach-O spelling, "
                         "e.g. _Foo) in the build the shard just made is its only complaint; "
                         "repeatable, recorded on the shard's OK line in the status file")
    ap.add_argument("shards", nargs="*")
    a = ap.parse_args()
    spec = json.load(open(SHARDS))
    ordered = [n for n in ORDER if n in spec] + [n for n in spec if n not in ORDER]
    if (a.pending or a.left) and a.shards:
        sys.exit("--pending and --left take no shard names")
    engine = engine_commit()
    if a.left:
        marked, ok = read_status()
        print(" ".join(n for n in ordered if not same_commit(marked, engine) or n not in ok))
        return 0
    os.makedirs(LOGS, exist_ok=True)
    claim_pid_file()
    # Read after taking the pid file, so no other build appends meanwhile.
    marked, ok = read_status()
    if not same_commit(marked, engine):
        print(f"engine commit is {engine}, last built {marked or 'unknown'}: "
              "no shard counts as built", flush=True)
        ok = set()
    if a.pending:
        names = [n for n in ordered if n not in ok]
    else:
        names = a.shards or ordered
    unknown = [n for n in names if n not in spec]
    if unknown:
        sys.exit(f"unknown shard(s): {', '.join(unknown)}")
    if not same_commit(marked, engine):
        status(f"--- engine {engine} {now()}")
    failed = 0
    for name in names:
        path = os.path.join(LOGS, f"shard-{name}.log")
        status(f"{now()} {name}: STARTED")
        with open(path, "a") as log:
            ok = True
            built_out, waived_here = None, set()
            for step in spec[name]["steps"]:
                t = step["type"]
                if t == "clang_tidy":
                    continue
                if t == "gn_ninja":
                    out = step["out_dir"]
                    rc = run(["./flutter/tools/gn", "--no-prebuilt-dart-sdk", *gn_args_for(step)], log)
                    if rc == 0 and not os.path.isfile(os.path.join(SRC, "out", out, "args.gn")):
                        log.write(f"gn did not produce out/{out}\n")
                        rc = 1
                    # Only once gn has succeeded, so a failed step leaves the
                    # out dir as it was.
                    if rc == 0:
                        for plist in stamped_plists(os.path.join(SRC, "out", out)):
                            try:
                                os.remove(plist)
                                log.write(f"removed {plist} so the build stamps it again\n")
                            except OSError as e:
                                log.write(f"cannot remove {plist}: {e}\n")
                                rc = 1
                    if rc == 0:
                        rc = run(["nice", "-n", "10", "ninja", "-C", f"out/{out}", "-j", str(a.jobs),
                                  *step["ninja_targets"]], log)
                    built_out = out if rc == 0 else None
                elif t == "shell":
                    if "flutter/bin/et" in step["command"] and not link_et_dart(log):
                        rc = 1
                    else:
                        rc = run(step["command"], log, shell=True)
                elif t == "verify_exported":
                    rc, seen = verify_exported(log, set(a.waive_export), built_out)
                    if seen:
                        waived_here |= seen
                        status(f"{now()} {name}: WAIVED exports {' '.join(sorted(seen))}")
                else:
                    log.write(f"unknown step type {t}\n")
                    rc = 1
                if rc != 0:
                    ok = False
                    break
        # read_status() keys on the word after the shard name, so the waiver
        # rides after "OK" and stays on the line that marks the shard built.
        waived_note = f" with waived exports {' '.join(sorted(waived_here))}" if ok and waived_here else ""
        status(f"{now()} {name}: {'OK' + waived_note if ok else 'FAILED (see ' + path + ')'}")
        failed += not ok
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
