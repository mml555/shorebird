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
Shorebird), so it never touches the mirror.

**Verified (Flow A), engine `69f9831c`:** all 87 engine artifact paths that
`artifact_proxy` routes were requested through the mirror. 78 returned `200` and
cached (2.8 GB total); the other 9 are not published for this revision and
`404` — nginx caches a `404` for one minute only, so those legitimately re-MISS.
A second pass over the same 87 reported `X-Cache-Status: HIT` for all 78, i.e.
served from local disk with no upstream contact.

Those 87 paths are **not the whole story**: they are the archives the flutter tool
fetches, and warming them all still left the Gradle Maven artifacts
(`download.flutter.io/io/flutter/<abi>_release/*.jar`) cold. A real
`shorebird release android` is what pulls those, so treat "warm" as meaning *one
full release build has run through the mirror*, not *a list of URLs was fetched*.

> Flow A needed a fix to work at all. `proxy_redirect` rewrites
> `artifact_proxy`'s `https://storage.googleapis.com/...` 302 to `/gcs/...`, but
> nginx turns a relative `Location` back into an absolute one using its own **listen** port —
> emitting `http://<host>:8080/gcs/...` even when the caller reached the mirror
> on the published host port (8085). A client on the host followed that to the
> wrong port and nothing ever cached, which is why this flow had previously only
> been reasoned about rather than exercised. `absolute_redirect off` in
> `nginx.conf` keeps the `Location` relative so it resolves against whatever
> host:port the client actually used — published on 8085, in-network on 8080, or
> behind TLS on 443.

## Android: Gradle refuses a plain-HTTP mirror

Engine artifacts reach an Android build two different ways, and only one of them
tolerates `http://`:

- the **flutter tool** downloads `flutter_infra_release/...` archives over plain
  HTTP happily (this is what `precache` and the release build's Dart/engine
  fetches use);
- **Gradle** resolves `download.flutter.io/io/flutter/<abi>_release/...jar` as
  Maven dependencies, and Gradle rejects any `http://` repository:

  ```
  Execution failed for task ':app:mergeReleaseAssets'.
  > Could not resolve all dependencies for configuration ':app:releaseRuntimeClasspath'.
     > Using insecure protocols with repositories, without explicit opt-in, is unsupported.
  ```

Flutter's Gradle plugin declares that repo as
`repositories.maven { url = uri("$FLUTTER_STORAGE_BASE_URL/${engineRealm}download.flutter.io") }`
with **no** `isAllowInsecureProtocol` support (`FlutterPlugin.kt`), so there is no
env var or flag that fixes this — the opt-in has to come from the app's own Gradle
config. Either serve the mirror over HTTPS, or add this to the app's
`android/build.gradle.kts`:

```kotlin
allprojects {
    repositories.all {
        if (this is MavenArtifactRepository && url.scheme == "http") {
            isAllowInsecureProtocol = true
        }
    }
}
```

`repositories.all` is a live collection, so it catches the repository Flutter adds
later during plugin application; only `http://` repos are touched. With that in
place a full `shorebird release android` completes with every engine artifact
served by the mirror. **Serving the mirror over HTTPS is the better answer for
anything beyond a local test** — it needs no per-app change and keeps the opt-in
from being copy-pasted into production apps.

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

## Serving a locally built (experimental) engine

The mirror doubles as the store for engines **we** build (see
`selfhost/ENGINE_BUILD.md` and `selfhost/engine/`). An experimental engine gets
its own 40-hex hash so it can never be mistaken for, or overwrite, the supported
pin — but only the Android arm64 binaries actually differ from that pin, and the
macOS/Windows host `gen_snapshot` cannot even be built on a Linux host. So the
mirror serves a *mixed* set:

| Request for an experimental hash | Result |
|---|---|
| present in `overlay/` | served from local disk (`X-Overlay: hit`) |
| **owned** by the overlay but absent | **404**, never stock bytes |
| anything else | hash rewritten to the pinned revision, served as usual |

"Owned" = the artifacts a build is required to produce itself, listed in the
`$overlay_owned` map in `nginx.conf`: `android-arm64-release/{artifacts,symbols,
linux-x64}.zip` and the `arm64_v8a_release` Maven artifacts. That 404 is the
point — a half-published experiment must fail loudly rather than quietly run
Shorebird's stock engine under your hash. `android-arm64-release/{darwin-x64,
windows-x64}.zip` are deliberately *not* owned: they are host `gen_snapshot` for
Mac/Windows and are stock by design.

Ownership only applies to hashes listed in `experimental_hashes.map`. For every
ordinary revision the mirror behaves exactly as it did before the overlay
existed.

```bash
# after selfhost/engine/build.sh --cell android-arm64
selfhost/engine/overlay_publish.sh --hash <expHash> --root /path/to/checkout
# nginx reads the hash map at startup:
docker compose -f selfhost/cdn/docker-compose.cdn.yaml up -d --force-recreate cdn-cache
```

Verify all three behaviors before spending a device cycle on it:

```bash
B=http://localhost:8085; EXP=<expHash>
# 1. our build, from disk
curl -sI $B/flutter_infra_release/flutter/$EXP/android-arm64-release/artifacts.zip | head -1
# 2. loud failure: temporarily move an owned artifact aside -> must be 404
# 3. stock fallback under the pinned hash
curl -sI $B/flutter_infra_release/flutter/$EXP/dart-sdk-darwin-arm64.zip | head -1
```

The `cdn` access log prints `must_be_local=` and `stock=` for each request, which
is the quickest way to see which of the three paths a request took.

> Docker Desktop on macOS caches bind-mount lookups for a second or two, so a
> file moved out of `overlay/` can still serve 200 briefly. Recreate the
> container if a negative test looks wrong.

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
