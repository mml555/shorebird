# UPGRADE-ROLLBACK-1 — certification

| backend | harness | verdict |
|---|---|---|
| **SQLite** (single profile) | `ur1_certify.sh` PROFILE=single | **CERTIFIED** — 32 passed, 0 failed |
| **Postgres** (scale profile) | `ur1_certify.sh` PROFILE=scale | **CERTIFIED** — 32 passed, 0 failed |

Both backends are certified independently. The repository surface is shared but
the engines are not, and this lane's two decisive questions — what a failed
migration leaves behind, and what a restore actually removes — are answered by
the engine.

## The certified sequence

```
old populated deployment (1.2.0, schema 7)
  -> certified pre-upgrade backup        the rollback boundary, image recorded
  -> upgrade to schema 12                five real migrations
  -> every pre-upgrade row and object intact; new patch/upload/promote/download
  -> a deliberately incompatible successor (schema 13)
  -> the previous binary REFUSES that schema (exit 65, FATAL, nothing served)
  -> wrong-image restore REFUSED; right-image restore succeeds
  -> state IDENTICAL to the pre-upgrade baseline
  -> mutate, then upgrade again
  -> a migration that starts and fails: nothing serves, no partial DDL,
     but the database is NOT where it started
  -> old image + pre-upgrade backup: exact recovery, and it accepts new work
```

## It discriminates

The same harness against the **pre-guard** binary fails exactly the checks the
guard adds, and fails them in the dangerous direction:

```
FAIL  it does not serve                       (want '000', got '200')
FAIL  it exits with the schema-mismatch code   (want '65',  got '0')
FAIL  no FATAL naming schema 13 vs 12
29 passed, 3 failed
```

A `200` there is the whole defect: an old binary answering health checks over a
schema it cannot serve.

## Reproducing

```bash
# build the successor and the two scratch fixtures first (see FINDINGS.md)
PROFILE=single DIR=<deployment dir> PORT=<port> KEY=<api key> \
OLD_IMAGE=ghcr.io/mml555/code-push-server:1.2.0 NEW_IMAGE=<built from HEAD> \
SCRATCH_IMAGE=<incompatible successor> FAIL_IMAGE=<failing migration> \
  selfhost/scripts/ur1_certify.sh
```

The harness resets the deployment to a clean old-schema state before it begins.
Run against whatever a rig happened to be left at, it measured a "12 -> 12
upgrade" and still reported the later steps as passes; the reset and the
`schema advanced` assertion together make that impossible.

## The documented claim, now measured

`SECRETS_BOUNDARY.md` said *"restore onto the image the backup came from, then
upgrade"*. That was guidance nothing enforced. It is now a contract the product
holds to: the backup records the image that produced it, restore refuses a
mismatch on both profiles, and the deliberate case has an explicit flag.

## Corrections made during the lane

1. **The first incompatible successor was itself broken.** Renaming the column
   in SQL left a `SELECT *` row mapper reading the old key, so the successor
   500'd on its own device path — a negative built on it would have proved
   nothing. The certification now requires the successor to serve its own
   device path before any refusal below it is believed, and the fixture's
   completeness scan looks for result-map keys as well as SQL text.
2. **The harness measured a 12 → 12 "upgrade".** It ran against whatever state
   the rig was left in. It now resets to a clean old-schema deployment and
   asserts the schema actually advanced.
3. **`health()` compared against the wrong literal.** `curl -w '%{http_code}'`
   prints `000` on a refused connection *and* exits non-zero, so a `|| echo 000`
   appended a second copy and every "is it down" check failed while the server
   was correctly down. The same mistake as in BACKUP-RESTORE-1's probe, made
   again in a new script.
4. **A correct refusal was reported as the wrong refusal.** Arm B of the
   BACKUP-RESTORE-1 harness began tripping this lane's new image check before
   reaching the quiescence guard it exists to test. Fixed by giving that arm an
   intact compose in a container-less project, so only the guard under test can
   fire — and the product now says "cannot tell which image this compose would
   start" instead of implying a mismatch.
