# BACKUP-RESTORE-1 — certification

Two persistence profiles, certified independently. Each verdict is produced by
a re-runnable script, and each script was run against the **pre-repair** code
to confirm it can fail.

| profile | subject | verdict |
|---|---|---|
| **single** (default: SQLite + files in one volume) | `setup.sh --backup` / `--restore` | **CERTIFIED** — `br1_certify_single.sh`, 32 passed, 0 failed |
| **scale** (Postgres + MinIO) | `ops/backup.sh` / `ops/restore.sh` | **CERTIFIED** — `br1_certify_scale.sh`, 30 passed, 0 failed |

Scope of the claim: **control-plane data backup and restore.** Not complete
disaster recovery — see [SECRETS_BOUNDARY.md](SECRETS_BOUNDARY.md) for the
line, and for what an operator must supply separately.

## The certifications discriminate

The same scripts, unchanged, against the code as it was before this lane:

| profile | pre-repair | post-repair |
|---|---|---|
| single | 20 passed, **12 failed** | 32 passed, 0 failed |
| scale  | 14 passed, **15 failed** | 30 passed, 0 failed |

Every guard added is a check that fails without it. A certification that passed
both ways would be measuring nothing.

## Reproducing

```bash
# single — needs a throwaway deployment dir with setup.sh + ops/lib
DIR=/path/to/deployment PORT=18092 KEY=<its API_KEY> \
  selfhost/scripts/br1_certify_single.sh

# scale — needs two independently-volumed stacks
SRC_COMPOSE=… SRC_ENV=… SRC_PORT=18090 SRC_KEY=… \
DST_COMPOSE=… DST_ENV=… DST_PORT=18091 \
  selfhost/scripts/br1_certify_scale.sh
```

Restoring into the stack you backed up cannot distinguish "restore worked" from
"nothing happened", so the scale certification requires two stacks.

## What each certification establishes

Both profiles:

* the backup **quiesces**, measured by a probe that sees the deployment
  unreachable during the snapshot and reachable either side of it — not by
  reading a `stop` call in the script;
* a backup taken **under a live two-phase artifact writer** contains no state
  the running system could not have been in (`br1_tear_check.sh`), with the
  writer's completed-write count asserted so a dead writer cannot report
  consistency;
* restore is **exact** — a full inventory of every row of every state-bearing
  table plus every object's sha256, diffed against the archive's own contents;
* restore **wipes stale state** — a stale app, a stray file and a stray object
  are all gone afterwards;
* the restored deployment **still works** — new patch, upload, promote, and a
  device download whose bytes match what was uploaded;
* every negative control **refuses for its own distinct reason** and leaves the
  target byte-unchanged.

Single, additionally: `--backup` and `--restore` refuse when the target volume
would have to be guessed, and **both** refuse a destination that is still
writable — a stop that fails or no-ops is caught rather than trusted, and a
refusal restarts the deployment instead of leaving it down. Scale, additionally: both halves carry one
`backup_id`, and restore refuses a crossed pair, a tampered dump, a short or
altered object snapshot, an unmanifested half, and a running destination.

## The defects this replaced

Measured before any change, and the reason each guard exists:

| | measured |
|---|---|
| **scale** | every backup taken while serving held at least one object no row accounted for (4/4 runs) |
| **scale** | restoring one run's dump with another's objects exited 0 silently; the result reported an artifact `verified` and answered **404** for it — `patches/check` said `patch_available: true` and handed devices a URL that did not resolve |
| **scale** | restore ran to completion against a live serving stack while `pg_restore --clean` dropped its tables |
| **single** | a `--restore` run in a directory with **no deployment** wiped a different, live, healthy deployment's volume |
| **single** | a truncated archive destroyed the copy the operator still had — the wipe preceded any validation — leaving 303 rows with 4 objects |
| **single** | a well-formed archive with no database restored with exit 0, a green ✓ and a healthy server holding **zero** apps, releases, patches and audit records |
| **single** | one missing object restored green and broke the device update path with a 404 |
| **single** | the quiescing was `stop server \|\| true`; from a foreign directory the server stayed up for 94/94 requests and the backup reported success |

Full evidence: [GATE_A_FINDINGS.md](GATE_A_FINDINGS.md) (single),
[GATE_B_FINDINGS.md](GATE_B_FINDINGS.md) (scale).

## Re-certified after UPGRADE-ROLLBACK-1

That lane changed `setup.sh` and `ops/restore.sh` (image identity, and a schema
reset before `pg_restore`), so both certifications were re-earned rather than
assumed: single **32/32**, scale **30/30**. The single count rose by one because
its arm-B control gained an explicit precondition check.

## Corrections made during the lane

Recorded because they changed conclusions, not just wording.

1. **The consistency predicate was wrong at first.** Scoring any DB/object
   disagreement as damage counted a `pending` row with no bytes as a tear. It is
   not: the row is INSERTed before the bytes, so that is exactly what a live
   system looks like mid-upload. The corrected predicate
   (`br1_tear_check.sh`) counts only combinations the live system cannot
   occupy, and reports faithful in-flight rows separately.
2. **The first reproducibility table was four clean zeros from a dead writer.**
   Both writers were failing every request on a duplicate-version 500 and
   swallowing it. The harness now refuses to report unless the writer completed
   at least three writes.
3. **Five "correct" refusals were a bug in the harness**, not the verifier: a
   variable followed by a multi-byte ellipsis made bash die with `unbound
   variable`, which under `set -e` looked exactly like a clean refusal. Each
   negative control now asserts its own expected reason.
4. **A crash-loop blamed on a missing database was a permissions confound** —
   an archive repacked on macOS extracted as the wrong uid. Rebuilt inside a
   container, the real result was far worse: a silent green restore with total
   metadata loss.
5. **The first repair left `--restore` fail-open**, and the first certification
   did not notice. `--backup` asserted quiescence; `--restore` stopped the
   server and went straight to `rm -rf /data/*`, trusting a `stop || true` that
   cannot distinguish a real stop from a no-op. The harness proved a *normal*
   stop works, which is not the same claim. Caught in review, not by the
   suite — the reason step 6 now exists.
6. **Two fingerprint bugs made correct refusals look like data loss.** A clean
   SQLite close deletes `-wal`/`-shm` and folds the WAL into the main file, so
   any check that stops the server legitimately changes both the file count and
   `code_push.db`'s bytes. The arms that stop the server now compare a
   *logical* fingerprint — the full inventory digest — instead of file bytes.
7. **The truncated-archive control silently stopped truncating.** It cut a
   fixed 300 KB; on a freshly seeded rig the whole archive was smaller than
   that, so `head -c` copied it intact and the control became a
   valid-archive control that reported the good archive as ACCEPTED. It now
   truncates to half the archive and asserts the result is shorter.
