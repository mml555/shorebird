<!-- cspell:words getsockname pristine androidx openjdk embedding cipd prpc canonicalisation canonicalised localsend armv -->

# ANDROID-CELL-SUPPLY-1 — the measured Android closure, and what identity must cover

2026-09-03. Measurement only. **No cell minted or published, `cd848320…`
untouched, `@must_be_local` unchanged, no fallback bytes published under the
cell, no Android release cut, no device run, no Route B compiler change.**

## Verdict

    closure            = 24 required objects (29 observed, 5 incidental)
    identity-bearing   = 14   (CELL-IDENTITY)
    cache/transport    = 10
    buildable          = 24/24, no blocker found — but NOT YET BUILT
    recommended schema = A (extend the cell manifest), and the evidence forces it

## Gate 1 — the closure, derived from real requests

A recording origin served every request so `precache` and `release` ran to
completion; a refusing origin only ever reveals the first one. Requests are
logged under the **cell's own address space**. Full table:
[`closure_table.txt`](closure_table.txt), raw requests in
[`requests_precache.jsonl`](requests_precache.jsonl) and
[`requests_release.jsonl`](requests_release.jsonl).

| class | count | consumer | content |
|---|--:|---|---|
| `flutter_infra_release/flutter/%H/android-{arm,arm64,x64}-{profile,release}/darwin-x64.zip` | 6 | `flutter precache` | **`gen_snapshot`** — the host AOT compiler (darwin-x64) |
| `…/android-{arm,arm64,x64,x86}/artifacts.zip` | 4 | `flutter precache` | debug `flutter.jar` |
| `…/android-{arm,arm64,x64}-{profile,release}/artifacts.zip` | 6 | `flutter precache` | profile/release `flutter.jar` |
| `download.flutter.io/io/flutter/{flutter_embedding,arm64_v8a,armeabi_v7a,x86_64}_release/1.0.0-%H/*.{pom,jar}` | 8 | **Gradle** | the AAR carrying `lib/<abi>/libflutter.so` |
| — **required total** | **24** | | |
| `*.pom.sha1` | 4 | Gradle | checksum sidecars — 404, build succeeded |
| `shorebird/%H/aot-tools.dill` | 1 | `cache.updateAll()` | 404 twice, **release still exited 0** |

Separated as asked: **build-host tooling** = the 6 `darwin-x64.zip`
(`gen_snapshot`); **Android debug/profile engines** = 7 objects; **Android
release engines** = 3 `artifacts.zip` + their 3 `gen_snapshot`; **SDK/tool
artifacts** = none appeared (the Android SDK/NDK are the developer's, not
fetched from the cell); **Shorebird-specific** = `aot-tools.dill` only, and it
is incidental.

**Two findings that only a real request log produces.**

1. **The engine that ships in the APK comes from Maven, not from
   `artifacts.zip`.** `FlutterPluginUtils.kt:887-899` adds
   `io.flutter:flutter_embedding_release:<v>` and `io.flutter:<arch>_release:<v>`,
   resolved from `System.getenv(FLUTTER_STORAGE_BASE_URL)/download.flutter.io`
   (`FlutterPlugin.kt:92`). The AAR contains `lib/arm64-v8a/libflutter.so`
   (174 MB uncompressed). Directory conventions would never have shown this: the
   Maven objects live under a different host prefix entirely.
2. **`shorebird release android` unconditionally runs `flutter precache
   --android`.** So the closure the WORKFLOW forces (24) is strictly larger than
   the release-defining subset (14). Ten debug/profile objects — 619 MB — are
   required for the command to run and contribute nothing to the shipped app.

## Gate 2 — identity significance

The test applied to every required object: *if these bytes changed while the
cell address stayed the same, could the resulting Android release change?*

**CELL-IDENTITY — 14.** The address must commit to the exact bytes.

| object | why |
|---|---|
| 4 × Maven `.jar` (`flutter_embedding_release`, `arm64_v8a`, `armeabi_v7a`, `x86_64`) | **ship in the APK** |
| 4 × Maven `.pom` | version-bound, and Gradle *validates* it — see below |
| 3 × `android-{arm,arm64,x64}-release/darwin-x64.zip` | `gen_snapshot` compiles the `libapp.so` that ships |
| 3 × `android-{arm,arm64,x64}-release/artifacts.zip` | release-mode engine jar; I could **not exclude** it from the release path, so it is classified conservatively |

**CACHE/TRANSPORT — 10.** The four debug `artifacts.zip`, three profile
`artifacts.zip`, three profile `gen_snapshot`. Reconstructible, and a release
build does not consume them; required only because `precache` is unconditional.

**INCIDENTAL — 5.** The four `.pom.sha1` and `aot-tools.dill`, each proven by a
run that **succeeded without it** ([`aot_tools_incidental.txt`](aot_tools_incidental.txt)) —
not by reasoning about whether it looked important.

### A POLICY GAP, reported and not touched

`@must_be_local` (`selfhost/cdn/Caddyfile:165`) covers
`android-arm64-release/` and all of `download.flutter.io/io/flutter/` — but
**not** `android-arm-release/` or `android-x64-release/`. So **4 of the 14
CELL-IDENTITY members are fallback-permitted today**:

    android-arm-release/{artifacts.zip,darwin-x64.zip}
    android-x64-release/{artifacts.zip,darwin-x64.zip}

Those carry the `gen_snapshot` that compiles the shipped `libapp.so` for armv7
and x86_64. Changing `@must_be_local` is outside this lane's boundary; it is
named here so ANDROID-CELL-SUPPLY-2 does not inherit the asymmetry silently.

### Maven artifacts CANNOT fall back, structurally

Not a policy choice — Gradle detects and refuses it. Measured, with the cell
hash rewritten to the fallback revision:

    inconsistent module metadata found.
    Descriptor: io.flutter:flutter_embedding_release:1.0.0-69f9831c…
    Errors: bad version: expected='1.0.0-cd848320…' found='1.0.0-69f9831c…'

The POM's own text names its version, and Gradle compares it to the requested
coordinate. So the eight Maven objects must be **genuinely published under the
cell hash**, with POMs that declare `1.0.0-<cell>`. `@must_be_local` on that
prefix is the only thing that can work.

## Gate 3 — provenance and buildability

| | value |
|---|---|
| source repository | `github.com/shorebirdtech/flutter` (engine monorepo) |
| source revision | `dfa2b24ac38477f3705ff0357530f33fe09474b8` — the checkout that produced this cell, and the recorded `producer_engine_revision` |
| Dart | forked vanilla Dart `6b58bb3a72e293e27ff920a61c007bf2e405071e` via a `file://` custom_dep; `dart_sdk_revision 9e8c898a…` |
| build command | `./flutter/tools/gn --android --android-cpu={arm,arm64,x64} --runtime-mode={profile,release} --no-prebuilt-dart-sdk` then `ninja -C out/android_<mode>_<cpu>` |
| host requirements | macOS arm64. `DEPS:102` gates Android deps on `host_os == "mac" or (linux && x64)` — **true here** |
| Maven packaging | **in-tree**: `shell/platform/android/BUILD.gn` (`embedding_artifact_id = "flutter_embedding_$flutter_runtime_mode"`, `maven-metadata.xml` targets) and `flutter/tools/androidx/generate_pom_file.py`, which takes the version as an argument |
| reproducible | unknown — not attempted |
| **can we build it** | **no blocker found**, and not yet demonstrated |

**Two deltas from the iOS build, both favourable.** `shorebird_use_interpreter`
defaults to `is_ios`, so it is already false on Android — the override that cost
the iOS build a cycle is unnecessary. And `--dart-dynamic-modules` is *not*
needed: Android patches are bidiff and ship real machine code, so the Route B
interpreter is not on the Android path at all.

**The blocker question, answered by measurement rather than inspection.** Every
Android dependency is a **public** CIPD package, and all four resolve at their
DEPS-pinned versions ([`android_cipd_pinned.txt`](android_cipd_pinned.txt)):

    flutter/android/sdk/all/mac-amd64   version:36v8unmodified               http 200
    flutter/android/embedding_bundle    last_updated:2025-10-15T09:53:03…    http 200
    flutter/java/openjdk/mac-amd64      version:21                           http 200
    gn/gn/mac-amd64                     git_revision:81b24e01…               http 200

None is private. That matters because the Dart SDK prebuilt *is* private
(`gs://shorebird-dart-sdk-prebuilt`, 401) and is exactly why this programme
carries a Dart fork — the same failure mode does not recur for Android.

**What is NOT established, stated plainly.** No Android engine was built. The
Android deps are absent from the engine checkout — that tree was configured for
macOS/iOS (`.gclient` says so) and never synced them. I deliberately did not run
`gclient sync` against it: that tree produced the qualified cell, and moving its
third-party deps could compromise the reproducibility of an artifact already in
service. **Buildability is established by inspection plus dependency-availability
measurement, not by execution**, and a scratch build in a separate checkout is
the first task of ANDROID-CELL-SUPPLY-2.

## Gate 4 — the closure proved sufficient and load-bearing

Against a **strict** temporary origin with no upstream at all, on a pristine
Flutter cache per trial (a warm cache would make every deletion test vacuous).
Never the published cell namespace. [`gate4_proof.log`](gate4_proof.log),
harness [`../../scripts/acs1_gate4.sh`](../../scripts/acs1_gate4.sh).
**6 passed, 0 failed.**

| control | result |
|---|---|
| the measured closure is sufficient | `precache --android` exit 0; 16 requests, **0 absences** |
| no request escapes | the log names no upstream host; strict mode has no upstream to escape to |
| load-bearing | deleting `android-arm64-release/darwin-x64.zip` → exit 1, `Failed to download …/android-arm64-release/darwin-x64.zip / Exception: 404` — that exact object |
| unrelated files cannot rescue | two 4 MB random decoys plus a copy of the victim under a neighbouring name → still exit 1 on the same object |

Separately, the full 24 let `shorebird release android` reach **exit 0** —
which is what establishes that the closure is complete and not merely
precache-complete.

## Gate 5 — schema decision: **Option A**, and the evidence forces it

**Option B is not mechanically expressible.** Every required object's path
derives from a *single* value — the Flutter checkout's `bin/internal/engine.version`,
which for this stack **is** the cell address:

    flutter_infra_release/flutter/<engine.version>/android-…
    download.flutter.io/io/flutter/<artifact>/1.0.0-<engine.version>/…

A separately addressed Android set would need a *second* hash in that same path
space. Flutter resolves one. Option B therefore requires changing how Flutter
resolves artifact paths — a deeper change than the one it was meant to avoid,
and it could not be fail-closed without inventing a binding Flutter has no
concept of.

**Option A is what the schema already anticipates.** Three pieces of existing
evidence:

1. The v2 descriptor's second line is **`cell macos-ios`** — a platform-scope
   field already present and already narrower than "everything".
2. The cell's `artifacts_manifest.yaml` **already lists the Android release and
   Maven overrides** in `artifact_overrides` — inherited via
   `override_list_from` from an earlier cell. The list describes what a
   Shorebird release engine overrides; the overlay holds 10 of the 48. Declared
   and unpublished, which is why the 404s are fail-closed rather than wrong
   bytes.
3. The address-bearing-member circularity is **already solved**. A POM must
   contain the address (Gradle validates it), and the address is computed over
   member digests — apparently circular. `verify_cell_members.sh`'s `canon_hash`
   resolves exactly this: it rewrites the cell's own hash back to a literal
   `%H` before hashing, and **refuses** a hash outside one permitted field per
   file type. Confirmed by recomputation: `artifacts_manifest.yaml` hashes to
   `ab8f1247…` raw and to the descriptor's `0f4e4cb2…` canonicalised.

   *(I first read the raw mismatch as a defect. It was my error — I hashed the
   file instead of canonicalising it. Recorded because the next reader will
   make the same mistake.)*

### The concrete delta for ANDROID-CELL-SUPPLY-2

    NEW cell address (a new descriptor, therefore a new address)
      cell macos-ios-android            ← widen the scope field
      16 existing members               ← unchanged bytes, unchanged digests
      +14 Android CELL-IDENTITY members ← 8 maven, 3 release gen_snapshot,
                                          3 release artifacts.zip
      = 30 addressed members

One schema addition is needed: `canon_hash` must learn a permitted hash-bearing
field for the Maven POM — `<version>1.0.0-%H</version>` — exactly as it already
has one for `engine_stamp.json`'s `git_revision` and `artifacts_manifest.yaml`'s
comments. Without it, a POM would be rejected as "no permitted hash-bearing
field", which is the guard behaving correctly.

The 10 CACHE/TRANSPORT members stay **unaddressed and fallback-permitted**: they
are reconstructible and cannot change a release. That keeps the new cell's
addressed set to what the invariant demands — *every byte capable of changing
the shipped executable is covered by an authenticated immutable identity* — and
no larger.

**And the `@must_be_local` asymmetry must be closed in the same change**, or 4
of the 14 identity-bearing members would be addressed by the cell while the CDN
still permitted a fallback to supply them.

## Provenance

| thing | value |
|---|---|
| repo revision | `b285387d` (clean) |
| cell under study | `cd848320d605ff8af5060cabf9a8d1b35853f752`, descriptor `route-b-cell-v2`, `cell macos-ios`, 16 members, verified 16/16 |
| CLI | worktree at `5920a8bf` with an isolated cache — the qualified runtime checkout was never written to and is still Android-free |
| fallback used for MEASUREMENT only | `69f9831c…`, per `experimental_hashes.map` |
| scratch trees | `/Volumes/build/route-b/acs1/` — nothing published under the cell namespace |
