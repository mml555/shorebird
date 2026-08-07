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
| `cdn-cache` (Caddy) | Caching reverse proxy in front of `artifact-proxy` and `storage.googleapis.com`. Rewrites the proxy's 302s back through itself and caches the real bytes. After one warm build, artifacts are served from local disk. Built from `Dockerfile` with the [cache-handler](https://github.com/caddyserver/cache-handler) module (stock Caddy has no disk HTTP cache). |

Listens on host port **8085** (8080 is left for `code_push_server`).

## Start it

```bash
docker compose -f selfhost/cdn/docker-compose.cdn.yaml up --build
```

The first image build compiles Caddy with the cache plugin (~1–2 min). Later
rebuilds reuse that layer when the plugin set is unchanged.

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
(cache miss→GCS on first build, hit→local disk thereafter), with no
`download.shorebird.dev` contact. `bundletool.jar` comes from GitHub (not
Shorebird), so it never touches the mirror.

**Verified (Flow A), engine `69f9831c`:** all 87 engine artifact paths that
`artifact_proxy` routes were requested through the mirror. 78 returned `200` and
cached (2.8 GB total); the other 9 are not published for this revision and
`404` — those are cached for one minute only, so they legitimately re-MISS.
A second pass over the same 87 reported cache hits for all 78, i.e. served from
local disk with no upstream contact.

Those 87 paths are **not the whole story**: they are the archives the flutter tool
fetches, and warming them all still left the Gradle Maven artifacts
(`download.flutter.io/io/flutter/<abi>_release/*.jar`) cold. A real
`shorebird release android` is what pulls those, so treat "warm" as meaning *one
full release build has run through the mirror*, not *a list of URLs was fetched*.

> Flow A needed a fix to work at all. `artifact_proxy`'s
> `https://storage.googleapis.com/...` 302 is rewritten to a relative `/gcs/...`
> Location so the client re-enters through the mirror. Absolute redirects keyed
> off the container listen port (8080) previously sent clients on the published
> host port (8085) to the wrong place. Relative Locations resolve against
> whatever host:port the client actually used — published on 8085, in-network on
> 8080, or behind TLS on 8443.

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

HTTPS for the mirror:

```bash
selfhost/cdn/tls/generate.sh
selfhost/cdn/tls/trust.sh          # on every machine that builds
docker compose -f selfhost/cdn/docker-compose.cdn.yaml \
               -f selfhost/cdn/docker-compose.cdn.tlslocal.yaml up --build -d
export FLUTTER_STORAGE_BASE_URL=https://localhost:8443
export SHOREBIRD_STORAGE_BASE_URL=https://localhost:8443
```

## Warm the cache

```bash
shorebird release android      # first run pulls artifacts through the cache
```

Watch cache status in the `cdn-cache` logs (`Cache-Status` response header also
reports hits/misses):

```bash
docker compose -f selfhost/cdn/docker-compose.cdn.yaml logs -f cdn-cache
```

Once warm, the same engine revision builds without touching
`download.shorebird.dev` or GCS. Host the cache centrally to warm it once for a
whole team.

**"Warm" is defined by executing full real workflows, never by a URL list** —
URL-list warming missed the Maven artifacts once already (see Notes). The
procedure for a provably complete cache is: run the acceptance payload
(`../scripts/airgap_acceptance.sh`) once against the unsealed mirror, then
seal and run it again.

## SEALED mode (air-gap acceptance)

Sealed mode makes the mirror REFUSE every upstream fetch: cache hits and
overlay files still serve, any cold path returns a greppable
`sealed: refusing upstream fetch` 502 (bounded to `max-age=1`, so a refusal
can never stick in the cache past unsealing). The upstream reachability is a
one-file compose mount (`upstream/enabled.caddy` vs `upstream/sealed.caddy`,
imported at every point the Caddyfile would reach GCS):

```bash
# seal
docker compose -f selfhost/cdn/docker-compose.cdn.yaml \
               -f selfhost/cdn/docker-compose.cdn.sealed.yaml up -d
# machine-check that a sealed run needed nothing cold
selfhost/cdn/verify_warm.sh --since 2h
# unseal
docker compose -f selfhost/cdn/docker-compose.cdn.yaml up -d
```

Verified live 2026-08-05: cached bytes 200, overlay files 200, cold path 502
with the marker. (Caddy ordering matters: `order cache before respond`, or the
sealed `respond` preempts cache HITs.)

## Mirrors for full self-containment

Everything a clean machine touches that is NOT Shorebird infrastructure:

- **Flutter git clone** (CLI bootstrap): a bare mirror lives at
  `selfhost/cdn/mirrors/flutter.git` (git-ignored; recreate with
  `git clone --mirror https://github.com/shorebirdtech/flutter.git` and set
  `uploadpack.allowfilter=true` + `uploadpack.allowanysha1inwant=true` on it —
  the bootstrap does a `--filter=tree:0` clone). Point
  `SHOREBIRD_FLUTTER_GIT_URL=file:///…/mirrors/flutter.git` (or serve it over
  git daemon / smart-HTTP for other machines). Bootstrap-from-mirror verified
  2026-08-05.

  **Durable copy: `github.com/mml555/shorebird-flutter-mirror` (private).**
  Pushed 2026-08-06 — 1779 refs. This is the insurance the local mirror is
  not: a laptop disk is not a backup. Upstream is open source and we are
  happy to depend on it; what we refuse is being unable to rebuild if it
  ever closes or disappears.

  `refs/pull/*` is rejected by GitHub ("deny updating a hidden ref") and that
  is fine — those are the source repo's PR metadata, not code.

  Refresh it (safe to re-run):
  ```bash
  git -C selfhost/cdn/mirrors/flutter.git fetch --prune origin
  git -C selfhost/cdn/mirrors/flutter.git push --mirror durable   # ignore refs/pull/* rejects
  ```

  **Restore from it** — this exact sequence was run and verified, it is not
  a plausible-looking recipe:
  ```bash
  git clone --mirror https://github.com/mml555/shorebird-flutter-mirror.git \
      selfhost/cdn/mirrors/flutter.git
  git -C selfhost/cdn/mirrors/flutter.git config uploadpack.allowfilter true
  git -C selfhost/cdn/mirrors/flutter.git config uploadpack.allowanysha1inwant true
  # proof it works: a bootstrap-shaped clone of the pinned revision
  git clone --filter=tree:0 --no-checkout <mirror-url> /tmp/restore_test
  git -C /tmp/restore_test checkout c15ef6379403a0a55531a058bdb2c8e55bc05c98
  cat /tmp/restore_test/bin/internal/engine.version   # expect 69f9831c…
  ```
- **bundletool.jar**: mirrored at `overlay/mirror/bundletool/`, served by the
  overlay; point `SHOREBIRD_BUNDLETOOL_URL` at
  `$MIRROR/mirror/bundletool/bundletool-all-1.18.1.jar`. The CLI still
  verifies the pinned SHA-256 either way.
- **pub.dev**: seed a `PUB_CACHE` during the warm run and set
  `SHOREBIRD_PUB_OFFLINE=true` for sealed runs (`dart pub get --offline`).
  A true pub mirror is possible but out of scope — pub's API embeds absolute
  archive URLs, so a dumb HTTP cache cannot mirror it.
- **artifact manifest**: `artifact_proxy` reads `MANIFEST_BASE_URL`
  (wired in docker-compose to route through this cache), so its server-side
  manifest fetch survives upstream loss too.

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
`@must_be_local` matcher in `Caddyfile`: `android-arm64-release/`, `ios-release/`,
host `artifacts.zip`, platform dills, `dart-sdk-*.zip`, `engine_stamp.json`, and
the `download.flutter.io` Maven modules. That 404 is the point — a half-published
experiment must fail loudly rather than quietly run Shorebird's stock engine
under your hash. `android-arm64-release/{darwin-x64, windows-x64}.zip` are
deliberately *not* owned: they are host `gen_snapshot` for Mac/Windows and are
stock by design.

Ownership only applies to hashes listed in `experimental_hashes.map`. For every
ordinary revision the mirror behaves exactly as it did before the overlay
existed.

```bash
# after selfhost/engine/build.sh --cell android-arm64
selfhost/engine/overlay_publish.sh --hash <expHash> --root /path/to/checkout
# Caddy reads the hash map at startup:
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

> Docker Desktop on macOS caches bind-mount lookups for a second or two, so a
> file moved out of `overlay/` can still serve 200 briefly. Recreate the
> container if a negative test looks wrong.

## Artifact ownership: what we BUILT vs what we merely SERVE

"It is in our mirror" and "we produced it" are different claims, and only the
second one is independence. [`artifact_policy.conf`](artifact_policy.conf) is
the written policy; [`audit_overlay.sh`](audit_overlay.sh) enforces it.

The rule:

> Own every artifact whose correctness depends on our Dart/Flutter tree, or
> whose URL is under one of our custom engine hashes. Mirror stock only when
> the artifact is demonstrably tree-independent, or belongs to a platform we
> deliberately do not build.

Four states, because two is not enough to describe what is actually going on:

| State | Meaning | May it support a "self-built" claim? |
|---|---|---|
| `owned-built` | Produced from our tree and validated | **Yes** |
| `owned-mirrored` | Served by us, sourced upstream because the artifact is tree-*independent* | No — we serve it, we did not compile it |
| `compat-mirrored` | Stock, kept only for a platform/cell we do not build | **Never** |
| `denied` | Route-protected and deliberately absent: 404 is the right answer | n/a |

`denied` exists because silent cross-toolchain mixing is worse than a loud
failure. Stock `font-subset.zip` extracts into the same cache directory as
`artifacts.zip`, so on 2026-08-06 the stock `const_finder` overwrote the fork
one and every release died with `Invalid SDK hash` — after a full warm run.
Host toolchains we do not build are therefore denied, not mirrored.

```bash
selfhost/cdn/audit_overlay.sh --hash <hash> --cell linux-android
selfhost/cdn/audit_overlay.sh --hash <hash> --cell macos-ios --emit-manifest
```

It cross-checks three sources that drift independently — the policy, the
overlay on disk, and the Caddyfile's `@must_be_local` matcher — and the
three-way check is the point. An artifact we *believe* we own but which is not
route-protected falls through to the pinned hash and serves **stock bytes
silently**; you cannot see that by looking at the overlay, because the bytes
are absent locally and present in the response.

`--emit-manifest` writes `provenance.yaml` beside the artifacts, generated from
the policy so the two cannot drift. That is the file that answers "where did
this come from?" for a custom hash — unlike `artifacts_manifest.yaml`, which is
produced by Shorebird's own `generate_manifest.sh` and is an upstream
description of our hash.

**Fix order, when the audit reports `UNPROTECTED`: publish the bytes first,
then add the path to `@must_be_local`.** Protecting an artifact that does not
exist yet 404s every build against that hash.

## Notes / caveats

- Artifacts are immutable per engine revision (the revision hash is in the path),
  so they cache effectively forever; re-warm only when adopting a new engine.
- Budget ~5–10 GB per engine revision. The NutsDB cache volume lives under
  `/var/cache/caddy/cdn` — raise host disk if you keep more revisions.
- If a Flutter version issues HTTP range requests for large artifacts, the first
  full fetch populates the cache; partial hits may still MISS until then.
- `artifact-proxy` itself still reaches Shorebird's GCS bucket for the per-
  revision `artifacts_manifest.yaml`; the Caddy cache captures that object on
  first fetch too, so it is covered by the same warm-up.
