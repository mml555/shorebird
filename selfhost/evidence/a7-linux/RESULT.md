<!-- cspell:words sdkmanager dind -->
# A7: a clean Linux machine, following GETTING_STARTED.md

2026-11-13, on ci-build. The test machine was a fresh `ubuntu:24.04` container with its own Docker
daemon: privileged, `/var/lib/docker` on a volume, and the cgroup v2 nesting set up at PID 1, as
the official dind image does. Those three settings belong to the test harness, not the guide. The
container started with nothing installed.

**Prerequisites**, installed as the guide's step 1 names them:
- from apt: git, curl, unzip, python3, docker.io, docker-compose-v2, openjdk-17;
- Android command-line tools, and through `sdkmanager`: platform-tools, platform 35, build-tools 35;
- `ANDROID_HOME` set.

## Three runs

1. **Docs only, at `selfhost-v1.2.0`.** The server came up, then the run stopped: no doc said how
   to install the CLI. Running the repository's `bin/shorebird` failed fetching the Dart SDK of
   engine `82fc78a8` from `download.shorebird.dev`, with
   `unzip: End-of-central-directory signature not found`. That engine is not there.
2. **`GETTING_STARTED.md` at `d962b981`** (#157), with the bootstrap pinned there by `--ref`:

| Guide step | Result |
|---|---|
| 2 bootstrap `--start-mirror` | `BOOTSTRAP COMPLETE`: 30/30 cell members verified, host extras matched the record, the mirror served the cell, the CLI reported engine `82fc78a8`, `SUPPORTED STATE VERIFIED` |
| 3 `setup.sh` | exit 0, server ready |
| 4 `flutter create my_app` | failed with the guide as written: no `flutter` on `PATH`, and the pinned `flutter` asked `download.shorebird.dev` for `sky_engine.zip` (404). With the Flutter `bin` on `PATH` and `FLUTTER_STORAGE_BASE_URL` set to the mirror, it passed. The guide and the bootstrap's closing lines now include both |
| 4 `shorebird init` | exit 0, wrote `app_id`; `base_url` added by hand as the guide says |
| 4 `shorebird doctor --fix` | exit 0 |
| 4 `shorebird release android` | exit 0. Gradle took the engine's Maven artifacts from the plain-HTTP mirror at `127.0.0.1` without an `isAllowInsecureProtocol` opt-in: Gradle exempts loopback (see run 3) |
| 4 `shorebird patch android` | exit 0, "Published Patch 1!" |
| server | release `1.0.0+1` active for android, Flutter `f6bbc8a0` |

3. **`GETTING_STARTED.md` at the tag `selfhost-v1.2.1`** (`3503834a`), in a new clean container,
   every command as the guide writes it: the bootstrap script fetched from the tag with `curl`,
   `--ref "$TAG" --start-mirror`, and the three `export` lines taken from the bootstrap's own
   output. Every step exited 0: bootstrap (`BOOTSTRAP COMPLETE`), `setup.sh`, `shorebird --version`,
   `flutter create`, `init`, `doctor --fix`, `release android`, `patch android` ("Published Patch
   1!"). The server held release `1.0.0+1` active for android and patch 1 active on `stable` at
   100% rollout.

   Then, in the same container, the plain-HTTP question. Gradle 9.3.1 (from the app's wrapper)
   fetched the engine's `.pom`s from `http://127.0.0.1:8085` in the release above. `flutter build
   apk --release` with `FLUTTER_STORAGE_BASE_URL` set to the same mirror at its LAN address,
   `http://172.17.0.2:8085`, failed: `Using insecure protocols with repositories, without
   explicit opt-in, is unsupported.` With the opt-in from `cdn/README.md` added to
   `android/build.gradle.kts` it built, and the mirror logged 24 `download.flutter.io` requests at
   that address. So the opt-in is needed only for a mirror on another machine.

## Hosts

The mirror served the build:
- 26 `flutter_infra_release` requests, the cell's files;
- 8 `download.flutter.io` (Maven);
- 2 `download.shorebird.dev` paths, from the overlay;
- 10 `/gcs` requests: stock Flutter files fetched once from Google's public storage, as the guide says.

Outside the mirror, the walkthrough contacted:
- github.com, for the clone and the release assets;
- pub.dev;
- Docker Hub;
- Google's Android SDK repository;
- the hosts `shorebird doctor` probes, `console.shorebird.dev` and `cdn.shorebird.cloud`. These are reachability checks in upstream's CLI and carry no data.

## Not covered

- A device: nothing was installed or booted.
- iOS.
- macOS as the host.
