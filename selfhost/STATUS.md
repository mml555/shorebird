<!-- cspell:words dartdev nehelper nutsfix sbrel uiautomator ureq -->
# Fork status

As of 2026-11-11. This is the starting point for picking the work back up: what state the
four repositories are in, what is proven, what is open, and what to do next. Update it
when an item here changes; history of how things got here lives in the PRs and in
[`STATE_OF_THE_SYSTEM.md`](STATE_OF_THE_SYSTEM.md).

## The four repositories

| Repository | Active branch | State |
|---|---|---|
| `mml555/shorebird` | `main` | Upstream v1.6.138 merged in (#79). CLI pins Flutter `5b180d22`. `experimental` and `selfhost/cli-backport-1.6.123` are ancestors of `main`: nothing on them is missing from it. |
| `mml555/shorebird-updater-mirror` | `route-b-ca91f4b3` (now the default) | Source port of the updater; vendored here under `vendor/updater/` (see its `VENDOR.md`). Old `route-b` is history only. |
| `mml555/shorebird-flutter` | `shorebird/dev` | PR #1 (the port onto Flutter 3.47.9 / Dart 3.13.7) merged 2026-11-09 as `bb7b68ab`. Its head `3a565f27` was built for android arm, arm64 and x64 plus the linux-x64 host toolchain, and published to the CDN mirror on ci-build (see below). PR #2 (merged 2026-11-09 as `c240f515`) pins `engine.version` to `3a565f27`. Its CI downloads the engine from the GitHub release `engine-3a565f27…` and serves it through `selfhost/cdn` on the runner ([`selfhost-engine-mirror`](https://github.com/mml555/shorebird-flutter/blob/shorebird/dev/.github/actions/selfhost-engine-mirror/action.yml)). Linux and Android jobs pass. Since 2026-11-10 the release also holds the macOS host side of `3a565f27` (built on the owner's Mac, [`selfhost/engine/macos/`](engine/macos/README.md)): darwin arm64 and x64 toolchains and Dart SDKs, the macOS framework, and `patch-darwin-*.zip`. PR #3 (merged 2026-11-10 as `eff7759c`) runs the mirror on macOS runners with `selfhost/cdn/run_native.sh`. PR #4 (merged 2026-11-10 as `206b4fd1`) adds the iOS engine and pins `engine.version` to `255fd850` (see [iOS on `255fd850`](#ios-on-255fd850)). PR #5 (`8b6a30d0`) skips the two jobs that need upstream's paid Namespace runners unless the repository opts in with `vars.NSCLOUD_RUNNERS`. PR #6 (`1ba9785e`) makes the runner-side mirror also install each release's `overlay-extra-<hash>.tar` when its `release_sums` line pins `SHA256SUMS.extra`. PR #8 (merged 2026-11-10) brings in upstream's newer shorebird-flutter commits and #7, and pins `engine.version` to `7806e0fb`, built and published the same way (iOS still without code patches; see [iOS engines](#ios-on-255fd850)). PRs #9 to #11 (merged 2026-11-11) port the Route B engine half behind the gn knob `shorebird_route_b` and build the iOS release engine with it on. PR #12 (merged 2026-11-11 as `d12e29ec`) pins `engine.version` to `2c4b0718`, the first 3.47 engine whose iOS release engine runs Dart patches (see [iOS code push on `2c4b0718`](#ios-code-push-on-2c4b0718-route-b)). |
| `mml555/dart-sdk-shorebird-lineage` | `selfhost/3.13.7/route-b` | Pushed. The `maot/3.13.7/*` branches are the mutable-AOT research line and are not part of the shipped toolchain. |

## Housekeeping done on 2026-11-08

- Closed 28 superseded PRs on `mml555/shorebird` (the August Route B stacks, cw01-cw05,
  rb01-rb10 and the original feature PRs). Every file they touch is on `main` in a later
  form, except `ios_framework_patcher.dart` from cw05 (see open items).
- Deleted 44 merged or superseded branches. Each tip is kept as an `archive/<branch>` tag,
  so any of them can be restored with
  `git push <remote> archive/<b>:refs/heads/<b>`, where `<remote>` points at `mml555/shorebird`.
- Updater mirror: default branch switched to `route-b-ca91f4b3`, branch protection
  requires the `ci` and `required` checks, stale dependabot PRs against `route-b` closed.
- CI runs only on the home CI host (the GitHub Actions billing limit is reached). The
  host already runs ephemeral runners with an egress allowlist and a registration backoff;
  the scripts that set it up are in the repo since #85 (`selfhost/ci-host/`).
- Commit `a97f0130e` scrubbed infrastructure details from the tree; older history still
  holds them. They belong to a cloud build host the owner has since deleted (confirmed
  2026-11-08), and the TLS key in history was trusted only by that host, so none of it is
  live.

## In flight

As of 2026-11-11. #84 to #118 are merged except #111 and #112 (both open, below; #113 is an issue). Mirror #10 and #11, and shorebird-flutter #1 to #12 are merged too (#7 landed inside #8; #12 pins engine `2c4b0718`). #93 makes `IDP_ISSUER` required in production when an IdP is configured: set it before the next server deploy.

| Item | What | Waiting on |
|---|---|---|
| Flutter 3.47 promotion ([#111](https://github.com/mml555/shorebird/pull/111), draft) | Moves `bin/internal/flutter.version` to shorebird-flutter `9056dae9` (engine `7806e0fb`) and the `shorebird:` block of `compatibility.yaml` to CLI 1.6.138. The artifact gates of [`TOOLCHAIN_PROMOTION.md`](TOOLCHAIN_PROMOTION.md) pass: sealed cold bootstrap, closure guard, Linux release and patch with no upstream fetch. The frozen R12 harness fails arm 3: with two releases and no `--release-version`, CLI 1.6.138 guesses the release (deprecated upstream, [shorebirdtech/shorebird#4354](https://github.com/shorebirdtech/shorebird/issues/4354)) instead of refusing with 64. | **On hold (owner's decision).** Upstream removes the guessing after 2027-01-01; re-run the chain and the two-arm R12 then. Re-pin it first to shorebird-flutter `d12e29ec` (engine `2c4b0718`): `9056dae9` has no Route B iOS engine. The PR comment lists what else it needs. |
| R12 tooling on ci-build ([#112](https://github.com/mml555/shorebird/pull/112)) | Lets the R12 scripts run on a Linux Docker engine and on a pin other than 3.44.8; defaults stay on the certified pin. | The review's should-fix items, before the next promotion attempt. |

## The CDN mirror on ci-build

Our engines (`3a565f27`, `255fd850`, `7806e0fb`, and `2c4b0718`, which shorebird-flutter now pins) are not on `download.shorebird.dev`. On the LAN they are served by the mirror, the
`selfhost/cdn` compose stack on ci-build (`shorebird-cdn-*` containers, restart
`unless-stopped`), on port 8085.

- **Plain HTTP.** Gradle refuses plain-HTTP Maven repositories, so an app's Android build
  needs `isAllowInsecureProtocol` until the HTTPS listener is on. That is
  `selfhost/cdn/tls/trust.sh`, which needs root on the host: the owner's to run.
- **Off-host copy.** The overlay bytes and the `3a565f27 -> 38855c84` map line are also
  on the GitHub release `engine-3a565f273d871d1ef004faf1a87bf45637df8ad0` in
  shorebird-flutter, with a `SHA256SUMS`. The repo's `experimental_hashes.map` still does
  not have that line; it gets it with the promotion.
- **`255fd850` is installed** in the ci-build mirror too (2026-11-10). The Caddyfile has
  `admin off`, so apply a config change with `docker restart shorebird-cdn-cdn-cache-1`.
- **`2c4b0718` is installed** (2026-11-11): all 64 files serve with `X-Overlay: hit`, and the
  Caddyfile from #118 protects its per-hash files. `audit_overlay.sh` is clean for `7806e0fb`
  and `2c4b0718` in each cell it was run on: `linux-android`, `macos-ios` and
  `macos-ios-android`.
- **`7806e0fb` is installed** too (2026-11-10): all 63 files serve with `X-Overlay: hit`.
  Its first `sky_engine.zip` was a 4-file stub packaged from `out/host_debug`; the release was
  republished from `out/android_release_arm64`, and `publish_sky_packages.sh` now refuses a
  stub (#110). Its `sky_engine` and `flutter_gpu` are route-protected since #118's Caddyfile
  (2026-11-11), and the audit above is clean for it.
- **Gaps closed by #100.** `sky_engine.zip`, `flutter_gpu.zip` and the arm64
  `maven-metadata.xml` are published and route-protected for `255fd850` and `3a565f27`,
  and so are the per-hash `linux-x64` and `darwin-x64` `font-subset.zip` (ours is built with
  the fork's `const_finder`, so the stock one breaks releases). The release tars
  hold them as `overlay-extra-<hash>.tar`, pinned by `SHA256SUMS.extra`. `3a565f27`'s sky
  and gpu were packaged from the `255fd850` tree; none of their 290 build inputs differ
  (recorded in its `PROVENANCE.txt`). `audit_overlay.sh` is clean for `255fd850` on all four
  cells, including the new `macos-x64`. For `3a565f27` it is clean except the iOS cells:
  it has no iOS engine.
- **Cold `/gcs/` fetches used to stall, then 504.** The cache handler (Souin) gave each
  upstream fetch a 10 s deadline for the whole body. A cold artifact that took longer
  (`dart-sdk-*.zip`, about 150 MB, took 8 s to 17 s) was cut off at exactly 10 s with
  `Cache-Status: Souin; fwd=bypass; detail=DEADLINE-EXCEEDED`, nothing stored. Fixed by a
  `timeout { backend 10m }` in the Caddyfile's `cache` block, with `dial_timeout 10s` and
  `read_timeout 60s` on the upstream so a dead or stalled upstream still fails fast. An
  earlier version of the fix has run on ci-build since 2026-11-10; this one is live once
  PR #106's deploy steps are done.
- **Fixed: the mirror's memory grew with its cache** (task 11b). Two causes:
  - The Caddyfile set only `path`, so NutsDB ran in its default `HintKeyValAndRAMIdxMode`,
    which keeps every value in its index. The key-only `HintKeyAndRAMIdxMode` has to go in
    `configuration` with `Dir`: storages/nuts ignores `path` once `configuration` is set.
  - That alone made no difference after a restart, which is what the earlier scratch test
    measured (686 MB against 687 MB for a 680 MB cache). NutsDB v1.0.4's `ParsePayload`
    makes the key a sub-slice of the buffer holding key and value, and recovery keeps the
    key in the index and in the expiry callback of every entry with a TTL, which every
    cached response has. A heap profile put 816 of 829 MB in `fileRecovery.readEntry`.
    [`cdn/nutsdb-v1.0.4-key-copy.patch`](cdn/nutsdb-v1.0.4-key-copy.patch) copies the key;
    the Dockerfile and `run_native.sh` build Caddy with it (NutsDB pinned by commit) and
    fail if the binary does not link it.

  Measured on ci-build with 1 GB cached: after a restart 140 MB (was 1,080 MB), after reading
  it all back 446 MB with `GOMEMLIMIT=1GiB` (was 2,041 MB), all hits with matching bytes. The
  compose file now sets `GOMEMLIMIT=1GiB` and `mem_limit: 8g` (a cold fetch holds 3-5 copies of
  the response, about 1 GB for a dart-sdk zip). Not measured: NutsDB's merge every 2 h, which
  rewrites live entries once there are two segments.

  Deployed to the live mirror on 2026-11-12 (it was at 4.8 GiB). Its 3.1 GB cache carried
  over: cached files still hit with the same sha256. About 530 MB after the restart; repeated
  reads of the 233 MB dart-sdk zip level off at about 1.0 GB, the `GOMEMLIMIT` target. The
  ci-build checkout got only the Dockerfile, compose file, patch and the Caddyfile's `nuts`
  block from main (backups `*.bak.20261112035903`); the previous image is tagged
  `shorebird-cdn-cdn-cache:pre-nutsfix-20261112035903` for a rollback.

<a id="ios-on-255fd850"></a>

## iOS engines (`255fd850`, `7806e0fb`)

What follows was measured on `255fd850`.

The iOS engine runs releases but takes no code patches (`shorebird_use_interpreter` is off).
The same holds for `7806e0fb`; see [Device runs on `7806e0fb`](#device-runs-on-7806e0fb) for the physical iPhone run.
What has been checked, 2026-11-10:

- **Simulator** (iPhone 17, iOS 27, debug, the only mode a simulator runs): host widget test,
  `flutter build ios --simulator --debug` and an integration test pass on Flutter
  `8b6a30d0` with artifacts from the mirror.
- **Release build** with the fork CLI and Flutter `8b6a30d0` needs:
  - `SHOREBIRD_ARTIFACT_ORIGIN=<mirror>`. With only `FLUTTER_STORAGE_BASE_URL` set, the
    patch tool and `aot-tools` still come from `storage.googleapis.com` and 404. Since #98
    the failure says so.
  - `SHOREBIRD_PUBLISHED_IOS_ENGINE_DIR` holding `{ios,ios-profile,ios-release}/artifacts.zip`,
    or the toolchain coherence check stops with `COHERENCE_UNDETERMINABLE`. Since #123 the
    variable is optional: unset, the CLI fetches the three zips from the mirror once per
    engine and keeps their digests.
  - #99. Before it, the CLI took `255fd850` for a Route B engine (it contains vanilla Dart's
    `InterpretCall`), built with patchable call sites and refused its own release.
- **Engine stamp.** The framework `Info.plist` `FlutterEngine` key in this release reads
  `3a565f27`: `copy_info_plist.py` stamps `git rev-parse HEAD` and ninja does not rerun it.
  Nothing reads it, so it is a label only. #97 fixed it: in `7806e0fb` the key reads `7806e0fb`.

## iOS code push on `2c4b0718` (Route B)

Route B is the fork's own iOS patch mechanism, built only on public Dart and Flutter. A Route B patch replaces individual Dart functions; by design the release runs the replaced functions in Dart's bytecode interpreter (`InterpretCall`). It is not upstream Shorebird's linker path (open item 11). Since `2c4b0718` the iOS release engine is built with `shorebird_route_b=true dart_dynamic_modules=true`, so the updater starts on iOS. Checked 2026-11-11, with the fork CLI from `main` merged locally with the #111 branch (`flutter.version` = shorebird-flutter `efe3162e`, the head of #12; nothing pushed), a local code push server and the ci-build mirror:

- **Physical iPhone 7** (iOS 15.8.8; logs in [shorebird-flutter#12](https://github.com/mml555/shorebird-flutter/pull/12#issuecomment-6800938572)): release 1.0.0+1 launched and downloaded patch 3. The next launch logged `active patch is a Route B container`, `ROUTEB: applied 1/1 targets` and showed the patched marker. So did the launch after. After a rollback through the server API, the next launch received the rollback and the one after ran the release again. Patches 1 and 2 were spent on test-harness problems (below), not engine faults. The logs show the patch applied; they do not show which calls ran in the interpreter.
- **Simulator** (iPhone 17e, iOS 27, debug): widget test, `flutter build ios --simulator --debug` and an integration test pass. Debug builds do not start the updater, so no patch runs on a simulator.
- **Release build**: `shorebird release ios` compiles calls so a patch can redirect them (patchable call sites). The CLI estimates this at about +4.5% app size; shorebird-flutter #10 measured +1.4% on the framework. The release then checks that the build carries enough of them: 1812 per MiB on a probe app, against a floor of 100 per MiB. Since #120 that line prints by default. The framework's `FlutterEngine` stamp reads `2c4b0718`.

Limits:

- A patch can carry only some kinds of Dart change; the rest are refused at `shorebird patch` time. On 3.44-era engines a replay of real app histories accepted 50% of the observed method changes in Wonderous (20 observations; 45% before the retention rerun) and 92.67% in LocalSend (232 observations); see [`producer_demand_2.md`](engine/route_b/evidence/producer_demand_2.md). The owner decided on 2026-11-11 not to re-measure them on 3.47, so the only measurement is the 3.44 one, not a 3.47 result. The replay could not be re-run as it was: its frozen corpus (`/Volumes/build/route-b/demand1`) is on neither this Mac nor ci-build, the scripts under `engine/route_b/coverage/` hard-code `/Volumes/build` and `/Users/mendell`, and the mirror holds only the `darwin-arm64` Route B compiler.
- `2c4b0718` is not a qualified cell: `engine/route_b/SUPPORTED_STATE.yaml` names only the `f85251f3` cell, and the release's lookup of `cell-manifests/2c4b0718….v2` gets a 404 and falls back to v1 (seen in the `-v` log).
- Before #123, release builds needed `SHOREBIRD_PUBLISHED_IOS_ENGINE_DIR`; the CLI now fetches the published iOS engines (about 175 MB, once per engine) when it is unset.
- iOS asks the user once per install before an app may reach a LAN address, so a device test against a LAN server needs one tap on "OK". Observed on this phone: a reinstall resets it, and a build signed with another app's application-identifier stayed blocked after the tap. Inferred from the `nehelper` and `UserEventAgent` logs: the permission is keyed to the bundle ID iOS first saw for the executable's Mach-O UUID, so a build re-signed under a second bundle ID is blocked too.

## Device runs on `7806e0fb`

2026-11-10, release builds only, with the fork CLI 1.6.138 built from the #111 branch (`flutter.version` = shorebird-flutter `9056dae9`, nothing committed to it), a local code push server, and the ci-build mirror.

- **Android, physical** (OnePlus CPH2551): release 1.0.0+1 installed and showed its marker; a patch published with `--release-version` was downloaded on the next launch and showed the patched marker after a restart and again after a second one. The marker is read from `uiautomator dump`, as in `scripts/android1_device.sh`. The engine's updater is `87c198d30f87` (shorebird-flutter DEPS), seen in `libflutter.so` and in the device's `__patch_download__` and `__patch_install__` events.
- **iOS, physical** (iPhone 7, iOS 15.8.8, resign mode with the team wildcard development profile): the release installs and runs, the log shows its marker and `This engine cannot run iOS patches, not starting the Shorebird updater.`, and `shorebird patch ios` refuses. No iOS patch was attempted on the device: `shorebird patch ios` refuses before building. That is the expected result until item 11.

Found on the way. None has an issue; each is small enough to fix with the next mirror or engine change, and the ones fixed since say so:

- Fixed: the six `ios-usb-dependencies` zips that `flutter precache` fetches were not in the overlay, so the mirror fetched them from upstream GCS through its `/gcs/` passthrough, which a sealed mirror refuses. [`cdn/publish_flutter_pins.sh`](cdn/publish_flutter_pins.sh) now copies them, `fonts.zip` and `gradle-wrapper.tgz` into the overlay, read from a Flutter checkout's pins and checked against GCS's md5. Run on ci-build 2026-11-11: all eight serve with `X-Overlay: hit`.
- `aot-tools.dill` for `7806e0fb` 404s on the mirror (Android does not need it).
- A bare `flutter create` reaches `download.shorebird.dev` and `storage.googleapis.com` unless `FLUTTER_STORAGE_BASE_URL` points at the mirror first.
- `shorebird release ios` on `7806e0fb` stops with `COHERENCE_UNDETERMINABLE` until `SHOREBIRD_PUBLISHED_IOS_ENGINE_DIR` points at the three `ios*/artifacts.zip` from the overlay (fixed by #123: the CLI fetches them itself).
- An app with an `http://` `base_url` needs cleartext allowed: `usesCleartextTraffic` on Android, an ATS exception on iOS.
- Profile and debug engines for `7806e0fb` are not built; the mirror serves those from the stock fallback engine, so a profile or debug build pairs a stock engine with our framework and its behaviour is untested.

## Stable baseline

The project is at a stable point when every row is done.

| # | Condition | State |
|---|---|---|
| 1 | `main` CI green on the home runners | Done: the last push run on `main` passed on the home runners (2026-11-08) |
| 2 | No stale PRs or branches | Done, except the snapshot branches below |
| 3 | Server release matches what compose pins | #86 is merged, tag `code_push_server-v1.4.0` exists and `release_code_push_server` last passed on 2026-11-09. Owner to confirm the 1.4.0 image is the one compose pulls |
| 4 | Docs and manifests name the current revisions | No: `selfhost/compatibility.yaml` still declares CLI 1.6.115 and Flutter `a4a3c0d1`; bump it with the 3.47.9 promotion |
| 5 | Release and patch proven on the current engine | Partly: proven on `3a565f27`, and on `7806e0fb` (which shorebird-flutter now pins) on a physical Android phone with the CLI from the #111 branch, not the CLI's current pin; iOS runs releases only there (see [Device runs on `7806e0fb`](#device-runs-on-7806e0fb)). On `2c4b0718` an iOS release and a Route B patch, plus rollback, ran on the physical iPhone 7 (2026-11-11, same CLI setup; see [iOS code push on `2c4b0718`](#ios-code-push-on-2c4b0718-route-b)). Done by hand, not in CI: on 2026-11-09 release 1.0.3+4 and patch 1 ran end to end on an x86_64 emulator with the CLI downloading engine `3a565f27` through the CDN mirror (no `--local-engine`), host tools included. Proof with screenshots: [shorebird-flutter#1](https://github.com/mml555/shorebird-flutter/pull/1#issuecomment-6735022921) |
| 6 | Publish durability shown (no vanished publishes) | Not reproduced in an API-driver run on 1.4.0 (2026-11-10), see the limits in item 3 below. Not yet shown |
| 7 | No unbounded growth on devices | Open, item 2 below |
| 8 | Device or emulator signal in CI | Open, item 5 below |
| 9 | `PATCH_SIGNING_KEY_SECRET` and `.env` backed up off the server | Owner to confirm. Losing the key means no device accepts new patches ([`backup_restore/SECRETS_BOUNDARY.md`](backup_restore/SECRETS_BOUNDARY.md)) |

## Open items, in the order to do them

Effort: S under a day, M a few days, L a week or more.

| # | Item | Effort | Notes |
|---|---|---|---|
| 1 | Promote the 3.47.9 engine | M-L | **Blockers fixed (merged):** the `_data` NoSuchMethodError hit every AOT program built with the fork's Dart 3.13.7, app code included. It came from a hash-accessor guard in `aot_call_specializer.cc`, and the dart2js and DDC platform builds rejected the new `external` members in `dart:_internal`. Both are fixed in [dart-sdk-shorebird-lineage#1](https://github.com/mml555/dart-sdk-shorebird-lineage/pull/1) and proven on ci-build. `build.sh --cell` now builds the host toolchain, including `linux-x64/artifacts.zip` with `impellerc`, and `overlay_publish.sh` publishes it. PR #1's conflicts are resolved and it is merged; the release + patch passed through the mirror; the engine is published there. Done since: the engine is on GitHub releases that CI downloads, and shorebird-flutter #2, #4 and #8 pin it (now `7806e0fb`). Left: bump `bin/internal/flutter.version` and `compatibility.yaml`. That is [#111](https://github.com/mml555/shorebird/pull/111): its artifact gates pass, and it is on hold over R12 arm 3 (see In flight). Bumping `flutter.version` makes every fork CLI need the mirror, so do it with the promotion (sealed cold bootstrap closure, `bootstrap_closure_guard.sh`, sealed smoke), not before. Rules in [`TOOLCHAIN_PROMOTION.md`](TOOLCHAIN_PROMOTION.md). `eligibleUpdaterRevisions` is frozen by [`MEASUREMENT_MODE.md`](MEASUREMENT_MODE.md): changing it is the owner's call. |
| 1a | ~~Alert when CI jobs sit queued~~ | Done | `ci-host/bin/gha-watch`, cron under `oem` on ci-build every 10 minutes; see `ci-host/README.md`, "Watch the runners". It logs to `~/.local/state/gha-watch/warnings.log`; it opens a GitHub issue only once the owner puts a `GH_TOKEN` in `~/.config/gha-watch.env`. |
| 2 | Bound the updater's diag logs | S | `state_diag.log` and `success_diag.log` are appended on every launch and never cleaned (`vendor/updater/SELFHOST_PORT_ca91f4b3.md`). Rotate or cap in the mirror, then re-vendor. **Merged:** [mirror#11](https://github.com/mml555/shorebird-updater-mirror/pull/11) caps each at 64 KiB plus one rotation; the engine gets it when `updater_rev` moves (the owner's call); a device's existing oversized log is deleted at its first append. |
| 3 | Re-test vanished publishes | M | Not reproduced on 1.4.0 in an API-driver run (2026-11-10): 447 releases and 445 patches through an API driver (Android only, artifacts up to 200 KB, SQLite, process kill and a starved container, read back minutes later): 0 lost. Not shown: the real CLI, user-OAuth, the iOS flow, large artifacts, Postgres/S3, power loss, the API read path, same-version retries, anything that runs hours later (retention or reclaim). The 2026-08 cause stays unknown. Evidence and limits: [`evidence/publish-durability-1.4.0/`](evidence/publish-durability-1.4.0/README.md). Keep open as a re-run check after a server upgrade. |
| 4 | Updater: map the HTTP client's `ConnectProxyFailed` to a transport error | S | Today a proxy refusal surfaces differently from a direct network failure; #84 works around it in CI only. **Merged:** [mirror#11](https://github.com/mml555/shorebird-updater-mirror/pull/11) maps it to `NetworkError::Transport` in the ureq builds only (Linux, Windows). Android, iOS and macOS use the engine client, which already reports `HttpError::Transport`; they are unaffected. Moving `updater_rev` is the owner's call. |
| 5 | E2E on the emulator pool | M | All e2e legs need `HOSTED_RUNNERS`. The home emulator pool can serve them; the `3a565f27` engine now includes android-x64, which the pool's x86_64 images run (proven 2026-11-09 by hand). |
| 6 | S3 client retries | S-M | `packages/code_push_server/lib/src/s3_client.dart` has none; a transient S3 error fails the upload. |
| 7 | Document that a proxy must pass `/api/v1/patches/events` | S | Unauthenticated POST; a proxy that blocks it drops install events silently. Belongs in `packages/code_push_server/PRODUCTION.md`. |
| 8 | Make `dart test --concurrency` a workflow input | S | Hard-coded to 4 in `.github/workflows/_shorebird_ci_dart.yaml`. |
| 9 | pub.dev publish via OIDC | S | Wired in `publish_dart_package.yaml`, never exercised. One dry run. |
| 10 | arm64 server image | M | Releases are amd64 only without hosted runners (buildx + QEMU or an arm64 runner). |
| 11 | iOS code push and `aot-tools.dill` | L | **Route B done on `2c4b0718`** (shorebird-flutter #9 ports the 3.44-era Route B engine changes, #10 builds the iOS engine with them, #11 fixes its gn check, #12 pins it; fork #115 and #116): iOS release, patch and rollback ran on the physical iPhone 7; see [iOS code push on `2c4b0718`](#ios-code-push-on-2c4b0718-route-b). The owner decided on 2026-11-11 not to re-measure on 3.47 the share of Dart changes a patch accepts; only the 3.44 numbers exist. Left: qualify `2c4b0718` in `SUPPORTED_STATE.yaml`, which has to name the CLI revision and shorebird-flutter pin that #111 lands, so it waits for #111; land the CLI side through the promotion (#111, on hold; re-pin it to shorebird-flutter `d12e29ec` first). Upstream's own iOS patch path (`Shorebird_ReadLinkHeader`, the five-argument `Dart_LoadELF`, `aot_tools`) lives in Shorebird's private Dart fork and is not pursued; `aot-tools.dill` belongs to it, does not build, and the mirror 404s it. |
| 11a | ~~Diagnose the mirror's cold `/gcs/` fetch hang~~ | Done | Souin's 10 s default backend timeout; see the CDN section. |
| 11b | Find why the mirror holds its whole cache in RAM | M | **Fixed:** key-only NutsDB index plus a one-line NutsDB patch; 140 MB after a restart instead of the cache's size. Deployed to the live mirror 2026-11-12. See the CDN section. |
| 12 | Apple and desktop paths in CI | L | iOS code push is proven by hand on the physical iPhone 7 with `2c4b0718` (and earlier with 3.44-era Route B engines), not in CI; macOS, Windows and Linux code push are untested ([`DESKTOP_PLATFORMS.md`](DESKTOP_PLATFORMS.md)). Needs a Mac runner. |

Owner decisions, no code needed:

- `ios_framework_patcher.dart` from the closed cw05 PR is the one file never on `main`.
  Glance at `archive/cw05-other-platforms` and keep or drop it.
- Snapshot branches `preserve/*` (three) and `worktree-wf_88d81758-e2a-1`, `-4` hold a few
  files not on `main`, most likely replaced by later rewrites. Archive or delete.
- `stable` is an old ancestor of `main`; keep only if something pins it.
- The `selfhost/` folder has 44 top-level docs, several of them dated handoffs.
  Archiving the `HANDOFF-*` files would make the index easier to use.

Longer research lines, not blocking: foldable-constant patches that attach but do nothing
([`STATE_OF_THE_SYSTEM.md`](STATE_OF_THE_SYSTEM.md)), progressive rollout with no client
surface ([`WORKFLOW_CERTIFICATION.md`](WORKFLOW_CERTIFICATION.md)), Route B `super.foo()`
on device ([`ROUTE_B.md`](ROUTE_B.md)), and the mutable-AOT line
([`engine/mutable_aot/`](engine/mutable_aot)).
