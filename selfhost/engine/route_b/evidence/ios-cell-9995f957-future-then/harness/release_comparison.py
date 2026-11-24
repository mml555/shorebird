"""Writes release_comparison.txt from the three local run directories.

Run from the devrun directory: python3 release_comparison.py. Reads each run's
route_b_snapshot_profile.json (9 MB, not kept), the archived App.framework/App,
the CLI worktree's HEAD and the distinct `Launch success` device-log lines
(each launch is in its step's log and in syslog.txt, so lines are deduplicated
by process id and patch number).
"""
import glob, json, os, re, subprocess

RUNS = [("run-9995f957", "1.0.0+75"), ("run-9995f957-ft", "1.0.0+76"), ("run-9995f957-668c", "1.0.0+77")]
LAUNCH = re.compile(r"Runner\(Flutter\)\[(\d+)\] <Notice>: \[shorebird\] Launch success for patch (\d+)")

for run, rel in RUNS:
    d = json.load(open(f"{run}/work/untab/build/route_b_snapshot_profile.json"))
    fields = d["snapshot"]["meta"]["node_fields"]
    i, n = fields.index("self_size"), len(fields)
    total = sum(d["nodes"][k + i] for k in range(0, len(d["nodes"]), n))
    cli = subprocess.run(["git", "-C", f"{run}/cli", "rev-parse", "--short=8", "HEAD"],
                         capture_output=True, text=True).stdout.strip()
    app = glob.glob(f"{run}/**/Products/Applications/Runner.app/Frameworks/App.framework/App", recursive=True)
    seen = set()
    for t in glob.glob(f"{run}/logs/*.txt"):
        for line in open(t, errors="replace"):
            m = LAUNCH.search(line)
            if m:
                seen.add(m.groups())
    by_patch = {}
    for _, p in seen:
        by_patch[p] = by_patch.get(p, 0) + 1
    print(f"{rel}  cli {cli}  snapshot_profile_self_size_total {total} B  "
          f"App.framework/App {os.path.getsize(app[0]) if app else None} B  "
          f"launch_success_by_patch {dict(sorted(by_patch.items()))} total {len(seen)}")
