# Publish durability on code push server 1.4.0 (2026-11-10)

Question: can the server accept a publish (200/204) and not keep it? Measured by
publishing through the API and reading the **database file and the stored bytes**
back, never the API or the CLI's output.

Image `ghcr.io/mml555/code-push-server:1.4.0`, one scratch container per run on
ci-build, with its own volume or bind mount. `cps-ios` was not touched.

- `drive.py` runs the CLI's call sequence per release: create release, register
  and upload the `aab` and `aarch64` artifacts, activate, then create patch,
  register and upload its artifact, promote to `stable`. It records every operation
  the server acknowledged (2xx) and reads nothing back.
- `verify.py` opens a `docker cp` of `/data` read-only and checks that every
  acknowledged release or patch creation exists, each fully published release is
  `ready` with `verified` artifacts whose stored sha256 matches, each patch is
  `ready`, each promote has a `channel_patches` row for that patch and the channel
  promoted to, and ids are dense in `releases`, `patches` and `artifacts`. It exits 1
  on any failure.
- `lib.sh` (sourced by `run.sh`, `kill.sh`, `pause.sh`) validates the run name
  (`^[a-z0-9-]+$`), refuses port 8090 (`cps-ios`) and any port in use, removes that
  run's own container and `vanish-repro-<name>-data` volume by exact name, and waits
  on its own container. `cleanup.sh <name>` removes a finished run.

To rerun: create `~/vanish-repro` on ci-build, copy this directory into it, then
`bash run.sh NAME PORT plain|interrupt|resumable PER WORKERS [BIND_SUBDIR]`,
`bash kill.sh NAME PORT SECONDS KILLS` or `bash pause.sh NAME PORT`. The 2026-11-10
runs used: a = 3 releases per worker, 2 workers; b1 = `plain 10 16`; c1 =
`interrupt 10 8 bind-c1`; d1 = `resumable 10 8`; e1 = `kill.sh e1 PORT 12 3`;
f1 = `pause.sh f1 PORT`. They ran on the earlier, looser versions of these scripts
and an earlier verify.py (it did not check patch status, the promoted channel or
dense ids, and exited 0 on a miss). The numbers below come from that
verify.py's missing-count; with the checks added here, re-run before relying on
them. The run itself was not repeated.

The CLI itself was not run: `shorebird release` needs a Flutter build. The driver
sends the same calls, but they were not compared against captured CLI traffic, and
the CLI's retry and error handling is not exercised.

**Not covered:** the iOS flow (only `android` with `aab` and `aarch64`); anything
time-driven (each run lasted minutes and was read back at once, so the 15-minute
upload reclaim and retention sweeps were not seen, nor a restart hours later);
large artifacts (releases 1 to 200 KB, patches 0.5 to 50 KB); host power loss
(only SIGKILL and `docker pause`; the copy was read from the live page cache and
WAL); the read path (nothing was read back through the API, where the original
vanish was seen, so a bug that hides rows from the list API would not show);
same-version retry publishes (versions were unique); user-OAuth (the API key was
used); a proxy; Postgres and S3; an upgrade from an older database. Only fully
completed sequences were recorded in the 2026-11-10 runs, so a create that was
acknowledged and then lost after a later client-side failure was not checked; the
driver now records every acknowledged create.

| Run | Conditions | Acknowledged releases / patches / promotes | Missing |
|---|---|---|---|
| a | 2 workers, named volume | 6 / 6 / 6 | 0 |
| b1 | 16 concurrent workers, named volume | 160 / 160 / 160 | 0 |
| c1 | 8 workers, bind mount, 40% of multipart uploads aborted halfway then retried | 80 / 80 / 80 | 0 |
| d1 | 8 workers, resumable uploads (`UPLOAD_METHOD=resumable`, 3 chunks) | 80 / 80 / 80 | 0 |
| e1 | 8 workers, aborted uploads, `docker kill` (SIGKILL) and restart 3 times mid-run, final SIGKILL before reading | 73 / 71 / 71 | 0 |
| f1 | 8 workers, container at 0.3 CPU and 256 MB, paused 3 s out of every 5 s | 48 / 48 / 48 | 0 |

Total 447 releases, 445 patches and 445 promotes acknowledged, none missing from
the database or from storage. The server log was checked for 5xx and unhandled
errors only in runs b1, c1 and d1 (none); a, e1 and f1 were not checked, and the
driver retries 5xx itself, so the client output does not show them either.
`max(releases.id) = count(*)` held in every run.

Run e1 left 9 uploads unfinished: a request killed mid-commit leaves the artifact
`uploading`, and the retry gets 409 until `Api.uploadClaimTimeout` (15 minutes,
fork #96) reclaims it. Those publishes were not acknowledged, so they are not
vanished publishes, and the CLI reports them as failures.
