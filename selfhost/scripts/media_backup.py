#!/usr/bin/env python3
# cspell:words APFS syscall dests ffprobe xerror
"""media_backup.py -- inventory, partition and verify the one irreplaceable asset.

WHY THIS EXISTS. /Volumes/build/media is 513 GB across ~2,055 files and, since
2026-08-05, the only copy in existence. The drive holding it has now detached
mid-operation twice. This tool makes the recovery mechanical instead of
improvised, because improvising over 513 GB with ~55 GB of aggregate slack is
how the remaining copy gets damaged.

WHAT IT CANNOT DO, AND SAY SO PLAINLY. HANDOFF.md records that the media was
"MD5-verified byte-identical" on 2026-08-04, but no manifest survives -- the
hashes were never stored, and the subsequent deletion of both server copies was
decided on path and byte size alone. So there is NOTHING to verify today's
content against. `manifest` therefore establishes a baseline going forward; it
cannot prove the files are unchanged since August.

What is still provable, and what each subcommand actually establishes:

  manifest   reads every byte, so unreadable blocks surface as I/O errors --
             the main risk from a mid-write detach. Records path, size, mtime
             and MD5. Silent bit-rot in a readable block is NOT detectable
             without a prior baseline; APFS does not checksum user data.
  plan       assigns WHOLE files to destinations using ACTUAL free bytes with a
             reserve. Never splits a file across roots: a split archive turns
             two incomplete backups into zero usable ones the moment either
             host is lost.
  decode     the semantic pass. ffprobe proves only that the CONTAINER parses;
             a full ffmpeg decode walks the actual video and audio streams and
             catches truncated or corrupt frames a metadata probe misses. This
             is the only check here that can find damage in bytes that read
             back cleanly.
  verify     re-hashes files at a destination against the manifest. This one IS
             a real integrity proof, because the manifest was made from the
             same bytes being copied.

A DECODE FAILURE IS NOT PROOF OF DRIVE DAMAGE. Old source files can already
contain malformed streams, and some were probably always that way. The two
findings are therefore kept apart everywhere in this tool:

  I/O error   the drive could not return the bytes. Implicates the hardware.
  decode fail the bytes came back, but the stream does not decode. SUSPICIOUS,
              not conclusive -- it needs a human look before anything is
              deleted or overwritten.

Usage:
  media_backup.py manifest --root /Volumes/build/media --out media.json
  media_backup.py plan --manifest media.json --dest NAME:FREE_BYTES ... --out plan.json
  media_backup.py decode --manifest media.json --root /Volumes/build/media --out decode.json
  media_backup.py verify --manifest media.json --root /path/to/backup [--only NAME]
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys

# Read in 8 MiB chunks: large enough that syscall overhead is irrelevant over
# hundreds of GB, small enough not to matter for RAM.
CHUNK = 8 * 1024 * 1024

# Leave this much untouched on every destination. Filling a filesystem to the
# last byte is how a copy fails at 99% and leaves an unusable partial tree, and
# these two volumes have only ~55 GB of combined slack to begin with.
DEFAULT_RESERVE = 5 * 1024 * 1024 * 1024  # 5 GiB


def human(n):
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(n) < 1024:
            return f"{n:,.1f} {unit}"
        n /= 1024
    return f"{n:,.1f} PiB"


def md5_of(path):
    """MD5 of a file, or ('', reason) when it cannot be read.

    Read errors are RETURNED rather than raised: one unreadable file must not
    abort an inventory of 2,055, because the list of what is damaged is exactly
    the thing worth having.
    """
    h = hashlib.md5()
    try:
        with open(path, "rb") as f:
            while True:
                block = f.read(CHUNK)
                if not block:
                    break
                h.update(block)
    except OSError as e:
        return "", f"{type(e).__name__}: {e}"
    return h.hexdigest(), ""


def cmd_manifest(args):
    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        sys.exit(f"error: no such directory: {root}")

    files, errors, total = [], [], 0
    for dirpath, _, filenames in os.walk(root):
        for name in sorted(filenames):
            if name == ".DS_Store":
                continue
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                continue
            try:
                st = os.stat(full)
            except OSError as e:
                errors.append({"path": os.path.relpath(full, root), "error": str(e)})
                continue
            digest, err = md5_of(full)
            rel = os.path.relpath(full, root)
            if err:
                errors.append({"path": rel, "error": err})
                print(f"  UNREADABLE {rel}: {err}", file=sys.stderr)
            files.append(
                {"path": rel, "size": st.st_size, "mtime": int(st.st_mtime),
                 "md5": digest, "error": err}
            )
            total += st.st_size
            print(f"\r  {len(files):,} files, {human(total)}", end="", file=sys.stderr)
    print(file=sys.stderr)

    out = {"manifestVersion": 1, "root": root, "fileCount": len(files),
           "totalBytes": total, "errorCount": len(errors), "files": files}
    with open(args.out, "w") as f:
        json.dump(out, f, indent=2)
        f.write("\n")

    print(f"wrote {args.out}")
    print(f"  files      : {len(files):,}")
    print(f"  total      : {human(total)}")
    print(f"  unreadable : {len(errors)}")
    if errors:
        # Loudly, and non-zero: an unreadable file after a detach is a damaged
        # original, and copying around it silently would bake the loss in.
        print("\nUNREADABLE FILES -- the original is damaged. Do not treat this")
        print("as an ordinary copy job; decide what to do about these first:")
        for e in errors[:20]:
            print(f"  {e['path']}: {e['error']}")
        if len(errors) > 20:
            print(f"  ... and {len(errors) - 20} more")
        return 2
    return 0


def cmd_plan(args):
    with open(args.manifest) as f:
        manifest = json.load(f)

    dests = []
    for spec in args.dest:
        name, _, free = spec.partition(":")
        if not free.isdigit():
            sys.exit(f"error: --dest wants NAME:FREE_BYTES, got: {spec}")
        usable = int(free) - args.reserve
        if usable <= 0:
            sys.exit(f"error: {name} has no usable space after the reserve")
        dests.append({"name": name, "free": int(free), "usable": usable,
                      "assigned": 0, "files": []})

    # Largest first. Big files are the ones that fail to fit at the end, so
    # placing them while both destinations are empty is what makes a tight fit
    # succeed at all -- and 513 GB into ~568 GB is tight.
    files = sorted(
        (f for f in manifest["files"] if not f["error"]),
        key=lambda f: f["size"], reverse=True,
    )
    skipped = [f for f in manifest["files"] if f["error"]]

    unplaced = []
    for f in files:
        # Whole files only. Never split one across roots.
        candidates = [d for d in dests if d["assigned"] + f["size"] <= d["usable"]]
        if not candidates:
            unplaced.append(f)
            continue
        # Most remaining room, so the two roots stay balanced and a late large
        # file still has somewhere to go.
        best = max(candidates, key=lambda d: d["usable"] - d["assigned"])
        best["files"].append(f["path"])
        best["assigned"] += f["size"]

    plan = {"planVersion": 1, "manifest": os.path.abspath(args.manifest),
            "reserveBytes": args.reserve,
            "destinations": [
                {"name": d["name"], "freeBytes": d["free"],
                 "assignedBytes": d["assigned"], "fileCount": len(d["files"]),
                 "files": d["files"]} for d in dests],
            "unplaced": [f["path"] for f in unplaced],
            "skippedUnreadable": [f["path"] for f in skipped]}
    with open(args.out, "w") as f:
        json.dump(plan, f, indent=2)
        f.write("\n")

    print(f"wrote {args.out}")
    for d in dests:
        print(f"  {d['name']:<24} {len(d['files']):>5} files  "
              f"{human(d['assigned']):>12} of {human(d['usable'])} usable")
    if skipped:
        print(f"  SKIPPED (unreadable in source): {len(skipped)}")
    if unplaced:
        need = sum(f["size"] for f in unplaced)
        print(f"\nDOES NOT FIT: {len(unplaced)} files, {human(need)} unplaced.")
        print("Add capacity or reduce the reserve. Do NOT split a file to make")
        print("it fit -- two incomplete backups are worth less than one.")
        return 2
    return 0


def _tool_version(binary):
    """First line of `<binary> -version`, or a marker if it cannot be run."""
    try:
        out = subprocess.run([binary, "-version"], capture_output=True, text=True)
        return out.stdout.splitlines()[0] if out.stdout else "(no output)"
    except (OSError, IndexError) as e:
        return f"(unavailable: {e})"


def cmd_decode(args):
    """Container parse, then full stream decode, with the two kept apart.

    ffprobe answers "does the CONTAINER parse and what streams does it claim".
    ffmpeg answers "do those streams actually decode end to end". Running both
    is what separates a suspicious container from semantic corruption inside an
    otherwise well-formed file, and those two findings deserve different
    responses.

    The report records the exact commands and the decoder versions. If a
    handful of files fail, the question six months from now is whether the
    finding was content-specific or decoder-version-specific, and that is
    unanswerable after the fact unless it was written down at the time.
    """
    with open(args.manifest) as f:
        manifest = json.load(f)

    probe_cmd = ["ffprobe", "-v", "error", "-show_entries",
                 "format=duration,format_name:stream=codec_type,codec_name",
                 "-of", "json", "FILE"]
    decode_cmd = ["ffmpeg", "-v", "error", "-xerror", "-i", "FILE",
                  "-map", "0:v?", "-map", "0:a?", "-f", "null", "-"]

    exts = {e.lower() for e in args.ext.split(",") if e}
    targets = [
        entry for entry in manifest["files"]
        if not entry["error"]
        and os.path.splitext(entry["path"])[1].lower().lstrip(".") in exts
    ]

    results, checked = [], 0
    counts = {"clean": 0, "container": 0, "stream": 0, "missing": 0}
    for entry in targets:
        full = os.path.join(args.root, entry["path"])
        rel = entry["path"]
        if not os.path.exists(full):
            results.append({"path": rel, "kind": "missing", "detail": ""})
            counts["missing"] += 1
            continue

        probe = subprocess.run([a if a != "FILE" else full for a in probe_cmd],
                               capture_output=True, text=True)
        if probe.returncode != 0:
            # The container itself does not parse. Nothing downstream is
            # meaningful, so do not spend a full decode on it.
            results.append({"path": rel, "kind": "container",
                            "returncode": probe.returncode,
                            "detail": probe.stderr.strip()[:500]})
            counts["container"] += 1
            print(f"  CONTAINER FAIL {rel}", file=sys.stderr)
            checked += 1
            continue

        meta = ""
        try:
            info = json.loads(probe.stdout or "{}")
            meta = (info.get("format", {}) or {}).get("duration", "")
        except json.JSONDecodeError:
            pass

        dec = subprocess.run([a if a != "FILE" else full for a in decode_cmd],
                             capture_output=True, text=True)
        checked += 1
        if dec.returncode != 0 or dec.stderr.strip():
            results.append({"path": rel, "kind": "stream",
                            "returncode": dec.returncode,
                            "duration": meta,
                            "detail": dec.stderr.strip()[:500]})
            counts["stream"] += 1
            print(f"  STREAM FAIL {rel}", file=sys.stderr)
        else:
            counts["clean"] += 1
        print(f"\r  decoded {checked:,}/{len(targets):,}", end="", file=sys.stderr)
    print(file=sys.stderr)

    out = {
        "decodeVersion": 2,
        "root": os.path.abspath(args.root),
        # Provenance: a finding is only interpretable against the decoder that
        # produced it.
        "tools": {"ffprobe": _tool_version("ffprobe"),
                  "ffmpeg": _tool_version("ffmpeg")},
        "commands": {"probe": " ".join(probe_cmd), "decode": " ".join(decode_cmd)},
        "checked": checked,
        "counts": counts,
        "findings": results,
    }
    with open(args.out, "w") as f:
        json.dump(out, f, indent=2)
        f.write("\n")

    print(f"wrote {args.out}")
    print(f"  ffmpeg   : {out['tools']['ffmpeg']}")
    print(f"  checked  : {checked:,}")
    print(f"  clean    : {counts['clean']:,}")
    print(f"  container: {counts['container']:,}   (file will not parse)")
    print(f"  stream   : {counts['stream']:,}   (parses, does not decode)")
    print(f"  missing  : {counts['missing']:,}")
    if counts["container"] or counts["stream"] or counts["missing"]:
        # Never called corruption here. Read failures implicate the drive;
        # these do not, on their own. Some of these files may have been
        # malformed long before this drive ever misbehaved.
        print("\nSUSPICIOUS FILES. This is NOT by itself evidence of drive")
        print("damage -- compare against the I/O errors from `manifest`, which")
        print("are. Review before copying or deleting anything:")
        for entry in results[:20]:
            print(f"  [{entry['kind']}] {entry['path']}")
        if len(results) > 20:
            print(f"  ... and {len(results) - 20} more")
        return 2
    return 0


def cmd_verify(args):
    with open(args.manifest) as f:
        manifest = json.load(f)
    expected = {f["path"]: f for f in manifest["files"] if not f["error"]}

    if args.only:
        with open(args.only) as f:
            plan = json.load(f)
        wanted = set()
        for d in plan["destinations"]:
            if d["name"] == args.name:
                wanted = set(d["files"])
        if not wanted:
            sys.exit(f"error: no destination named {args.name} in {args.only}")
        expected = {p: v for p, v in expected.items() if p in wanted}

    ok = missing = mismatch = 0
    for rel, meta in sorted(expected.items()):
        full = os.path.join(args.root, rel)
        if not os.path.exists(full):
            print(f"  MISSING  {rel}")
            missing += 1
            continue
        digest, err = md5_of(full)
        if err or digest != meta["md5"]:
            print(f"  MISMATCH {rel}  {err or digest}")
            mismatch += 1
        else:
            ok += 1
        print(f"\r  verified {ok:,}", end="", file=sys.stderr)
    print(file=sys.stderr)

    print(f"\nverified : {ok:,}")
    print(f"missing  : {missing:,}")
    print(f"mismatch : {mismatch:,}")
    return 0 if (missing == 0 and mismatch == 0) else 2


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    m = sub.add_parser("manifest", help="inventory a tree: size + MD5, surfacing I/O errors")
    m.add_argument("--root", required=True)
    m.add_argument("--out", required=True)
    m.set_defaults(func=cmd_manifest)

    pl = sub.add_parser("plan", help="assign whole files to destinations by ACTUAL free bytes")
    pl.add_argument("--manifest", required=True)
    pl.add_argument("--dest", action="append", required=True,
                    metavar="NAME:FREE_BYTES",
                    help="repeatable; free bytes from `df --output=avail`, not nominal size")
    pl.add_argument("--reserve", type=int, default=DEFAULT_RESERVE)
    pl.add_argument("--out", required=True)
    pl.set_defaults(func=cmd_plan)

    d = sub.add_parser("decode", help="full ffmpeg decode; finds damage that reads back cleanly")
    d.add_argument("--manifest", required=True)
    d.add_argument("--root", required=True)
    d.add_argument("--out", required=True)
    d.add_argument("--ext", default="mkv,mp4,avi,m4v,mov,ts,m2ts,wmv,flv,webm",
                   help="comma-separated extensions to decode")
    d.set_defaults(func=cmd_decode)

    v = sub.add_parser("verify", help="re-hash a destination against the manifest")
    v.add_argument("--manifest", required=True)
    v.add_argument("--root", required=True)
    v.add_argument("--only", help="a plan.json, to verify only one destination's share")
    v.add_argument("--name", help="destination name within --only")
    v.set_defaults(func=cmd_verify)

    args = p.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
