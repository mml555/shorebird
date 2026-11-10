# Publish durability on code push server 1.4.0 (2026-11-10)

Question: can the server accept a publish (200/204) and not keep it? Measured by
publishing through the API and reading the **database file and the stored bytes**
back, never the API or the CLI's output.

Image `ghcr.io/mml555/code-push-server:1.4.0`, one scratch container per run on
ci-build, with its own volume or bind mount. `cps-ios` was not touched.

- `drive.py` runs the CLI's call sequence per release: create release, register
  and upload the `aab` and `aarch64` artifacts, activate, then create patch,
  register and upload its artifact, promote to `stable`. Every operation that
  returned success goes into a JSON file.
- `verify.py` copies nothing itself: it opens a `docker cp` of `/data` read-only
  and checks that each acknowledged release is `ready`, each acknowledged artifact
  is `verified` with a file whose sha256 matches, each patch exists and each
  promote has a `channel_patches` row.
- `run.sh`, `kill.sh`, `pause.sh` start the container, run the driver and verify.

The CLI itself was not run: `shorebird release` needs a Flutter build. The driver
sends the same requests, but the CLI's retry and error handling is not exercised.

| Run | Conditions | Acknowledged releases / patches / promotes | Missing |
|---|---|---|---|
| a | 2 workers, named volume | 6 / 6 / 6 | 0 |
| b1 | 16 concurrent workers, named volume | 160 / 160 / 160 | 0 |
| c1 | 8 workers, bind mount, 40% of multipart uploads aborted halfway then retried | 80 / 80 / 80 | 0 |
| d1 | 8 workers, resumable uploads (`UPLOAD_METHOD=resumable`, 3 chunks) | 80 / 80 / 80 | 0 |
| e1 | 8 workers, aborted uploads, `docker kill` (SIGKILL) and restart 3 times mid-run, final SIGKILL before reading | 73 / 71 / 71 | 0 |
| f1 | 8 workers, container at 0.3 CPU and 256 MB, paused 3 s out of every 5 s | 48 / 48 / 48 | 0 |

Total 447 releases, 445 patches and 445 promotes acknowledged, none missing from
the database or from storage. The server log showed no 5xx and no unhandled error
outside run e1. In every run `max(releases.id) = count(*)`, so no id was consumed
and lost.

Run e1 left 9 uploads unfinished: a request killed mid-commit leaves the artifact
`uploading`, and the retry gets 409 until `Api.uploadClaimTimeout` (15 minutes,
fork #96) reclaims it. Those publishes were not acknowledged, so they are not
vanished publishes, and the CLI reports them as failures.
