# UPGRADE-ROLLBACK-1 — findings

Question: *can an operator upgrade a populated control plane through schema
migration, prove the existing system still works, and recover to the exact
pre-upgrade state when the new schema is deliberately incompatible with the old
binary?*

Certified on **both** persistence backends. The repository surface is shared,
but the engines are not, and the two questions this lane turns on — what a
failed migration leaves behind, and what a restore actually removes — are
answered by the engine, not by the Dart code.

Rig: throwaway deployments seeded with the same representative state as
BACKUP-RESTORE-1. Old = `ghcr.io/mml555/code-push-server:1.2.0` (schema 7),
new = an image built from this checkout (schema 12), so the upgrade runs five
real migrations: a new `crash_reports` table plus column additions to `events`
and `audit_log`.

## U-0 — image tags are not a statement about the code inside them

The git tag `code_push_server-v1.3.0` carries a source tree whose highest
migration is **8**. The published image `:1.3.0` applies migrations up to
**12**: it was rebuilt from newer source and re-tagged. Measured by booting each
published tag against a throwaway volume and reading the migrations it applied:

```
ghcr.io/mml555/code-push-server:1.1.0   schema 4
ghcr.io/mml555/code-push-server:1.2.0   schema 7
ghcr.io/mml555/code-push-server:1.3.0   schema 12   (its git tag says 8)
```

This matters here because the rollback contract is "restore onto the image the
backup came from". A tag cannot carry that meaning on its own, so the backup
manifest records the **digest** as well as the reference.

## U-1 — DEFECT (fixed): an old binary silently serves a newer schema

The migration loop skips versions it does not recognise. It had no notion of a
version *above* what it implements, so an old binary met a migrated database and
simply carried on.

Measured, old binary against a database a newer release had migrated:

| probe | result |
|---|---|
| `/healthz` | **200** |
| `/readyz` | **200** |
| `GET /apps` | 200 |
| `GET /apps/{id}/releases` | 200 |
| `POST /api/v1/patches/check` | **500** |

An orchestrator sees a ready server. Every device sees a broken one. Reads on
tables the newer schema did not touch keep working, which is what makes it
survive a smoke test.

**Fixed**: `Repository._migrate` now compares the highest applied version with
the highest this binary implements and throws `SchemaTooNewException`;
`bin/server.dart` turns that into a FATAL and `exit 65` (EX_DATAERR):

```
FATAL: database schema is at version 13 but this server implements only up to
12. It has been migrated by a newer release. Start that release, or restore the
backup taken before the upgrade with the image you are rolling back to.
```

Falsified: the same certification against the pre-guard binary fails exactly the
three checks the guard adds — `it does not serve (want '000', got '200')`,
`exit code (want 65, got 0)`, and no FATAL. Unit-tested in
`test/schema_guard_test.dart`, which also fails when the throw is removed and
keeps a control proving ordinary startup still works.

## U-2 — DEFECT (fixed): a rollback with the wrong image silently re-upgrades

Restoring the pre-upgrade backup while the successor image was still selected
printed `✓ Restored`, came up healthy — and had already migrated the restored
database straight back to the schema the operator was rolling back *from*:

```
schema after the "rollback": 1..12      (the backup holds 1..7)
```

Nothing distinguished that from a rollback that worked.

**Fixed**: the backup manifest records `server_image` and `server_image_id`, and
restore refuses a mismatch on both profiles, naming both sides and the
consequence. `--allow-image-change` (single) / `ALLOW_IMAGE_CHANGE=1` (scale)
covers the deliberate case of restoring into a different version. A backup taken
before this change carries no image and is not refused, so older archives still
restore.

## U-2b — DEFECT (fixed): the digest was recorded and not enforced

The first repair recorded `server_image` **and** `server_image_id`, and the
supported-state record said `image_identity: digest`. Both restore paths
compared only the reference string. The record claimed something the code did
not do.

That gap is not hypothetical here, because U-0 is the counterexample: this
project has already published an image whose tag misdescribes its code. A tag
is mutable, so:

```
backup taken under  :1.3.0 @ digest A
:1.3.0 later republished over digest B
restore sees "1.3.0 == 1.3.0"  ->  ACCEPTED
```

Measured against `8e64536b` with one reference over two builds:

```
✓ Restored          exit 0
schema before 12  ->  schema after 13
```

The operator asked to roll back and got a database migrated to a schema the
backup had never seen.

**Fixed**: both profiles now resolve the selected image to the set of
identities it answers to (its repo digests and its own id) and require the
manifest's `server_image_id` to be one of them. An image that cannot be
resolved to any identity is refused rather than falling back to the tag —
falling back is what made the guarantee hollow in the first place. A manifest
with no recorded identity keeps the documented tag-only behaviour so older
archives still restore.

Falsified: against `8e64536b` the same control reports `restoring under the
same tag but a DIFFERENT build was accepted` on both backends.

## U-3 — DEFECT (fixed): the scale rollback left the newer schema behind

`pg_restore --clean` drops only the objects the dump mentions. Anything a newer
schema *added* is invisible to it. Rolling a scale stack back from schema 12 to
7 left the `crash_reports` table that migration 8 had created, because the
schema-7 dump had never heard of it — so a rollback was exact on the single
profile (which replaces the whole volume) and not on scale.

**Fixed**: `ops/restore.sh` resets the schema before restoring. This is safe
here and nowhere else in that script: the dump's sha256 has already been
verified against its manifest, so a good copy is known to exist before anything
is dropped. Re-measured: `crash_reports` gone, inventory identical to baseline.

## U-4 — MEASURED, and it decides the recovery contract

A migration that starts and then fails, on both engines:

| | SQLite | Postgres |
|---|---|---|
| partial DDL survives? | **no** | **no** |
| failing version recorded? | no | no |
| server serves afterwards? | **no** — exit 255, `/healthz` and `/readyz` unreachable | **no** — exit 255, same |

So the failing migration itself is atomic on both, and readiness cannot report
healthy after a failed upgrade because the process never reaches the server
loop.

**But the upgrade is not atomic.** Each migration commits in its own
transaction, so a failure at version 13 leaves versions 8–12 already committed.
Measured on both backends, starting from schema 7:

```
schema AFTER the failed upgrade: 12      (not 7)
```

Two consequences, and they are the reason this arm exists:

1. **Putting the old image back is not recovery.** It happened to work here
   only because migrations 8–12 are additive; the old binary read a schema-12
   database and answered 200. With any non-additive migration in that range it
   would have been U-1 all over again, and an image predating the guard cannot
   refuse.
2. **"Retry the migration" is only safe if the cause was external.** Nothing
   partial survives, so a retry is not corrupting — but if the cause is the new
   release itself, retrying just fails again against a database that has already
   moved.

The supported contract is therefore, and is now certified as:

> failed upgrade → stop the candidate → old image + pre-upgrade certified backup

## U-5 — PASS: the forward migration preserves everything

Zero baseline rows and zero objects lost, on both backends. The only difference
between the pre- and post-upgrade inventories is the new, empty table:

```
10a11
> count crash_reports 0
```

Old artifacts still download byte-exact through the device path after the
migration, and a new patch → upload → promote → device download succeeds.

Comparing inventories across schema versions needed the instrument to change:
`br1_inventory.sh` now projects only the columns a database actually has,
records the projection it used, and can be pinned to an earlier inventory's
projection so a difference in the diff is a difference in the data rather than
in the schema. On a full schema its output is byte-identical to the previous
version, so BACKUP-RESTORE-1's results are unaffected — verified by running both
versions against the same database.

## Fixtures

The break in U-1 has to be manufactured: every migration this project ships is
additive, so an old binary survives them by accident and a rollback test would
pass for the wrong reason. Two scratch successors do it, applied to a **copy** of
the package so the permanent migration history stays clean:

* `fixtures/incompatible_successor.py` renames `channel_patches.rollout`, which
  the device patch-check reads and promote writes.
* `fixtures/failing_migration.py` adds a column and then fails on a missing
  table.

The first fixture's completeness is not self-evident: renaming the column in SQL
left a `SELECT *` row mapper still reading the old key, and the successor 500'd
on its own device path. A negative built on a broken successor proves nothing,
so the certification requires the successor to serve its own device path before
any refusal below it is believed.
