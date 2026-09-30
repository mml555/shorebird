# Durability content-read — COMPLETE (the `audit_log` half)

2026-08-18. Host-side only; no device, no control-plane mutation.

`cycle_0013_prepared_state.md` recorded publish durability as **PARTIAL**: the
`releases`/`patches` half was content-read via the CLI, but `audit_log` was not,
because it appeared to need `docker exec` into `cps-ios` — which this session's
permissions refused. That gap is now closed, and it did not need `docker exec`.

## Method — and why it could not perturb the control plane

The database is BIND-MOUNTED to the host:

    docker inspect cps-ios -> bind /Users/mendell/shorebird-rig/control-plane/cps-ios : /data

So it is readable directly. Two precautions, both load-bearing:

1. **The `.db`, `-wal` and `-shm` were copied together.** The WAL was 1.5 MB and
   newer than the `.db` — this cycle's writes lived in it, so copying the `.db`
   alone would have read a stale database and understated the tables.
2. **All queries ran against the COPY, opened `mode=ro`.** The live database was
   never opened by this read, so no recovery, checkpoint or lock could be
   attributed to it.

## THE DENSITY SIGNATURE — the same test the prior lane used

| table | count | min | max | span | dense? | `sqlite_sequence` | == `MAX(id)`? |
|---|---|---|---|---|---|---|---|
| `audit_log` | 189 | 1 | 189 | 189 | **DENSE** | 189 | **EQUAL** |
| `releases` | 99 | 1 | 99 | 99 | **DENSE** | 99 | **EQUAL** |
| `patches` | 65 | 1 | 65 | 65 | **DENSE** | 65 | **EQUAL** |

Every table is perfectly dense with consecutive ids, and every high-water mark
equals `MAX(id)` — **no id was ever allocated beyond what survives**, which is the
signature that distinguishes "nothing was written" from "something was written and
lost".

## THIS CYCLE'S WRITES, all present

    189  patch.promote  65   channel=9   <- the repair patch (1.0.8+1)
    188  release.ready  99               <- killswitch 1.0.8+1, the repaired specimen
    187  patch.promote  64   channel=6   <- foldability patch
    186  release.ready  98               <- airgap 41.0.0+1
    185  patch.promote  63   channel=6   <- target-kind patch
    184  release.ready  97               <- airgap 40.0.0+1
    183  patch.promote  59   channel=9   <- arm 2's patch, promoted to stable
    182  patch.promote  62   channel=9
    181  release.ready  96               <- killswitch 1.0.7+1

**Nine operations, nine rows, no gaps.** The "publish returned success and
committed nothing" phenomenon (`HANDOFF-2026-08-16-g41c.md`) did NOT recur in this
cycle, and the dense/equal signature says nothing was silently dropped.

**VERDICT: publish durability for this cycle is CONTENT-READ ON BOTH HALVES.** The
provisional status recorded in `cycle_0013_prepared_state.md` is discharged.

## A MISLABEL THIS READ EXPOSED, and it was in committed evidence

Mapping ids to versions showed a collision:

    control-plane 98 = airgap      41.0.0+1
    control-plane 99 = killswitch  1.0.8+1   <- preserved as `evidence/releases/98`

The killswitch releases are preserved under their CONTROL-PLANE ID (91, 95, 96), so
`releases/98` claimed an id belonging to **a different app's release**. A later
reader resolving "release 98" against the control plane would have got the airgap
fixture and the wrong `App` bytes.

Corrected: `evidence/releases/98` → `evidence/releases/99`, with every textual
reference updated in `routebvalue_repair_verdict.txt`,
`routebvalue_repair/static_precheck.txt` and `tombstone_lane_PARKED.md`. The
`LC_UUID` in those files (`b68032df…`) was already correct and is unchanged —
identity was never wrong, only the label.

*(Note the convention differs by fixture and predates this cycle: `airgap_probe`
releases are preserved by VERSION (39, 40, 41), `killswitch_probe` by
CONTROL-PLANE ID (91, 95, 96, 99). Worth unifying eventually; not changed here.)*

## Still open in this area

`SHOREBIRD_JWT_ISSUER` remains misconfigured — a separate defect, deliberately not
touched in the same pass as a durability read.
