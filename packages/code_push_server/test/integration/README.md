# Integration tests

The unit tests under `test/` run with no external dependencies and are what
CI executes via `dart test`. The **integration** flow exercises the full HTTP
server against a live Postgres + S3 (MinIO) stack, and is therefore **opt-in**:
it is skipped unless you explicitly enable it.

## What it covers

The canonical end-to-end flow is scripted in [`tool/smoke_test.sh`](../../tool/smoke_test.sh),
which drives the complete CLI + device wire sequence with `curl`:

- create app / release
- fail-closed finalize before artifacts are verified (expects `409`)
- register + upload a release artifact with a real sha256 (expects `204`)
- reject a hash mismatch (expects `400`)
- finalize the release
- fail-closed promote before the patch is `ready` (expects `409`)
- upload a patch artifact, mark it ready, promote it (expects `204`)
- device `patches/check` offers the patch (`patch_available: true`)
- ranged download returns `206` + `Content-Range`
- rollback (withdraw + revert) reflected in the next check

`integration_test.dart` in this directory is a thin Dart wrapper tagged
`integration`. It is skipped unless `INTEGRATION=1` and the required env vars
are set, so `dart test` stays green in CI without a live stack.

## Required environment

| Variable          | Purpose                                              | Example                                   |
| ----------------- | ---------------------------------------------------- | ----------------------------------------- |
| `INTEGRATION`     | Opt-in switch; must be `1` to run                    | `1`                                       |
| `DATABASE_URL`    | Postgres connection string                           | `postgres://cps:cps@localhost:5432/cps`   |
| `S3_ENDPOINT`     | S3 / MinIO endpoint                                  | `http://localhost:19000`                  |
| `BASE_URL`        | Base URL of the running server (a.k.a. `BASE` below) | `http://localhost:8080`                   |
| `API_KEY`         | Bearer API key the server accepts                    | the value in your `.env`                  |

`S3_ACCESS_KEY`, `S3_SECRET_KEY`, and `S3_BUCKET` may also be set; they default
to `cps` / `cps-secret` / `code-push-artifacts`.

> **There is no zero-config path.** `API_KEY` and `URL_SIGNING_SECRET` are both
> published placeholders in this repository, so `Config.validate()` refuses to
> boot with either of them — in *every* mode, not just production. `docker
> compose up` fails on the `${API_KEY:?}` guard and `dart run bin/server.dart`
> exits `78`. Generate real values first; every command below assumes you have.

## Running the full flow

1. Generate secrets into `.env` (once):

   ```bash
   ./setup.sh
   ```

   Or, to stay out of Docker, export them yourself:

   ```bash
   export API_KEY="sb_api_$(openssl rand -hex 32)"
   export URL_SIGNING_SECRET="$(openssl rand -hex 32)"
   ```

2. Bring up Postgres + MinIO (see `docker-compose.yaml`):

   ```bash
   docker compose up -d
   ```

3. Start the server (skip if `setup.sh` already started the stack):

   ```bash
   dart run bin/server.dart &
   ```

4. Run the smoke test (the source of truth for the integration flow). With no
   `KEY` it reads `API_KEY` from `.env`:

   ```bash
   tool/smoke_test.sh
   # or point it at another host / key:
   BASE=http://localhost:8080 KEY="$API_KEY" tool/smoke_test.sh
   ```

5. Optionally run the Dart wrapper (opt-in):

   ```bash
   INTEGRATION=1 \
   DATABASE_URL=postgres://cps:cps@localhost:5432/cps \
   S3_ENDPOINT=http://localhost:19000 \
   BASE_URL=http://localhost:8080 \
   API_KEY="$API_KEY" \
   dart test --tags integration
   ```

By default (`dart test`) the integration test is excluded via its
`@Tags(['integration'])` annotation combined with the `INTEGRATION` guard, so
it never blocks the unit suite.
