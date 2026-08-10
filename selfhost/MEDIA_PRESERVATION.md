<!-- cspell:words APFS ffprobe fsck enclosure -->

# Media preservation — runbook and standing rules

`/Volumes/build/media` is 513 GB across 2,055 files and, since 2026-08-05, the
only copy in existence. The SSD holding it has physically detached mid-operation
**twice**. This is the procedure for getting it to two durable copies, and the
rules that outlive the incident.

Everything here is about *preservation*, not recovery: as of 2026-08-09 the
media is intact by every test available. Do not read urgency into it as damage.

## What is established, and what each claim rests on

| claim | evidence | limit |
|---|---|---|
| No filesystem-structural damage | `diskutil verifyVolume` → *"appears to be OK"*, exit 0 | says nothing about file contents |
| No missing files | 2,055 files / 513 GB, exact match to the recorded figures | equality of count and size, not content |
| **Every byte readable** | full-byte read of all 2,055 files, **0 I/O errors** | proves readable, not *correct* |
| **202 files unchanged since 2010** | `.sfv` CRC32 manifests written 2010-04-12 → **202/202 OK** | covers ~10 % of the tree only |
| A baseline exists **going forward** | MD5 per file, stored off-drive | dates from 2026-08-09, not earlier |

### There is no historical baseline for the other 1,853 files

`HANDOFF.md` used to say the media was *"MD5-verified byte-identical"* on
2026-08-04. **The hashes were never retained.** What survives supports path and
byte-size equality, which is what the deletion of both server copies was
actually decided on. APFS does not checksum user data, so the filesystem never
held that proof either.

The `.sfv` discovery is the one exception and it was luck — the original
packager shipped checksums inside the collection. Treat it as a reminder to
*store* verification output, not as a general safety net.

## The order, and why it is this order

```
manifest → copy → verify destinations → [SSD stops being load-bearing]
        → decode the COPIES → replace cable → resume other work
```

**Decode does not gate the copy.** It was originally sequenced first and moved
deliberately. The full-byte read returned zero I/O errors, so decode is
content-quality analysis; it cannot change the decision that these bytes should
be preserved. Gating a 17-hour copy behind a 30–50-hour decode would have meant
30–50 more hours with exactly one copy in existence, on a drive that has already
failed twice.

**Copy work accumulates; decode work does not.** A detach at hour 10 of a copy
leaves 60 % preserved and `rsync --partial` resumes. A decode interrupted at
hour 10 lost everything — demonstrated, not hypothesised, which is why decode
now checkpoints per file.

**Decode runs against the verified copies, never the SSD again.** Once
destination MD5s match the manifest the copies are byte-identical, so decoding
them is semantically equivalent and costs the fragile drive nothing.

## The commands

All subcommands live in [`scripts/media_backup.py`](scripts/media_backup.py).

```bash
# 1. Baseline + readability. Output goes on a DIFFERENT disk than the source.
media_backup.py manifest --root /Volumes/build/media --out media_manifest.json

# 2. Placement. ACTUAL free bytes (df -B1 --output=avail), never nominal size.
media_backup.py plan --manifest media_manifest.json \
  --dest "data:400180142080" --dest "spare:208978722816" \
  --reserve 10737418240 --out placement_plan.json

# 3. Copy, one destination at a time (both are on one host; the WAN is the
#    bottleneck, so concurrency splits bandwidth and doubles SSD load for
#    nothing). --partial to resume, never --delete.
rsync -a --partial --files-from=files_data.txt SRC/ host:/data/ssd-backup/

# 4. Verify ON THE DESTINATION HOST, so 513 GB is not pulled back over the WAN.
media_backup.py verify --manifest media_manifest.json --root /data/ssd-backup \
  --only placement_plan.json --name data
#    --present-only to check a copy that is still running.

# 5. Semantic pass, against the COPIES. Always with --checkpoint.
media_backup.py decode --manifest media_manifest.json --root /data/ssd-backup \
  --only placement_plan.json --name data \
  --checkpoint decode_data.jsonl --out decode_data.json
```

## Reading the results

Four outcomes, three of which are not the same thing:

| finding | means | implicates |
|---|---|---|
| **I/O error** (`manifest`) | the drive could not return the bytes | **the hardware** |
| **container** (`decode`) | file does not parse at all | the file |
| **stream** (`decode`) | parses, but does not decode end to end | the file |
| **clean** | decoded fully | — |

**A decode failure is not evidence of drive damage.** Some of these files may
have been malformed long before this drive misbehaved. Only I/O errors implicate
the hardware. Never merge the two counts.

Record the ffmpeg version — the report does this automatically. Hermes runs
6.1.1 and the Mac runs 8.1.2, so a file failing on one may pass on the other,
and six months from now that has to be attributable.

## Standing rules

1. **On any detach: stop.** Then `diskutil verifyVolume`, re-confirm the mount
   is the external filesystem (`df` should show the real device, not
   `/System/Volumes/Data` — an empty mountpoint on the internal disk looks
   convincingly like the real thing), and only then resume. `rsync --partial`
   makes resuming easy; that is not a reason to resume onto a faulted volume.
2. **Replace the cable/enclosure path before any further long build**, attended
   or not. The drive has vanished mid-write twice, and once it enumerated at the
   disk layer while showing **no device at all** on USB or Thunderbolt.
3. **Re-check actual free bytes before each destination leg.** A ~17 GiB reserve
   is enough only if nothing else grew.
4. **Keep manifest, plan and checkpoints off both backup volumes** as well as on
   them. Either root is incomplete alone; the metadata is what makes the union
   reconstructible. They currently live on this Mac plus
   `/data/ssd-backup-meta` and `/mnt/spare/ssd-backup-meta`.
5. **Store verification output, always.** The single most expensive fact in this
   whole episode is that a verification ran in August and kept nothing.
6. **Long jobs run under `screen` with `caffeinate`**, never as a harness
   background task — harness cleanup has killed builds here twice, and idle
   sleep killed another.

## What "done" means

The SSD stops being load-bearing at exactly one point:

> **source manifest MD5 == destination MD5, for every file in the plan.**

Not when the copy finishes — when both roots verify. Until then there is still
only one trustworthy copy.
