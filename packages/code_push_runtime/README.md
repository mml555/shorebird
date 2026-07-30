# code_push_runtime

App-side runtime for a self-hosted Shorebird control plane
([`code_push_server`](../code_push_server)). Two jobs, both of which exist
because a self-hosted control plane can do things the hosted service does not:

| | |
|---|---|
| **Patched assets** | Serves the `flutter_assets` bundle attached to the running patch, so a patch can change images, fonts and JSON — not only Dart code. |
| **Crash reporting** | Reports Dart crashes with the `(app, release, patch, arch)` tuple the server needs to symbolicate them against the debug symbols retained for that patch. |

Neither needs an engine build, a modified updater, or Shorebird's private Dart VM
fork — which is the whole point. Both work on Android and iOS.

## Usage

```dart
import 'package:code_push_runtime/code_push_runtime.dart';
import 'package:package_info_plus/package_info_plus.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final runtime = await CodePushRuntime.initialize(
    readReleaseVersion: () async {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    },
  );

  runApp(
    DefaultAssetBundle(bundle: runtime.assetBundle, child: const MyApp()),
  );
}
```

`readReleaseVersion` is injected rather than read for you: Flutter does not
bundle the app version anywhere this package can reach on every platform, and
taking a platform-channel dependency to discover it would make the package
impossible to test without one. Any source works as long as it matches the
release version the CLI published (`shorebird release` prints it).

Everything else is read from the `shorebird.yaml` that `shorebird init` already
bundles as an asset, so there is no second place to configure a server.

## Inert unless you self-host

With no `base_url` in `shorebird.yaml` the app is talking to Shorebird's hosted
service, which offers neither endpoint this package uses. In that case
`initialize` returns a runtime whose `assetBundle` is just `rootBundle` and whose
crash reporter is absent. Nothing fails; nothing is sent.

## Behavior worth knowing

**Assets are an overlay, not a replacement.** A key the patch bundle does not
carry still resolves from the app's compiled-in assets, so a patch that changes
one file cannot make the rest disappear.

**The asset fetch is not atomic with the code patch.** It is a second network
request, so a bundle is stored under its patch number, served *only* while that
patch is the one running, and every other patch's bundle is deleted as soon as a
different one is. That is what keeps a rollback from pairing new assets with old
code.

**A bundle is published only once it is complete.** It unpacks into a staging
directory, gets a completion marker, then moves into place in one rename — so an
interrupted unpack can never be mistaken for a finished one. Bundles are also
rejected if their hash does not match, which catches a truncated transfer before
it becomes a cached directory that looks fine and serves broken assets forever.

**Crash reporting chains, it does not replace.** `FlutterError.onError` and
`PlatformDispatcher.instance.onError` are wrapped, and whatever was there before
still runs — an app using Crashlytics keeps it, and in debug Flutter's default
handler still prints the red screen. Reporting never throws: the caller is an app
that is already failing, and a reporter that throws from an error handler turns
one fault into a loop.

**Crashes are Dart-level.** A release build's stack trace is a Dart trace, and
the symbols the CLI retains (`--split-debug-info`) resolve exactly that. Native
frames would need a crashpad-style collector in the engine — a separate and much
larger piece of work.

## Requirements

- The control plane must be new enough to serve `POST /patches/assets`. The
  image pinned in `code_push_server/docker-compose.yaml` may predate it.
- Patches must be published with `shorebird patch --assets` for a bundle to
  exist, and with `--split-debug-info` for crashes to be symbolicatable.

## Tests

Standalone package with its own lockfile, like `code_push_server`:

```bash
cd packages/code_push_runtime && flutter test
```
