import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:code_push_runtime/src/crash_reporter.dart';
import 'package:code_push_runtime/src/engine_asset_overlay.dart';
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
/// Scoped to patches on purpose. This is not a crash reporting product, and it
/// does not try to replace one — it answers the narrower question code push
/// creates, "did the patch I shipped break something?" An app on an unpatched
/// release reports nothing here and keeps using whatever reporter it already
/// had.
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
    this.assetsPatchNumber,
    this.engineOverlayInstalled = false,
  });

  /// The bundle to read assets through. Serves the running patch's assets when
  /// it has any, and the app's compiled-in assets otherwise.
  final AssetBundle assetBundle;

  /// The **code** patch running, or null when none is — including when an
  /// assets-only patch is active, since that one replaces no code.
  final int? patchNumber;

  /// The patch whose assets are being served, or null when the compiled-in
  /// assets are.
  ///
  /// Equal to [patchNumber] when a code patch carries assets. Set *without* it
  /// for an assets-only patch, which is the case that would otherwise be
  /// indistinguishable from "no patch at all" — the two are reported separately
  /// so an app can tell "no patch" from "assets patched, code original" rather
  /// than having [patchNumber] quietly mean two different things.
  final int? assetsPatchNumber;

  /// Whether this launch wrote the patch's assets into the engine's overlay
  /// directory.
  ///
  /// Diagnostic only, and note the tense: the overlay takes effect on the
  /// **next** launch, because the engine builds its resolver chain during
  /// startup before any Dart runs. True here means "installed for next time",
  /// not "active now".
  final bool engineOverlayInstalled;

  /// The installed crash reporter, or null when there is nothing to report to
  /// or no patch running.
  ///
  /// Null on an unpatched release by design — see [initialize].
  final CrashReporter? crashReporter;

  /// Prepares the runtime: resolves the running patch, makes its assets
  /// available, and — only if a patch is running — starts crash reporting.
  ///
  /// Never throws. Every failure degrades to the app's built-in assets and no
  /// reporting, because neither feature is worth failing an app's startup over.
  static Future<CodePushRuntime> initialize({
    required ReleaseVersionReader readReleaseVersion,
    bool reportCrashes = true,
    bool installEngineOverlay = false,
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

      // An assets-only patch is invisible to the updater by design, so when it
      // reports nothing we still have to ask whether one is active. Without
      // this, publishing an assets-only patch changes nothing on the device:
      // the updater says "no patch", the store is never consulted, and the app
      // keeps serving compiled-in assets forever. This is the only way such a
      // patch reaches a device running a stock updater — which is every iOS
      // device, since iOS code patches need an AOT linker we do not have.
      var assetsPatch = patch;
      if (patch == null && releaseVersion != null) {
        assetsPatch = await store.discoverAssetsOnlyPatch(
          releaseVersion: releaseVersion,
          clientId: await _clientId(),
        );
      }

      var bundle = fallback;
      var engineOverlayInstalled = false;
      if (assetsPatch == null) {
        // No patch running: the app's own assets are correct, and any bundle
        // left from a patch that was rolled back must not outlive it.
        store.evictAll();
      } else if (releaseVersion != null) {
        final dir = await store.ensure(
          patchNumber: assetsPatch,
          releaseVersion: releaseVersion,
        );
        if (dir != null) {
          bundle = PatchAssetBundle(directory: dir, fallback: fallback);
          if (installEngineOverlay) {
            engineOverlayInstalled = await _installEngineOverlay(
              environment: env,
              patchNumber: assetsPatch,
              bundle: dir,
            );
          }
        }
      }

      // Only while a CODE patch is running — deliberately `patch`, not
      // `assetsPatch`. This package is not a crash reporting product and should
      // not act like one: an app on an unpatched release already has whatever
      // reporter it chose, and duplicating it would add reports that can never
      // be symbolicated here, because symbols are retained per patch. The
      // question this answers is narrower and is the one code push creates —
      // "did the patch I shipped break something?" An assets-only patch ships
      // no code and retains no symbols, so a report attributed to it could
      // never resolve a frame; swapping an asset is also not the kind of change
      // that introduces a crash in compiled code.
      CrashReporter? reporter;
      if (reportCrashes && releaseVersion != null && patch != null) {
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
        // Only claim assets are patched when a bundle is actually being
        // served: discovery succeeding but the fetch failing must not look
        // like success.
        assetsPatchNumber: bundle == fallback ? null : assetsPatch,
        crashReporter: reporter,
        engineOverlayInstalled: engineOverlayInstalled,
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

  /// Copies the patch's assets into the engine's overlay directory.
  ///
  /// Both plausible roots are offered because the engine derives the updater's
  /// directory from a different base per platform: Android passes
  /// `getFilesDir()` (which `getApplicationSupportDirectory` reaches), while
  /// iOS passes its caches path for both arguments. Probing beats encoding a
  /// per-platform constant that would break silently on the platform nobody
  /// tested.
  static Future<bool> _installEngineOverlay({
    required ShorebirdEnvironment environment,
    required int patchNumber,
    required Directory bundle,
  }) async {
    try {
      final roots = <Directory>[];
      for (final resolve in <Future<Directory> Function()>[
        getApplicationSupportDirectory,
        getApplicationCacheDirectory,
      ]) {
        try {
          roots.add(await resolve());
        } on Object {
          // Not every platform implements every directory; a root we cannot
          // resolve is simply one we do not search.
        }
      }
      if (roots.isEmpty) return false;

      return EngineAssetOverlay(
        appId: environment.appId,
        searchRoots: roots,
      ).install(patchNumber: patchNumber, bundle: bundle);
    } on Object {
      return false;
    }
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
