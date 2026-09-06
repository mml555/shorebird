# BACKUP-RESTORE-1 · what a backup is, and what it is not

**These scripts produce a control-plane data backup. They do not produce
complete disaster recovery.** Everything below distinguishes the two, and every
row is a measurement against a running stack, not a reading of the code.

## The claim, stated precisely

A backup produced by `setup.sh --backup` (single) or `ops/backup.sh` (scale),
restored by its matching restore command into a stack of the same profile and
image, reproduces:

* every app, release, patch, artifact row, channel, promotion, collaborator,
  organization, user, invitation, setting and audit record;
* every artifact object, byte for byte;
* a deployment that keeps working — new patch, upload, promote, and a device
  download that matches the uploaded bytes.

It does **not** reproduce the deployment. Bringing a stack up around the data is
the operator's job, and the table at the end of this file is the list.

## The backup file is a credential store

`api_keys.key` stores the **plaintext API key**, not a digest
(`repository.dart:742` inserts the key itself). Both profiles. Anyone holding a
backup holds working credentials for every account in it.

Measured consequence — rotating the deployment's own `API_KEY` does **not**
close that door:

```
after rotating API_KEY in .env and recreating the server:
  old bootstrap key            -> HTTP 403     (rotation took effect)
  new bootstrap key            -> HTTP 200
  a DB-stored collaborator key -> HTTP 200     ← still works
```

The bootstrap `API_KEY` is an environment credential checked directly by the
server (`config.bootstrapApiKey`); the per-user keys live in the database and
came from the backup. **If a backup is exposed, rotating `API_KEY` is not
enough — the rows in `api_keys` have to be revoked as well.**

Store backups encrypted, wherever you store passwords.

## Classification

### Must be restored unchanged, or something breaks

| item | measured effect of changing it |
|---|---|
| `URL_SIGNING_SECRET` | every already-issued download URL stops working. Measured: a URL issued under the old secret returned 200, returned **403** after rotation, and a re-issued URL returned 200. Devices recover on their next `patches/check`; anything holding a URL does not. |
| `PUBLIC_BASE_URL` / `SHOREBIRD_JWT_ISSUER` | baked into the download URLs the server hands devices and into JWT issuance. Changing it points devices somewhere else. |
| the image the backup was taken under | **enforced, not advice.** The manifest records `server_image` and `server_image_id`, and restore enforces the **digest**, not the tag — one reference republished over a different build is refused. A mismatch means: restoring a pre-upgrade backup with the successor still selected does not roll anything back, it migrates the restored database straight forward again. Pass `--allow-image-change` (single) / `ALLOW_IMAGE_CHANGE=1` (scale) for the deliberate case. Certified by UPGRADE-ROLLBACK-1. |

### May be rotated safely

| item | why |
|---|---|
| `API_KEY` (the bootstrap key) | env-only, not in the database. Measured above: old rejected, new accepted, all data intact. CLI configs holding the old value must be updated. |
| `POSTGRES_PASSWORD`, `MINIO_ROOT_*`, `S3_ACCESS_KEY`/`S3_SECRET_KEY` | infrastructure credentials; the data does not reference them. Change them in `.env` and in the store together. |
| TLS material | Caddy reissues on a reachable domain. A private CA is not reconstructible and belongs in the row below. |

### External prerequisites — not in the backup, required before restoring

| item | note |
|---|---|
| `.env` | the stack will not boot without `API_KEY` and `URL_SIGNING_SECRET`; both are `:?` required. Back it up **separately and encrypted** — putting it in the data backup would merely move the secret, not protect it. |
| the container image tag | `ghcr.io/mml555/code-push-server:<tag>` |
| Docker, volumes, compose files, host, DNS, firewall | described by the compose files, captured by none of them |
| a private CA, if you use one | Caddy's own CA store is not in either profile's backup |

### Reconstructible — deliberately not preserved

| item | consequence |
|---|---|
| `refresh_tokens`, `auth_codes`, `idp_states` | console sessions end; users log in again |
| `rate_limits` | a cache; refills |
| in-flight resumable upload chunks | **scale**: staged in the server container's ephemeral filesystem (`S3ArtifactStore.open` → `Directory.systemTemp/cps_staging`), so in neither half. **single**: staged under `/data/staging`, inside the volume, so it *is* captured. Either way an interrupted upload is not resumable across a restore; the CLI re-uploads. |
| an artifact row left `pending` or `uploading` | a faithful record of an upload that was in flight. The row survives; the bytes never arrived. Harmless, but see the note below. |

## One adjacent thing worth knowing

`GET /apps/{id}/releases/{id}/artifacts` lists `pending` artifacts and hands out
a signed download URL for them, which 404s. That is equally true of a live
server after an interrupted upload — backup and restore do not cause it — but a
restored stack inherits any such rows, so it can look like restore damage when
it is not.
