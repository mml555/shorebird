import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:code_push_runtime/src/crash_reporter.dart';
import 'package:code_push_runtime/src/environment.dart';
import 'package:code_push_runtime/src/patch_asset_bundle.dart';
import 'package:code_push_runtime/src/patch_asset_store.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

/// Reads the running release's version, e.g. `1.0.0+1`.
///
/// Injected rather than read from a plugin because Flutter does not bundle the
/// app version anywhere this package can reach — `version.json` is not in
/// `flutter_assets` on every platform — and pulling in a platform-channel
/// dependency to discover it would make this package untestable without one.
typedef ReleaseVersionReader = Future<String?> Function();

/// App-side runtime for a self-hosted Shorebird control plane.
///
/// Two jobs, both of which exist because the control plane can do something
/// Shorebird's hosted service does not: serve the assets attached to a patch,
/// and symbolicate crashes against the symbols retained for it.
///
/// ```dart
/// final runtime = await CodePushRuntime.initialize(
///   readReleaseVersion: () async => '1.0.0+1',
/// );
/// runApp(DefaultAssetBundle(bundle: runtime.assetBundle, child: MyApp()));
/// ```
///
/// Inert unless the app is talking to a self-hosted control plane: with no
/// `base_url` in `shorebird.yaml` there is no server offering these endpoints,
/// so [assetBundle] is just [rootBundle] and nothing is reported.
class CodePushRuntime {
  CodePushRuntime._({
    required this.assetBundle,
    required this.patchNumber,
    required this.crashReporter,
  });

  /// The bundle to read assets through. Serves the running patch's assets when
  /// it has any, and the app's compiled-in assets otherwise.
  final AssetBundle assetBundle;

  /// The patch running, or null on an unpatched release.
  final int? patchNumber;

  /// The installed crash reporter, or null when there is no control plane to
  /// report to.
  final CrashReporter? crashReporter;

  /// Prepares the runtime: resolves the running patch, makes its assets
  /// available, and starts crash reporting.
  ///
  /// Never throws. Every failure degrades to the app's built-in assets and no
  /// reporting, because neither feature is worth failing an app's startup over.
  static Future<CodePushRuntime> initialize({
    required ReleaseVersionReader readReleaseVersion,
    bool reportCrashes = true,
    AssetBundle? fallbackBundle,
    ShorebirdUpdater? updater,
    ShorebirdEnvironment? environment,
    Directory? cacheDirectory,
    PatchAssetStore? assetStore,
  }) async {
    final fallback = fallbackBundle ?? rootBundle;
    try {
      final env = environment ?? await ShorebirdEnvironment.load();
      if (env == null) {
        return CodePushRuntime._(
          assetBundle: fallback,
          patchNumber: null,
          crashReporter: null,
        );
      }

      final patch = await _readPatch(updater ?? ShorebirdUpdater());
      final releaseVersion = await _read(readReleaseVersion);

      final store =
          assetStore ??
          PatchAssetStore(
            environment: env,
            rootDirectory: cacheDirectory ?? await _defaultCacheDirectory(),
          );

      var bundle = fallback;
      if (patch == null) {
        // No patch running: the app's own assets are correct, and any bundle
        // left from a patch that was rolled back must not outlive it.
        store.evictAll();
      } else if (releaseVersion != null) {
        final dir = await store.ensure(
          patchNumber: patch,
          releaseVersion: releaseVersion,
        );
        if (dir != null) {
          bundle = PatchAssetBundle(directory: dir, fallback: fallback);
        }
      }

      CrashReporter? reporter;
      if (reportCrashes && releaseVersion != null) {
        reporter = CrashReporter(
          environment: env,
          releaseVersion: releaseVersion,
          patchNumber: patch,
          clientId: await _clientId(),
        )..install();
      }

      return CodePushRuntime._(
        assetBundle: bundle,
        patchNumber: patch,
        crashReporter: reporter,
      );
    } on Object {
      return CodePushRuntime._(
        assetBundle: fallback,
        patchNumber: null,
        crashReporter: null,
      );
    }
  }

  static Future<int?> _readPatch(ShorebirdUpdater updater) async {
    try {
      return (await updater.readCurrentPatch())?.number;
    } on Object {
      // Thrown when the app is not running under the Shorebird engine at all,
      // which is the normal case in tests and on an unsupported platform.
      return null;
    }
  }

  static Future<String?> _read(ReleaseVersionReader reader) async {
    try {
      final value = await reader();
      return (value == null || value.isEmpty) ? null : value;
    } on Object {
      return null;
    }
  }

  static Future<Directory> _defaultCacheDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'code_push_runtime', 'assets'));
  }

  /// A per-install identifier used only to group crash reports.
  ///
  /// Deliberately random and local rather than a device id: grouping is all the
  /// server needs, and a real device identifier would make crash reports carry
  /// personal data they have no reason to.
  static Future<String> _clientId() async {
    try {
      final support = await getApplicationSupportDirectory();
      final file = File(p.join(support.path, 'code_push_runtime', 'client_id'));
      if (file.existsSync()) {
        final existing = file.readAsStringSync().trim();
        if (existing.isNotEmpty) return existing;
      }
      final generated = _randomId();
      file
        ..createSync(recursive: true)
        ..writeAsStringSync(generated);
      return generated;
    } on Object {
      // Unwritable storage means reports group per launch instead of per
      // install, which is worse but still useful.
      return _randomId();
    }
  }

  static String _randomId() {
    final random = Random();
    return List.generate(
      32,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
  }
}
