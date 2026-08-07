# Control-plane data: the authoritative location

```
~/shorebird-rig/control-plane/
  cps-ios/       app ids, releases, patches, artifacts for the iOS rig  (:18080)
  cps-android/   the same for the Android rig                           (:18081)
```

Override with `CONTROL_PLANE_ROOT`. Nothing here is in the repo — it is rig
state, not source — but the *path* is documented so it stops being folklore.

## Why this moved

Until 2026-08-07 both rigs bind-mounted `/data` from **per-session scratchpad
directories**:

```
cps-ios      .../b5a4ac4a-…/scratchpad/cps-data          927 MB
cps-android  .../e7ae16e6-…/scratchpad/cps-android-data  334 MB
```

Those belong to sessions that ended days earlier and are subject to cleanup.
They hold every app id, release, patch and artifact both rigs have produced.
This is the same ephemeral-state failure class that already cost the
2026-08-06 acceptance its reproducibility, when the fixture app's scratchpad
was cleaned and the run could no longer be repeated. A rig whose entire history
sits one cleanup away from gone is not a durable proof.

Moved by [`scripts/relocate_control_plane_data.sh`](../scripts/relocate_control_plane_data.sh)
— a **storage-ownership fix only**: no schema change, no database migration, no
control-plane redesign.

## The guard

`airgap_acceptance.sh` runs a `control-plane-durable` stage that **refuses** an
acceptance run when either container's `/data` resolves inside a
scratchpad/temp tree. Warning would not have been enough: the whole point is
that nobody notices ephemeral state until it disappears.

`AIRGAP_ALLOW_EPHEMERAL_DATA=1` overrides, deliberately awkwardly.

## Backup and restore

```bash
# back up (stop first for a consistent SQLite snapshot)
docker stop cps-ios cps-android
tar -C ~/shorebird-rig/control-plane -czf control-plane-$(date +%F).tgz .
docker start cps-ios cps-android

# restore
docker stop cps-ios cps-android
tar -C ~/shorebird-rig/control-plane -xzf control-plane-<date>.tgz
docker start cps-ios cps-android
```

Stopping first matters: a live SQLite file copied mid-write can land in a state
the server will not open.

## Moving it again

```bash
selfhost/scripts/relocate_control_plane_data.sh --dry-run
selfhost/scripts/relocate_control_plane_data.sh [--dest-root DIR] [--purge-source]
```

Idempotent — a container already under the destination root is left alone, and
one already outside a scratch tree is left alone unless `FORCE_RELOCATE=1`. The
source is renamed `.migrated-<date>` rather than deleted, so a bad move is
recoverable; `--purge-source` removes it only after verification passes.

Verification compares **content**, never disk usage: file counts, an
`rsync --checksum` pass, and a byte-for-byte `cmp` of every `*.db`. The first
attempt used `du -sk` and refused a perfectly good copy over a 4 KB
block-accounting difference between filesystems.

## Two things that bit during the move

- **`docker rm -f` runs before `docker run`.** A failure in between leaves the
  container *deleted*, and its env — including `API_KEY` and
  `URL_SIGNING_SECRET` — lives only in the container config. It happened:
  `"${arr[@]}"` on an EMPTY array aborts under `set -u` in bash 3.2 (macOS),
  right between the two. The secrets were recovered from the script's temp
  env-file, which had not been cleaned up yet. The expansion is now guarded,
  but the sharper lesson is that **the container config is the only copy of
  those secrets** — worth a backup of its own before any recreate.
- **A live server keeps writing.** `code_push.db` will not match a hash taken
  before the move; the meaningful check is that the *copy* was byte-identical
  at copy time and the app records survive. After the move: cps-ios 6 apps,
  cps-android 2 apps, both answering 200.
