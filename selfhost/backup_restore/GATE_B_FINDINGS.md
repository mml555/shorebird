# BACKUP-RESTORE-1 · Gate B — the scale pair, scripts as written

Subject, unmodified: `packages/code_push_server/ops/backup.sh` and
`ops/restore.sh`. Rig: a throwaway scale stack (Postgres 16 + MinIO +
`ghcr.io/mml555/code-push-server:1.3.0`) on `127.0.0.1:18090`, restored into a
second, independently-volumed stack on `:18091`.

Nothing below is inferred from reading the scripts. Every line is a measurement
against a running stack.

## The predicate — and a correction to my first attempt at it

The first version of this analysis scored a backup as inconsistent whenever the
DB half and the object half disagreed. **That predicate is wrong, and it
produced a false finding** that I reported before catching it.

An artifact is written in a fixed order (`api.dart` `_upload`):

```
INSERT row status=pending     (no object)
status := uploading           (no object)
store.put(key, bytes)         (object appears, row still `uploading`)
status := verified            (object present)
```

So a row saying `pending` with no object on disk is a **faithful** capture of an
upload that was genuinely in flight. The live system looks exactly like that at
that instant, and a backup recording it is *correct*. Counting it as damage
inflated the numbers and pointed at the wrong cause.

The sound question is: **is there any instant at which the live system's state
equalled this backup's state?** Only three combinations answer no:

| | state | why it is impossible live |
|---|---|---|
| **TEAR-1** | object present, no row at all | the row is always INSERTed before the bytes |
| **TEAR-2** | object present, row says `pending` | `put` happens only after the row reaches `uploading` |
| **TEAR-3** | row says `verified`, object absent | `verified` is set only after a successful `put` |

`selfhost/scripts/br1_tear_check.sh` implements exactly this, and reports
faithful in-flight rows separately so they cannot be mistaken for damage.

## S-1 — CONFIRMED: the halves are snapshotted at different times, and the
## backup records states the system was never in

`backup.sh` runs `pg_dump` (T1) then `mc mirror` (T2) with nothing between: no
lock, no stop, no read-only mode, no reconciliation. Measured window on this
rig: T1 at `23:27:18.344Z`, mirror listing `…18.958Z`–`…18.990Z` — **830 ms**,
dominated by `docker compose run` container startup.

Four runs of the unmodified script with a writer performing the real two-phase
artifact write, each scored by restoring the dump into a scratch database and
diffing it against the mirror directory:

```
run 1 (writer_completed=31):  TEARS=1  T1=1 T2=0 T3=0   faithful-in-flight=1
run 2 (writer_completed=31):  TEARS=1  T1=1 T2=0 T3=0   faithful-in-flight=1
run 3 (writer_completed=31):  TEARS=2  T1=1 T2=1 T3=0   faithful-in-flight=1
run 4 (writer_completed=30):  TEARS=2  T1=1 T2=1 T3=0   faithful-in-flight=1
```

**TEAR-1 in 4/4. TEAR-2 in 2/4.** Every backup taken while the deployment was
serving contained at least one object that no row in the same backup accounts
for — an unreachable, unreclaimable orphan, since nothing in this system ever
deletes an object.

`T3=0` in 4/4 is a positive result, not an absence. `ArtifactStore`
(lib/src/artifact_store.dart) exposes `put`, `exists`, `size`, `verify`,
`stageChunk`, `commitStaged` — and **no delete**. The store is append-only, so
with `pg_dump` strictly before `mc mirror`:

    objects(T2) ⊇ objects(T1) ⊇ objects referenced by DB(T1)

A `verified` row therefore cannot lose its object to concurrency *in this
ordering*. The counter that would have shown otherwise was live and read zero.

> The harness that produced this table first reported four clean `0/0` runs
> with identical row and object counts. Both writers were failing every request
> on `releases_app_id_version_key` (HTTP 500, duplicate version from the prior
> run) and swallowing it in a `continue`. It now refuses to report a result
> unless `writer_completed >= 3`, and the writer aborts after ten consecutive
> failures instead of spinning. A concurrency experiment whose writer is dead
> reports perfect consistency.

## S-2 — CONFIRMED: restore accepts crossed pairs silently, and that is the
## only route to the damaging TEAR-3

`restore.sh` takes two independent path arguments. Neither half records which
run produced it; the only linkage is the shared `STAMP` in the two filenames,
which the script never reads and never compares. Filenames are not provenance.

Restoring `pair2/postgres_*.dump` with `pair1/minio/*` exited **0**, silently:

```
artifact 47  status=verified  key=release/61/2c3d950b8168af30ad1aa74ca9c24cf6
GET /api/v1/apps/{app}/releases/61/artifacts  -> HTTP 200 + signed download URL
GET <that signed URL>                          -> HTTP 404
```

This is the state S-1 proved concurrency alone cannot reach. The restored
control plane reports an artifact as ready and cannot serve it. Since a matched
pair is only matched by operator discipline, "we never cross them" is the sole
thing standing between this deployment and serving 404s for ready artifacts.

## S-3 — DEFECT: restore does not stop the server, it documents that you should

The header says to `docker compose stop server` first. The script never checks.
The crossed-pair restore above ran to completion against a live, serving stack
while `pg_restore --clean` dropped and recreated its tables underneath it, and
exited 0.

## S-4 — DEFECT: a third piece of state is in neither half

`S3ArtifactStore.open` stages resumable-upload chunks in
`Directory.systemTemp/cps_staging` — the **server container's** ephemeral
filesystem. `pg_dump` cannot see it and `mc mirror` cannot see it. In-flight
resumable uploads do not survive a backup/restore cycle, and nothing says so.
(The single profile differs: its `FilesystemArtifactStore` stages under
`/data/staging`, inside the backed-up volume.)

## S-5 — PASS: the dirty-volume wipe works on both halves

Negative control, so the check could fail: stack B was dirtied with state no
backup contains — a `STALE-APP-MUST-VANISH` app with a release and a `verified`
artifact, plus a bucket object at `release/999/stale-orphan`. Restoring a
matched pair removed all of it.

```
before: apps=2   objects=48
after:  apps=1   objects=46      (pair1's mirror holds exactly 46)
stale app -> (gone)   stale-orphan -> (gone)
```

`pg_restore --clean --if-exists` wipes the tables it recreates; `mc mirror
--remove` prunes objects absent from the snapshot. Both directions verified.

Not covered by this control: a table present in the target but absent from the
dump is not dropped, so restoring an older dump onto a newer schema leaves the
newer tables populated.

## Adjacent, NOT a backup defect — recorded so it is not mistaken for one

`GET /apps/{id}/releases/{id}/artifacts` returns `pending` artifacts with a
signed download URL that 404s. That is true of a live server with an
interrupted upload, not something backup/restore introduces. It is why the
first version of this analysis mistook a faithful capture for damage.
