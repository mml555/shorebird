# CDN independence — removing the build-time dependency on `download.shorebird.dev`

Status legend: `source-derived` = read directly from the CLI / `artifact_proxy`
source in this repo at commit `60edcfdc` (CLI 1.6.114, Flutter 3.44.7, engine
`309dd6573a9fe716410489284cd325a34b950375`). No runtime CDN calls were made to
produce this document.

Runtime code-push is already fully self-hosted (see `BEHAVIORAL_FINDINGS.md`).
The **only** remaining dependency on Shorebird-operated infrastructure is at
**build time**: the CLI + the vended Flutter tool fetch engine/tooling artifacts
from `download.shorebird.dev` and from the Google Cloud Storage bucket behind it.
This document enumerates exactly what is fetched, which knobs are and are not
overridable, and gives a concrete plan (with the exact minimal source diff) to
mirror or proxy all of it.

---

## 1. What `download.shorebird.dev` actually is

`download.shorebird.dev` is **the `packages/artifact_proxy` service** deployed in
front of a Google Cloud Storage bucket also named `download.shorebird.dev`. It is
a redirector, not a byte store:

- It matches the incoming Flutter artifact path against `engineArtifactPatterns`
  / `flutterArtifactPatterns` (`artifact_proxy/lib/config.dart`).
- For an **engine** artifact it loads the manifest
  `storage.googleapis.com/download.shorebird.dev/shorebird/<engineRev>/artifacts_manifest.yaml`
  (`artifact_manifest_client.dart`). If the normalized path is in that manifest's
  `artifact_overrides`, it `302`-redirects to the **Shorebird-modified** copy at
  `storage.googleapis.com/<bucket>/shorebird/<engineRev>/…` (bucket =
  `download.shorebird.dev`). Otherwise it `302`-redirects to the **stock Flutter**
  copy at `storage.googleapis.com/flutter_infra_release/flutter/<flutterEngineRev>/…`
  (`artifact_proxy.dart`, `getShorebirdArtifactLocation` / `getFlutterArtifactLocation`).

So the actual artifact **bytes** always live in Google Cloud Storage:
`storage.googleapis.com/download.shorebird.dev/…` (Shorebird's bucket, genuinely
Shorebird infra) and `storage.googleapis.com/flutter_infra_release/…` (Google's
public Flutter bucket). `download.shorebird.dev` only decides *which* of the two
to hand back. **Running `artifact_proxy` yourself relocates that decision to your
host but does NOT remove the dependency on Shorebird's GCS bucket** — true
build-time independence requires mirroring those bytes (see §4).

---

## 2. The two independent artifact flows (and their override knobs)

There are **two** distinct fetch paths to `download.shorebird.dev`, wired
completely differently. This distinction is the crux of the whole effort.

### Flow A — the vended Flutter engine (via `FLUTTER_STORAGE_BASE_URL`)

When the CLI runs the vended `flutter` binary, the Flutter tool downloads every
engine artifact it needs (dart-sdk, gen_snapshot, `artifacts.zip`,
`flutter_patched_sdk`, the Android `.jar`/`.pom`s, iOS frameworks, gradle-wrapper,
canvaskit, fonts, …) from `$FLUTTER_STORAGE_BASE_URL/flutter_infra_release/…` and
`$FLUTTER_STORAGE_BASE_URL/download.flutter.io/…`.

Shorebird forces that base URL to `https://download.shorebird.dev` in **three**
places (`source-derived`):

| # | Location | When it fires |
|---|----------|----------------|
| A1 | `packages/shorebird_cli/lib/src/shorebird_process.dart:265-273` (`_environmentOverrides`) | Every `flutter` invocation the CLI makes |
| A2 | `third_party/flutter/bin/internal/shared.sh:23` | First-time Flutter bootstrap (POSIX wrapper) |
| A3 | `bin/shorebird.ps1:127` | First-time Flutter bootstrap (Windows wrapper) |

> **Not runtime-overridable via the environment.** Although
> `FLUTTER_STORAGE_BASE_URL` is a standard Flutter knob, `_environmentOverrides`
> is merged with `addAll(...)` which *overwrites* any caller/shell value
> (the code comments even warn about this). So a user exporting
> `FLUTTER_STORAGE_BASE_URL` in their shell has no effect — the CLI stomps it.
> Redirecting Flow A therefore requires **either** a source change to A1–A3
> **or** a transparent proxy / DNS override of the `download.shorebird.dev`
> hostname (§3, §5).

`artifact_proxy` is purpose-built for exactly this flow: point
`FLUTTER_STORAGE_BASE_URL` at it and it does the stock-vs-shorebird routing.

### Flow B — the Shorebird CLI cache (hardcoded in `cache.dart`, NOT env-overridable)

Separately, `Cache` fetches Shorebird's own tooling. The URLs are assembled from
two getters in `packages/shorebird_cli/lib/src/cache.dart`:

```dart
String get storageBaseUrl => 'https://storage.googleapis.com';   // line 121
String get storageBucket  => 'download.shorebird.dev';           // line 124
```

Used by (`source-derived`):

| Artifact | Class / line | Resulting URL |
|----------|--------------|----------------|
| `patch` / `patch.exe` (binary diff engine) | `PatchArtifact.storageUrl`, `cache.dart:361` | `https://storage.googleapis.com/download.shorebird.dev/shorebird/<engineRev>/patch-<os-arch>.zip` |
| `aot-tools.dill` (AOT linker, optional) | `AotToolsArtifact.storageUrl`, `cache.dart:315` | `https://storage.googleapis.com/download.shorebird.dev/shorebird/<engineRev>/aot-tools.dill` |
| `bundletool.jar` | `BundleToolArtifact.storageUrl`, `cache.dart:393` | `https://github.com/google/bundletool/releases/…` — **not Shorebird infra**, independent already |

> **These bypass `FLUTTER_STORAGE_BASE_URL` and `artifact_proxy` entirely.** They
> hit `storage.googleapis.com` **directly** (the raw GCS host, not the
> `download.shorebird.dev` proxy host), and the two getters read **no environment
> variable** — they are literal strings. Flow B is therefore **not overridable at
> all today**. Redirecting it requires **either** the source patch in §6 **or** a
> per-URL proxy. A DNS override is *not* viable here because the host is the
> shared `storage.googleapis.com` — repointing it would break every other GCS
> user on the machine.

### Also: the manifest fetch inside `artifact_proxy` (`source-derived`)

`artifact_manifest_client.dart` hardcodes
`https://storage.googleapis.com/download.shorebird.dev/shorebird/<rev>/artifacts_manifest.yaml`.
So even a self-hosted `artifact_proxy` still reaches Shorebird's GCS bucket for
the manifest. For a fully offline mirror this file must be mirrored too (§4).

### Also: the AAR maven repo (`source-derived`, docs-only)

`aar_releaser.dart:170` prints setup instructions telling the *end user's app* to
add `maven { url 'https://download.shorebird.dev/download.flutter.io' }`. This is
printed guidance for AAR consumers, not a CLI fetch, but it is another
`download.shorebird.dev` reference to rewrite for AAR users.

---

## 3. Overridable vs hardcoded — summary table

| Flow | What | Mechanism | Env-overridable today? | To redirect |
|------|------|-----------|------------------------|-------------|
| A | Flutter engine artifacts | `FLUTTER_STORAGE_BASE_URL` forced to `download.shorebird.dev` in 3 spots | **No** (CLI overwrites the env) | Patch A1–A3 to honor an env/default, **or** DNS+TLS override of `download.shorebird.dev`; then run `artifact_proxy` |
| B | `patch`, `aot-tools.dill` | `cache.dart` `storageBaseUrl`+`storageBucket` literals | **No** (literal getters) | Source patch (§6) to read env, **or** a proxy the patched base URL points at |
| B | `bundletool.jar` | GitHub releases URL literal | **No**, but already off Shorebird infra | (optional) mirror GitHub asset |
| — | `artifact_proxy` manifest fetch | literal GCS URL in `artifact_manifest_client.dart` | **No** | mirror the manifest into your GCS-fronting cache |

**Bottom line:** *nothing* in the build-time path is overridable purely via
environment variables today. Every option needs **either** a small CLI source
change **or** a network-layer interception (proxy/DNS).

---

## 4. Plan: mirror vs proxy

Two complementary pieces, matching the two flows.

### (a) Flutter engine artifacts — `artifact_proxy` + a caching mirror

`artifact_proxy` already implements the exact stock-vs-shorebird routing
`download.shorebird.dev` does. Deploy it (§/cdn/`docker-compose.cdn.yaml`) and
point Flow A at it. Because it emits `302`s to `storage.googleapis.com`, put a
caching reverse proxy (nginx) in front so that:

1. the client hits our nginx,
2. nginx forwards the engine path to `artifact_proxy`,
3. `artifact_proxy` returns a `302` to `storage.googleapis.com/…`,
4. nginx **rewrites** that `Location` to a relative `/gcs/…` path so the client
   re-enters *through nginx*, which then proxies **and caches** the real bytes
   from GCS.

After one warm build, every engine artifact for that engine revision is served
from local disk — no `download.shorebird.dev`, no GCS round-trip. This mirrors
both the stock Flutter bytes (`flutter_infra_release/…`) and the Shorebird-
modified engine bytes (`download.shorebird.dev/shorebird/<rev>/…`), plus the
manifest, since all three are just GCS objects the cache captures on first fetch.

Wiring for Flow A still needs the entry redirect (§5): either patch A1–A3 to send
`FLUTTER_STORAGE_BASE_URL` at our nginx, or DNS-override `download.shorebird.dev`.

### (b) Shorebird cache artifacts — patch `cache.dart` to point at the same cache

Flow B can't be proxied without either changing where its URL points (source
patch §6) or hijacking `storage.googleapis.com` (unacceptable). With the §6
patch, set `SHOREBIRD_STORAGE_BASE_URL=http://<your-nginx>` and keep
`SHOREBIRD_STORAGE_BUCKET=download.shorebird.dev`; the CLI then requests
`http://<your-nginx>/download.shorebird.dev/shorebird/<rev>/patch-*.zip`, which
nginx proxies+caches from `storage.googleapis.com/download.shorebird.dev/…`.
Same cache, same offline guarantee after warm-up.

---

## 5. Wiring Flow A without patching the CLI: DNS + TLS override (alternative)

If you cannot patch A1–A3, intercept the hostname instead:

- Add `download.shorebird.dev  <your-nginx-ip>` to `/etc/hosts` (or LAN DNS).
- Because Flutter requests `https://download.shorebird.dev`, your nginx must
  present a TLS cert **for that hostname** that the build machine trusts
  (self-signed cert added to the system/Flutter trust store). Flutter/Dart will
  reject an untrusted cert, so this is the fiddly part.
- `storage.googleapis.com` (Flow B and the `302` targets) must **not** be
  DNS-overridden — it is a shared Google host. This is why DNS-only cannot cover
  Flow B and why the §6 source patch is the clean answer for it.

Because of the TLS friction and the Flow-B gap, the **recommended** approach is
the small source patch (§6 for Flow B, and the analogous A1–A3 tweak for Flow A),
which needs no cert wrangling and no DNS games.

---

## 6. Exact minimal source diff for Flow B (PROPOSAL — not applied)

Make the two `cache.dart` getters honor environment variables, defaulting to
today's values so behavior is unchanged unless the operator opts in. `platform`
is already the ambient scoped dependency in this file (it is passed to every
`CachedArtifact` in the `Cache` constructor), and `platform.environment[...]` is
the established pattern across the CLI (e.g. `shorebird_env.dart`).

`packages/shorebird_cli/lib/src/cache.dart`, lines 120-124:

```diff
-  /// The storage base url.
-  String get storageBaseUrl => 'https://storage.googleapis.com';
-
-  /// The storage bucket host.
-  String get storageBucket => 'download.shorebird.dev';
+  /// The storage base url. Override with `SHOREBIRD_STORAGE_BASE_URL` to point
+  /// the CLI cache (patch/aot-tools) at a self-hosted mirror or proxy.
+  String get storageBaseUrl =>
+      platform.environment['SHOREBIRD_STORAGE_BASE_URL'] ??
+      'https://storage.googleapis.com';
+
+  /// The storage bucket host. Override with `SHOREBIRD_STORAGE_BUCKET`.
+  String get storageBucket =>
+      platform.environment['SHOREBIRD_STORAGE_BUCKET'] ??
+      'download.shorebird.dev';
```

That is the entire change needed to make Flow B self-hostable. No call sites
change: both getters are consumed only by `PatchArtifact.storageUrl` and
`AotToolsArtifact.storageUrl`, which concatenate `storageBaseUrl` + `/` +
`storageBucket` + `/shorebird/…`.

### Analogous (optional) Flow A patch

For symmetry and to avoid the DNS/TLS route, make A1 honor an env default too —
`packages/shorebird_cli/lib/src/shorebird_process.dart:265-273`:

```diff
   Map<String, String> _environmentOverrides({required String executable}) {
     if (executable == 'flutter') {
-      // If this ever changes we also need to update the `shorebird` shell
-      // wrapper which downloads runs Flutter to fetch artifacts the first time.
-      return {'FLUTTER_STORAGE_BASE_URL': 'https://download.shorebird.dev'};
+      // If this ever changes we also need to update the `shorebird` shell
+      // wrapper which runs Flutter to fetch artifacts the first time
+      // (third_party/flutter/bin/internal/shared.sh and bin/shorebird.ps1).
+      return {
+        'FLUTTER_STORAGE_BASE_URL':
+            platform.environment['SHOREBIRD_FLUTTER_STORAGE_BASE_URL'] ??
+            'https://download.shorebird.dev',
+      };
     }
     return {};
   }
```

(`platform` is already imported in `shorebird_process.dart`.) The two shell
wrappers A2/A3 would take the same `${SHOREBIRD_FLUTTER_STORAGE_BASE_URL:-https://download.shorebird.dev}`
default. A dedicated `SHOREBIRD_`-prefixed var is used rather than reusing
`FLUTTER_STORAGE_BASE_URL` so the override is explicit and can't be triggered
accidentally by unrelated Flutter tooling in the environment.

---

## 7. Honest assessment

**Fully achievable with proxy/mirror + the §6 patch (no protocol changes):**

- All Flutter engine artifacts (Flow A) via self-hosted `artifact_proxy` + nginx
  cache. `artifact_proxy` is first-party and already does the exact routing.
- The Shorebird `patch` and `aot-tools.dill` artifacts (Flow B) via the same
  nginx cache once the two `cache.dart` getters are env-driven.
- `bundletool.jar` is already off Shorebird infra (GitHub); optional to mirror.

**Requires a CLI source change (small, low-risk, defaulted):**

- **Flow B cannot be self-hosted by env or proxy alone** — the URL literals must
  become env-driven (§6), because the alternative (DNS-hijacking
  `storage.googleapis.com`) is unsafe. This is the single load-bearing code
  change. 4 lines, backward-compatible.
- **Flow A** can technically be done without a source change via DNS+TLS
  override, but in practice the TLS-trust friction makes the analogous small
  patch (A1–A3) the sane path.

**What a self-hosted proxy does NOT remove by itself:** running `artifact_proxy`
only relocates the *routing* host; the Shorebird-modified engine bytes and the
`patch`/`aot-tools` bytes still originate in Shorebird's GCS bucket. Genuine
independence needs the **mirror** (nginx cache, warmed once per engine revision),
not just the proxy.

**Bandwidth / storage implications of mirroring:**

- Artifacts are **immutable per engine revision** (the path contains the revision
  hash), so they can be cached effectively forever and only re-fetched when you
  adopt a new Shorebird/Flutter engine.
- A single engine revision's full multi-platform artifact set (dart-sdks +
  gen_snapshots + per-arch `artifacts.zip` + Android `.jar`/`.pom`s + iOS
  frameworks + web SDK + canvaskit + gradle-wrapper) is on the order of **a few
  GB**. Budget ~5–10 GB of cache per engine revision you intend to support; the
  compose file sets a 20 GB cap (`max_size=20g`) to hold a couple of revisions.
- First build per revision pays the full download once (from GCS through your
  cache); every subsequent build on any machine pointed at the cache is served
  locally. For a team, host the nginx cache centrally so the warm-up is paid once
  org-wide.
- The `patch`/`aot-tools`/manifest objects are tiny (KB–low-MB); negligible.
- Range/partial-content requests: the provided nginx config caches full `200`
  responses; if a Flutter version issues range requests for a large artifact,
  enable nginx's `slice` module or let the first full fetch populate the cache.
  Noted as a caveat, not observed to block standard `flutter precache`.

---

## 8. Files in this deliverable

- `selfhost/CDN_INDEPENDENCE.md` — this document.
- `selfhost/cdn/docker-compose.cdn.yaml` — runs `artifact_proxy` + nginx cache.
- `selfhost/cdn/nginx.conf` — caching reverse proxy that mirrors GCS and rewrites
  the `artifact_proxy` redirects back through itself.
- `selfhost/cdn/README.md` — step-by-step wiring (env vars, patches, warm-up).
</content>
