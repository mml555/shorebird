# BACKUP-RESTORE-1 · Gate A — the single (default) profile, script as written

Subject, unmodified: `packages/code_push_server/setup.sh --backup` /
`--restore`. Rig: the default single-container deployment
(`ghcr.io/mml555/code-push-server:1.3.0`, SQLite + filesystem artifacts in one
`/data` volume) on `127.0.0.1:18092`, seeded through the ordinary HTTP API.

Scoring uses the same predicate as Gate B (`br1_tear_check.sh`): only states the
live system can never occupy count as damage. A `pending` row with no object is
a faithful capture of an in-flight upload, not a tear.

## A-0 — PASS: the intended path is correct, and exactly correct

The single profile has one structural advantage over the scale pair that no
amount of care can give the latter: **there is only one archive**, so the two
halves cannot be crossed or skewed. And `--backup` genuinely quiesces —
`compose stop server`, tar, `compose start server`.

Measured, with real writes in flight throughout:

```
23:40:16.789Z  200            ← writes succeeding
23:40:19.001Z  connection refused (15 consecutive)
23:40:19.789Z  200            ← writes succeeding again
```

The deployment is **down** for the whole snapshot. Five backups under a live
two-phase artifact writer: **TEARS=0 in 5/5.**

Restore correctness, measured as a full inventory diff (every row of every
state-bearing table, projected explicitly and hashed; every object with its
sha256):

```
inv0 (before)  2229 lines, 302 objects
inv1 (after)   2229 lines, 302 objects
diff           IDENTICAL
```

And the restored deployment is *functional*, not merely readable — new patch →
artifact upload → promote → device `patches/check` → download:

```
patch_available=True  number=2   download -> HTTP 200
sha of downloaded bytes  b154b5400c9b0043028d9e6bd25288706893ead789a881f48840c15396ddb1d4
expected                 b154b5400c9b0043028d9e6bd25288706893ead789a881f48840c15396ddb1d4
```

Dirty-volume wipe, with a negative control so it could fail: a stale app with a
`verified` artifact, a stray `/data/STRAY-MUST-VANISH.txt`, and a stray object
at `artifacts/release/99999/stray-object`. After restore: **all three gone**,
inventory identical to inv0.

Everything below is about how easily that correct path is left.

## A-1 — DEFECT: the quiescing is best-effort and cannot be distinguished from
## having happened

```sh
"${COMPOSE[@]}" stop server >/dev/null 2>&1 || true
```

Output discarded, exit status discarded. If the stop is a no-op the tar runs
against a live, writable volume and the script prints the same `✓ Wrote
backups/… Copy it off-host.`

Falsified by running `setup.sh --backup` from a *different* compose project
directory. The server never went down — **94/94 requests answered 200 across
the whole backup** — and the script reported success as usual.

Five such unquiesced backups under the same writer used in A-0:

```
unquiesced run 1:  TEARS=0
unquiesced run 2:  TEARS=2   (T2=2: object present, row still `pending`)
unquiesced run 3:  TEARS=0
unquiesced run 4:  TEARS=0
unquiesced run 5:  TEARS=0
quiesced   1..5 :  TEARS=0 in all five
```

1/5 versus 0/5, same instrument in both arms. The quiescing is what prevents
the tear, and it is protected by nothing.

## A-2 — DEFECT, most severe in the lane: the target volume is guessed
## host-wide, and a restore can destroy a different deployment

```sh
docker volume ls -q | grep -E 'cps_data$' | head -1
```

When `docker compose ps -q server` finds nothing, both `--backup` and
`--restore` fall back to *any* volume on the host whose name ends `cps_data`,
first one wins. `--restore` adds a looser fallback still
(`$(basename $PWD)_cps_data`).

Measured. From `/Volumes/build/br1/single2`, a directory with **no deployment
of its own**:

```
before:  the `single` deployment is live, healthy, 1 app
run:     setup.sh --restore ./wrong.tgz
         ==> Restoring …/wrong.tgz into single_cps_data (DESTRUCTIVE, brief pause)…
after:   single_cps_data now contains:  artifacts marker.txt staging
```

A restore invoked in one directory wiped a different, live, healthy
deployment's data. The message names `single_cps_data`, but nothing tells the
operator that is not the deployment they meant.

## A-3 — DEFECT: the archive is destroyed-into, never validated first

```sh
sh -c "rm -rf /data/* /data/..?* 2>/dev/null; tar xzf /backup/<file> -C /data"
```

The wipe happens **before** anything reads the archive. Restoring a truncated
backup therefore destroys the data the operator still had:

```
tar: unexpected end of file
tar: short read
script exit=1                         ← it does fail loudly, which is something
volume after: 303 artifact rows, 4 objects on disk   → TEARS=298 (all T3)
server: left stopped (set -e aborts before `compose up -d`)
```

The failure is loud, but it arrives after the only good copy is gone. There is
no verify-then-swap and no staging directory.

## A-4 — DEFECT: a well-formed but incomplete archive restores GREEN and loses
## everything, silently

An archive containing `artifacts/` and `staging/` but no `code_push.db`
(repacked inside a container so ownership matches, ruling out a permissions
confound that muddied the first attempt at this test):

```
script exit=0
✓ Restored. Server restarting.
health 200            ← healthy
apps=0 releases=0 artifacts=0 audit=0
artifact objects still on disk: 302
```

Exit 0, a green checkmark, a healthy server, and **every app, release, patch,
user, collaborator, channel, promotion and audit record gone**, with all 302
objects orphaned. The server simply created a fresh empty database. Nothing —
not the script, not the health check, not the API — reports a problem.

This is the worst kind of failure for a restore: the operator has no signal.

## A-5 — DEFECT: a single missing object restores green and breaks devices

An archive with the DB intact and exactly one artifact object removed:

```
script exit=0, health 200
TEARS=1  (T3=1: patch/1/2ee9d6f1e28c37dfcf0fdb5560ebe351 verified, absent)
```

User-visible on the device update path, not merely internal:

```
POST /api/v1/patches/check  ->  {"patch_available":true, "download_url": …}   HTTP 200
GET  <that download_url>    ->  HTTP 404
```

Every device on `stable` for that release asks for a patch the server has
advertised and cannot deliver.

## A-6 — the archive is credential-bearing, by schema

`api_keys.key` stores the **plaintext API key** (`repository.dart:742` inserts
the key itself, not a digest). Both profiles. So the backup file is a secret at
rest: anyone holding a `cps-backup-*.tgz` holds working credentials for the
deployment, and `API_KEY` authenticates as an owner of the root org.

Nothing was added to the backup to make a test pass — this is what the schema
already stores. It belongs in the secrets-boundary classification, and the
"Copy it off-host" advice the script prints needs to say *where*.

## Harness note, so it is not mistaken for a product defect

The first attempt at A-4 used an archive repacked on macOS. It carried
AppleDouble `._` members and extracted as `501:staff` rather than `10001:999`,
and the server crash-looped on `unable to open database file (code 14)` — a
permissions failure, not the missing database. Rebuilding the archive inside a
container removed the confound and produced the far worse result recorded
above. A backup repacked by an operator outside a container will hit the same
ownership problem.
