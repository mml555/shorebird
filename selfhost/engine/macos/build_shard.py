#!/usr/bin/env python3
# cspell:words dartvm
"""Build the macOS engine shard (shorebird/ci/shards/macos.json) from a synced checkout.

Runs every gn_ninja and shell step, skips clang_tidy, and keeps going past a
failed shard so one broken configuration doesn't cost the rest of the night.
Writes "<date> <time> <shard>: STARTED" to logs/shards.status when a shard
starts and ": OK" or ": FAILED ..." when it ends. The last line per shard
decides its state, so a shard re-run that fails or is interrupted no longer
counts as built (collect_darwin.py reads the same file). Before building it
appends "--- engine <commit>" whenever the checkout is at a commit other than
the last such line names, and only lines after the last one count, so a shard
built at an earlier engine commit is built again. While it runs, its pid
is in logs/build.pid, which watchdog.sh and anything queued behind the build
wait on; it refuses to start while another build holds that file.

Run it with env.sh sourced (bootstrap.sh does the setup).

usage: build_shard.py [--jobs N] [--pending | shard ...]
  --pending   build every shard with no OK line for the checkout's commit
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


def now():
    return datetime.datetime.now().strftime("%F %T")


def engine_commit():
    return subprocess.check_output(["git", "-C", ROOT, "rev-parse", "HEAD"], text=True).strip()


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


def run(cmd, log, **kw):
    log.write(f"[{now()}] $ {' '.join(cmd) if isinstance(cmd, list) else cmd}\n")
    log.flush()
    return subprocess.run(cmd, cwd=SRC, stdout=log, stderr=subprocess.STDOUT, **kw).returncode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--pending", action="store_true")
    ap.add_argument("shards", nargs="*")
    a = ap.parse_args()
    spec = json.load(open(SHARDS))
    ordered = [n for n in ORDER if n in spec] + [n for n in spec if n not in ORDER]
    if a.pending and a.shards:
        sys.exit("--pending takes no shard names")
    head = engine_commit()
    marked, ok = read_status()
    if marked != head:
        ok = set()
    if a.pending:
        names = [n for n in ordered if n not in ok]
    else:
        names = a.shards or ordered
    unknown = [n for n in names if n not in spec]
    if unknown:
        sys.exit(f"unknown shard(s): {', '.join(unknown)}")
    os.makedirs(LOGS, exist_ok=True)
    claim_pid_file()
    if marked != head:
        status(f"--- engine {head} {now()}")
    failed = 0
    for name in names:
        path = os.path.join(LOGS, f"shard-{name}.log")
        status(f"{now()} {name}: STARTED")
        with open(path, "a") as log:
            ok = True
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
                    if rc == 0:
                        rc = run(["nice", "-n", "10", "ninja", "-C", f"out/{out}", "-j", str(a.jobs),
                                  *step["ninja_targets"]], log)
                elif t == "shell":
                    if "flutter/bin/et" in step["command"] and not link_et_dart(log):
                        rc = 1
                    else:
                        rc = run(step["command"], log, shell=True)
                else:
                    log.write(f"unknown step type {t}\n")
                    rc = 1
                if rc != 0:
                    ok = False
                    break
        status(f"{now()} {name}: {'OK' if ok else 'FAILED (see ' + path + ')'}")
        failed += not ok
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
