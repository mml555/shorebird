<!-- cspell:words sdkmanager -->
# Getting started: from nothing to a patched app

This is the one path from a machine that has never seen this project to a Flutter
app released and patched through your own server. It takes four pieces, all run
on your machines:

| Piece | What it is | Started by |
|---|---|---|
| Server | `code_push_server`, which the CLI and your apps talk to instead of `api.shorebird.dev` | `packages/code_push_server/setup.sh` |
| Artifact mirror | Serves this fork's Flutter engine to the CLI. Upstream's `download.shorebird.dev` does not have it, so **it is required**, not optional | `selfhost/scripts/bootstrap_selfhost.sh --start-mirror` |
| CLI | This fork's `shorebird`, pinned to the engine above. Upstream's installer installs upstream's CLI, which does not work here | the same bootstrap |
| Your app | Any Flutter app | you |

What works and what does not, platform by platform, is in
[`UPSTREAM_PARITY.md`](UPSTREAM_PARITY.md). In short: Android is proven in CI on an emulator; iOS
is proven on one iPhone by script and patches a subset of Dart changes; desktop and add-to-app
are not supported yet.

## 1. Prerequisites

- **Linux (x86_64, glibc) or macOS.** Alpine and other musl systems cannot run the Dart
  SDK the CLI downloads. iOS needs a Mac with Apple silicon: the iOS patch compiler is
  built for it only.
- `git`, `curl`, `unzip`, `python3`, `bash`.
- **Docker with the Compose plugin** (`docker compose version` must work). On Ubuntu
  that is the `docker.io` and `docker-compose-v2` packages; Docker Desktop has both.
- Several GB of disk: the engine download alone is 1.6 GB, kept beside its unpacked copy,
  plus the CLI's Flutter, the mirror's Docker images and its cache.
- For Android: a JDK 17 and the Android SDK (command-line tools, `platform-tools`, a
  platform and build tools, installed with `sdkmanager`), with `ANDROID_HOME` set to it;
  `flutter doctor` names what is missing.
- For iOS: macOS with Xcode, and an Apple developer account to sign the app.

Ports used on the machine: 8080 (server) and 8085 (mirror).

## 2. Install the CLI and start the mirror

Pin a release: pick the newest `selfhost-v*` tag on the
[tags page](https://github.com/mml555/shorebird/tags), `selfhost-v1.2.1` or newer
(older tags cannot install on Linux), and use it for both the script and `--ref`:

```bash
TAG=selfhost-v1.2.1
curl -fsSL "https://raw.githubusercontent.com/mml555/shorebird/$TAG/selfhost/scripts/bootstrap_selfhost.sh" \
  -o bootstrap_selfhost.sh
bash bootstrap_selfhost.sh --root ~/shorebird-selfhost --ref "$TAG" --start-mirror
```

It then:

1. clones this repository at the tag into `~/shorebird-selfhost/shorebird`;
2. checks out the CLI revision the tag pins, into `~/shorebird-selfhost/runtime`;
3. downloads the engine from the tag's GitHub release (about 1.6 GB), checks every
   file against the digests committed in
   [`engine/route_b/SUPPORTED_STATE.yaml`](engine/route_b/SUPPORTED_STATE.yaml), and lays it
   out for the mirror;
4. starts the mirror on `http://127.0.0.1:8085` with Docker;
5. runs the CLI once, so it fetches its pinned Flutter and engine through the mirror;
6. verifies the whole stack, and prints three lines to add to your shell profile:

```bash
export PATH="$HOME/shorebird-selfhost/runtime/bin:$HOME/shorebird-selfhost/runtime/bin/cache/flutter/<revision>/bin:$PATH"
export SHOREBIRD_ARTIFACT_ORIGIN=http://127.0.0.1:8085
export FLUTTER_STORAGE_BASE_URL=http://127.0.0.1:8085
```

The second `PATH` entry is the Flutter this CLI pins (`<revision>` is filled in for you).
Use that `flutter`, not another one you have installed: the app must be built with the
same Flutter as its releases.

Every step prints `PASS` or `FAIL`; it ends with `BOOTSTRAP COMPLETE` or the number
of failures. Logs are in `~/shorebird-selfhost/*.log`. Running it again is safe: it
reuses what it already downloaded.

`SHOREBIRD_ARTIFACT_ORIGIN` must be set whenever you run `shorebird`, and
`FLUTTER_STORAGE_BASE_URL` whenever you run that `flutter`. Without them they ask
`download.shorebird.dev` for an engine that is not there: `shorebird` fails with an
`unzip` error, `flutter` with a 404.

The mirror fetches the stock Flutter files it does not hold (the same for every
Flutter app) from Google's public storage the first time, and caches them.

## 3. Start the server

```bash
cd ~/shorebird-selfhost/shorebird/packages/code_push_server
./setup.sh
```

It prints the server URL (your machine's LAN address, port 8080), an API key and the
console URL. The URL must be one your phones can reach, because the app checks it for
patches. For HTTPS on a real domain, see
[`packages/code_push_server/README.md`](../packages/code_push_server/README.md).

```bash
export SHOREBIRD_HOSTED_URL=<the server URL it printed>
export SHOREBIRD_TOKEN=<the API key it printed>
```

## 4. Release and patch an Android app

```bash
shorebird --version            # the first run in a new shell checks the pinned Flutter
flutter create my_app          # or use your own app
cd my_app
shorebird init                 # creates the app on your server and writes shorebird.yaml
```

Open the checked-in `shorebird.yaml` that `init` wrote and add your server's URL, so the
app asks your server, not Shorebird's, for patches:

```yaml
app_id: <written by init>
base_url: <the server URL>
```

If your server URL is plain `http://`, Android blocks it in release builds. Add
`android:usesCleartextTraffic="true"` to the `<application>` element of
`android/app/src/main/AndroidManifest.xml`, or put the server behind HTTPS.

```bash
shorebird doctor --fix         # adds the INTERNET permission the updater needs
shorebird release android      # builds and uploads the release
```

Install the release on a device (the `.aab` is in `build/app/outputs/bundle/release/`;
`shorebird release android --artifact apk` builds an `.apk` to install directly).
Change some Dart code, then:

```bash
shorebird patch android
```

Start the app, close it, and start it again: the patch is downloaded on the first
launch and runs from the second. The console at `<server URL>/console` shows the
release, the patch and the installs.

## 5. iOS

The same steps with `shorebird release ios` and `shorebird patch ios`, on macOS with
Xcode. What differs:

- iOS patches use this fork's interpreter (Route B, [`ROUTE_B.md`](ROUTE_B.md)), not
  upstream's. Many kinds of Dart change are refused at `shorebird patch` time, with a
  message naming the change; a release can always be shipped instead.
- The app reaches your server over the local network, so iOS asks the user once per
  install to allow it.
- Native changes are not refused, as upstream: only a changed `Podfile.lock` stops a
  patch, and apps that use Swift Package Manager (Flutter's default) have none. Ship
  a release for native changes.

## When something fails

- `unzip: End-of-central-directory signature not found` on the first `shorebird` run:
  `SHOREBIRD_ARTIFACT_ORIGIN` is not set, or the mirror is not running
  (`docker compose -f ~/shorebird-selfhost/shorebird/selfhost/cdn/docker-compose.cdn.yaml ps`).
- `setup.sh` stops with `The Docker Compose plugin is required`: install the Compose
  plugin (step 1).
- A `FAIL` line from the bootstrap: the line names the step and its log.

The mirror's internals, and running it without Docker, are in
[`cdn/README.md`](cdn/README.md).
