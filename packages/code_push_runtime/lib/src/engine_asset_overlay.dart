import 'dart:io';

import 'package:path/path.dart' as p;

/// Installs a patch's assets where the **engine** looks for them, rather than
/// where this package's own `PatchAssetBundle` looks.
///
/// The difference is what it can reach. An `AssetBundle` only intercepts reads
/// that go through one — so `DefaultAssetBundle.of(context)` and anything built
/// on it. Three things never do: `rootBundle`, pubspec-declared fonts, and
/// declared shaders. The engine loads those itself from its own resolver chain,
/// so the only way to override them is to put files where that chain looks.
///
/// Our engine registers a resolver over `<patch dir>/flutter_assets` ahead of
/// the ones bundled into the app, so a file placed there wins. That directory
/// is derived from the running patch's own path, which is why this locates the
/// updater's patch directory rather than inventing a location.
///
/// **This only does anything on an engine built with that resolver.** On
/// Shorebird's stock engine the directory is simply never read, which is
/// harmless but also pointless — hence opt-in.
///
/// **Assets install for the *next* launch, not this one.** The engine builds
/// its resolver chain during startup, long before any Dart runs, so a tree
/// written now is picked up the next time the app starts. That matches the
/// updater's own launch-N / launch-N+1 model rather than fighting it.
class EngineAssetOverlay {
  /// Creates an overlay installer that searches [searchRoots] for the
  /// updater's state directory.
  ///
  /// Roots are injected rather than read from `path_provider` here so this is
  /// testable without a platform channel, which is the same reason
  /// `readReleaseVersion` is injected on `CodePushRuntime`.
  const EngineAssetOverlay({required this.appId, required this.searchRoots});

  /// The app's Shorebird id, needed because some platforms include it in the
  /// patch path and others do not.
  final String appId;

  /// Directories that may contain a `shorebird_updater` state tree.
  final List<Directory> searchRoots;

  /// The directory name the engine resolves assets from.
  static const _assetsDirName = 'flutter_assets';

  static const _updaterDirName = 'shorebird_updater';

  /// Locates the updater's directory for [patchNumber], or `null`.
  ///
  /// Two layouts are probed because the engine builds the path differently per
  /// platform, and getting this wrong is silent: Android's older
  /// `ConfigureShorebird` omits the app id (`<root>/shorebird_updater/patches/N`)
  /// while the desktop/iOS path inserts it
  /// (`<root>/shorebird_updater/<app id>/patches/N`). Probing for the one that
  /// exists avoids encoding a platform assumption that would rot.
  ///
  /// Only ever returns a directory the updater already created. Creating one
  /// would put files in a tree whose state machine we do not own, for a patch
  /// the updater may not consider installed.
  Directory? patchDirectory(int patchNumber) {
    for (final root in searchRoots) {
      final candidates = [
        Directory(
          p.join(root.path, _updaterDirName, 'patches', '$patchNumber'),
        ),
        Directory(
          p.join(root.path, _updaterDirName, appId, 'patches', '$patchNumber'),
        ),
      ];
      for (final candidate in candidates) {
        if (candidate.existsSync()) return candidate;
      }
    }
    return null;
  }

  /// Copies [bundle] into the patch directory for [patchNumber].
  ///
  /// Returns whether the overlay is now in place. Never throws: failing to
  /// install an overlay must leave the app running on its built-in assets, the
  /// same way a failed asset fetch does.
  bool install({required int patchNumber, required Directory bundle}) {
    try {
      if (!bundle.existsSync()) return false;
      final patchDir = patchDirectory(patchNumber);
      if (patchDir == null) return false;

      final target = Directory(p.join(patchDir.path, _assetsDirName));
      // Staged then renamed, because the engine reads this tree at startup
      // without any completeness check of its own. A half-copied tree is worse
      // than none: a truncated font or shader renders as corruption rather
      // than falling back.
      final staging = Directory('${target.path}.staging');
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      staging.createSync(recursive: true);

      var copied = 0;
      for (final entity in bundle.listSync(recursive: true)) {
        if (entity is! File) continue;
        final relative = p.relative(entity.path, from: bundle.path);
        // Skip this package's own bookkeeping; the engine reads every file
        // here as an asset.
        if (p.basename(relative).startsWith('.')) continue;
        File(p.join(staging.path, relative))
          ..createSync(recursive: true)
          ..writeAsBytesSync(entity.readAsBytesSync());
        copied++;
      }

      if (copied == 0) {
        staging.deleteSync(recursive: true);
        return false;
      }

      if (target.existsSync()) target.deleteSync(recursive: true);
      staging.renameSync(target.path);
      return true;
    } on Object {
      return false;
    }
  }
}
