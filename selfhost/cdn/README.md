# Self-hosted Shorebird build-time CDN

Removes the last build-time dependency on Shorebird-operated infrastructure
(`download.shorebird.dev` and the Google Cloud Storage bucket behind it). Runtime
code-push is already self-hosted; this covers the artifacts the CLI + vended
Flutter tool fetch while **building** releases and patches.

Read `../CDN_INDEPENDENCE.md` first — it explains the two artifact flows, which
knobs are hardcoded vs env-overridable, and the exact minimal source diff. This
README is the operational how-to.

## What runs

| Service | Role |
|---------|------|
| `artifact-proxy` | The first-party `packages/artifact_proxy` (unmodified). Routes Flutter engine artifact paths to the stock-Flutter or Shorebird-modified copy and 302s to GCS. Same code as `download.shorebird.dev`. |
| `cdn-cache` (nginx) | Caching reverse proxy in front of `artifact-proxy` and `storage.googleapis.com`. Rewrites the proxy's 302s back through itself and caches the real bytes. After one warm build, artifacts are served from local disk. |

Listens on host port **8081** (8080 is left for `code_push_server`).

## Start it

```bash
docker compose -f selfhost/cdn/docker-compose.cdn.yaml up --build
```

## Point the CLI at it

The two source patches (`cache.dart` + `shorebird_process.dart`) that make the
hardcoded URLs honor env vars are **applied in this repo** (see
`CDN_INDEPENDENCE.md` §6). They are backward-compatible — with no env vars set,
the CLI behaves exactly as before (fetches from `download.shorebird.dev`).

**Activation requires a CLI built from the patched source.** The installed CLI
(`~/.shorebird`) runs a compiled snapshot, so apply the patch there and rebuild:

```bash
# ~/.shorebird is a git checkout; copy the two patched files over and rebuild
cp packages/shorebird_cli/lib/src/{cache,shorebird_process}.dart \
   ~/.shorebird/packages/shorebird_cli/lib/src/
rm -f ~/.shorebird/bin/cache/shorebird.snapshot ~/.shorebird/bin/cache/shorebird.stamp
shorebird --version   # recompiles the snapshot from patched source
# revert later with: (cd ~/.shorebird && git checkout packages/shorebird_cli) && rm bin/cache/shorebird.snapshot
```

Then export the mirror env vars (host port is **8085** in this setup):

```bash
export FLUTTER_STORAGE_BASE_URL=http://localhost:8085   # Flow A: Flutter engine
export SHOREBIRD_STORAGE_BASE_URL=http://localhost:8085 # Flow B: shorebird CLI cache
export SHOREBIRD_STORAGE_BUCKET=download.shorebird.dev
shorebird release android   # or patch — pulls through the mirror
```

**Verified (Flow B):** with the above, `shorebird patch android` fetched
`patch-darwin-arm64.zip` and `aot-tools.dill` from the mirror
(`cache=MISS`→GCS on first build, `cache=HIT`→local disk thereafter), with no
`download.shorebird.dev` contact. `bundletool.jar` comes from GitHub (not
Shorebird), so it never touches the mirror. Flow A (engine) rides the same nginx
+ `artifact_proxy` and warms on the next fresh engine revision (`flutter
precache` / first release on a new engine).

## Warm the cache

```bash
shorebird release android      # first run pulls artifacts through the cache
```

Watch `cache=MISS` become `cache=HIT` in the `cdn-cache` logs:

```bash
docker compose -f selfhost/cdn/docker-compose.cdn.yaml logs -f cdn-cache
```

Once warm, the same engine revision builds without touching
`download.shorebird.dev` or GCS. Host the cache centrally to warm it once for a
whole team.

## Notes / caveats

- Artifacts are immutable per engine revision (the revision hash is in the path),
  so they cache effectively forever; re-warm only when adopting a new engine.
- Budget ~5–10 GB per engine revision. The compose volume caps at 20 GB
  (`max_size=20g` in `nginx.conf`) — raise it to hold more revisions.
- If a Flutter version issues HTTP range requests for large artifacts, enable
  nginx's `slice` module; the first full fetch otherwise populates the cache.
- `artifact-proxy` itself still reaches Shorebird's GCS bucket for the per-
  revision `artifacts_manifest.yaml`; the nginx cache captures that object on
  first fetch too, so it is covered by the same warm-up.
