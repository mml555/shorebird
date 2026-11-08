# Control-plane rig state: the authoritative locations

```
~/shorebird-rig/
  control-plane/<name>/   data: app ids, releases, patches, artifacts
  config/<name>.env       non-secret: PORT, DATA_DIR, HOST_BIND, ...   0644
  secrets/<name>.env      API_KEY, URL_SIGNING_SECRET                  0600
```

`<name>` is `cps-ios` (:18080) or `cps-android` (:18081). Override the roots
with `CONTROL_PLANE_ROOT`, `RIG_CONFIG_DIR`, `RIG_SECRETS_DIR`. Nothing here is
in the repo — it is rig state, not source — but the *paths* are documented so
they stop being folklore.

## The ownership direction

Containers are built **from** these files. They are never rebuilt by reading
state back out of the container being replaced:

```
durable config + durable secrets + durable data  ->  container
```

[`scripts/lib/rig_container.sh`](../scripts/lib/rig_container.sh) is the only
thing that creates them. `rig_preflight` proves every input exists — secrets
file present, mode 0600, owned by you, required keys non-empty; config present;
data root present and not in a scratch tree — and `rig_recreate` calls it
**before** `docker rm`, so a missing or malformed input costs you nothing.

Verified: with the secrets file absent, or present at mode 0644, the recreate
refuses and the existing container survives.

Why it matters: `API_KEY` authenticates every CLI call and
`URL_SIGNING_SECRET` signs artifact download URLs. When those lived only in
container config, a `docker rm -f` followed by a failed `docker run` destroyed
them — see the note at the end of this file.

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

Back up **all three** roots — data alone will not rebuild a rig.

```bash
# stop first for a consistent SQLite snapshot
docker stop cps-ios cps-android
tar -C ~/shorebird-rig -czf shorebird-rig-$(date +%F).tgz \
    control-plane config secrets
docker start cps-ios cps-android
# the archive contains 0600 secrets — store it somewhere you would keep a
# private key, and never in the repo
chmod 600 shorebird-rig-$(date +%F).tgz

# restore
docker stop cps-ios cps-android 2>/dev/null || true
tar -C ~/shorebird-rig -xzf shorebird-rig-<date>.tgz
# recreate from the restored inputs rather than starting a stale container
selfhost/scripts/prepare_ios_endpoint.sh --mode lan --force
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
  env-file, which had not been cleaned up yet. The expansion is now guarded —
  and more importantly the premise is gone: credentials live in
  `secrets/<name>.env`, and `rig_recreate` validates them before destroying
  anything, so the container is no longer the authoritative copy of anything.
- **A live server keeps writing.** `code_push.db` will not match a hash taken
  before the move; the meaningful check is that the *copy* was byte-identical
  at copy time and the app records survive. After the move: cps-ios 6 apps,
  cps-android 2 apps, both answering 200.
