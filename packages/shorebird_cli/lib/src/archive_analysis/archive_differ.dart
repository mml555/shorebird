// cspell:words arsc
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/archive_analysis/archive_analysis.dart';

/// Thrown when an [ArchiveDiffer] fails to generate a [FileSetDiff].
class DiffFailedException implements Exception {}

/// {@template archive_differ}
/// Computes content differences between two archives.
/// {@endtemplate}
abstract class ArchiveDiffer {
  /// {@macro archive_differ}
  const ArchiveDiffer();

  /// Asset files that are not considered to be breaking changes.
  static const assetFileNamesToIgnore = {
    'AssetManifest.bin',
    'AssetManifest.json',
    'NOTICES.Z',
  };

  /// Whether there are asset differences between the archives that may cause
  /// issues when patching a release.
  bool containsPotentiallyBreakingAssetDiffs(FileSetDiff fileSetDiff) {
    final assetsDiff = assetsFileSetDiff(fileSetDiff);

    // If assets were added, we need to warn the user about asset differences.
    // We don't care about removed assets, as they can't be removed by patch
    // and won't cause issues.
    if (assetsDiff.addedPaths.isNotEmpty) {
      return true;
    }

    return assetsDiff.changedPaths
        .whereNot(
          (path) =>
              ArchiveDiffer.assetFileNamesToIgnore.contains(p.basename(path)),
        )
        .isNotEmpty;
  }

  /// Whether there are native code differences between the archives that may
  /// cause issues when patching a release.
  bool containsPotentiallyBreakingNativeDiffs(FileSetDiff fileSetDiff) =>
      nativeFileSetDiff(fileSetDiff).isNotEmpty;

  /// Whether the provided file path represents a changed asset.
  bool isAssetFilePath(String filePath);

  /// Whether the provided file path represents changed Dart code.
  bool isDartFilePath(String filePath);

  /// Whether the provided file path represents changed Native code.
  bool isNativeFilePath(String filePath);

  /// The subset of [fileSetDiff] that contains only changes that result from
  /// edited assets.
  FileSetDiff assetsFileSetDiff(FileSetDiff fileSetDiff) => FileSetDiff(
    addedPaths: fileSetDiff.addedPaths.where(isAssetFilePath).toSet(),
    removedPaths: fileSetDiff.removedPaths.where(isAssetFilePath).toSet(),
    changedPaths: fileSetDiff.changedPaths.where(isAssetFilePath).toSet(),
  );

  /// The subset of [fileSetDiff] that contains only changes that result from
  /// edited Dart code.
  FileSetDiff dartFileSetDiff(FileSetDiff fileSetDiff) => FileSetDiff(
    addedPaths: fileSetDiff.addedPaths.where(isDartFilePath).toSet(),
    removedPaths: fileSetDiff.removedPaths.where(isDartFilePath).toSet(),
    changedPaths: fileSetDiff.changedPaths.where(isDartFilePath).toSet(),
  );

  /// The subset of [fileSetDiff] that contains only changes that result from
  /// edited native code.
  FileSetDiff nativeFileSetDiff(FileSetDiff fileSetDiff) => FileSetDiff(
    addedPaths: fileSetDiff.addedPaths.where(isNativeFilePath).toSet(),
    removedPaths: fileSetDiff.removedPaths.where(isNativeFilePath).toSet(),
    changedPaths: fileSetDiff.changedPaths.where(isNativeFilePath).toSet(),
  );

  /// The subset of [fileSetDiff] matching none of [isAssetFilePath],
  /// [isDartFilePath] or [isNativeFilePath].
  ///
  /// These are changes no warning covers. `Info.plist` is the case that
  /// motivated surfacing them: it lives in the built app, so it *is* in the
  /// diff, but it is not an asset, not Dart, and does not match the Apple
  /// native regex (`[\w\- ]+$` excludes the dot), so a change to it used to
  /// vanish silently. Android has the same hole for `AndroidManifest.xml` and
  /// `resources.arsc`.
  FileSetDiff unclassifiedFileSetDiff(FileSetDiff fileSetDiff) {
    bool unclassified(String path) =>
        !isAssetFilePath(path) &&
        !isDartFilePath(path) &&
        !isNativeFilePath(path);
    return FileSetDiff(
      addedPaths: fileSetDiff.addedPaths.where(unclassified).toSet(),
      removedPaths: fileSetDiff.removedPaths.where(unclassified).toSet(),
      changedPaths: fileSetDiff.changedPaths.where(unclassified).toSet(),
    );
  }

  /// The asset key Dart would use to load [archivePath], or `null` if
  /// [archivePath] is not a `flutter_assets` entry.
  ///
  /// Archive layouts bury the key at different depths — an AAB has
  /// `base/assets/flutter_assets/<key>`, an APK `assets/flutter_assets/<key>`,
  /// an iOS app `…/App.framework/flutter_assets/<key>` — but the key Dart sees
  /// is always what follows `flutter_assets/`. Entries outside that tree
  /// (Android `res/`, `Assets.car`) are not addressed by key and yield `null`.
  static String? assetKeyForArchivePath(String archivePath) {
    const marker = 'flutter_assets/';
    final index = archivePath.indexOf(marker);
    if (index < 0) return null;
    final key = archivePath.substring(index + marker.length);
    return key.isEmpty ? null : key;
  }

  /// Which of [assetKeys] appear verbatim in the compiled Dart inside
  /// [archivePath].
  ///
  /// Answers the question `--allow-asset-diffs` leaves open: the flag drops
  /// added assets from the patch, but says nothing about whether the patched
  /// Dart still asks for them. A hit means code this patch ships references an
  /// asset the patch does not carry, which fails at runtime — an empty box for
  /// `Image.asset`, not a crash, so it is easy to ship unnoticed.
  ///
  /// Works by substring search over the snapshot, which is sound because
  /// obfuscation renames identifiers and not string literals, so asset keys
  /// survive `--obfuscate` intact.
  ///
  /// Deliberately conservative in both directions. A key built at runtime
  /// (`'assets/images/$name.png'`) is never found, so this can miss; and a key
  /// that merely appears as a substring is reported without proof it is
  /// reached, so this can over-report. It warns rather than fails for exactly
  /// that reason.
  Future<Set<String>> assetKeysReferencedByDart({
    required String archivePath,
    required Set<String> assetKeys,
  }) async {
    if (assetKeys.isEmpty) return {};
    return Isolate.run(() {
      final referenced = <String>{};
      // The stream is closed in `finally`, not after the loop: an archive that
      // throws mid-parse must still release the handle. On POSIX a leaked
      // handle is invisible — the file can be unlinked while open — so this
      // only ever fails on Windows, where the OS refuses to delete it
      // (`errno 32`). The bug is cross-platform; the observation is not.
      final stream = InputFileStream(archivePath);
      try {
        final archive = ZipDecoder().decodeStream(stream);
        for (final file in archive.files) {
          if (!file.isFile || !isDartFilePath(file.name)) continue;
          final content = file.readBytes();
          if (content == null) continue;
          // latin1 maps each byte to one code unit, so indexOf over the decoded
          // string is an exact byte search. Asset keys are ASCII, so no key can
          // be mangled by the decode.
          final haystack = latin1.decode(content, allowInvalid: true);
          for (final key in assetKeys) {
            if (haystack.contains(key)) referenced.add(key);
          }
        }
      } finally {
        stream.closeSync();
      }
      return referenced;
    });
  }

  /// Files that have been added, removed, or that have changed between the
  /// archives at the two provided paths.
  Future<FileSetDiff> changedFiles(
    String oldArchivePath,
    String newArchivePath,
  ) async {
    return FileSetDiff.fromPathHashes(
      oldPathHashes: await fileHashes(File(oldArchivePath)),
      newPathHashes: await fileHashes(File(newArchivePath)),
    );
  }

  /// Returns a map of file paths to their respective checksums.
  Future<PathHashes> fileHashes(File archive) async {
    return Isolate.run(() {
      // Same handle contract as assetKeysReferencedByDart above: closed in
      // `finally` so a malformed archive cannot leak it.
      final stream = InputFileStream(archive.path);
      try {
        final zipDirectory = ZipDirectory()..read(stream);

        return {
          for (final file in zipDirectory.fileHeaders)
            // Zip files contain an (optional) crc32 checksum for a file. IPAs
            // and AARs seem to always include this for files, so a quick way
            // for us to tell if file contents differ is if their checksums
            // differ.
            file.filename: file.crc32.toString(),
        };
      } finally {
        stream.closeSync();
      }
    });
  }

  /// Prints the diffs of the changed files to the console.
  Future<String> availableAssetDiffs({
    required FileSetDiff fileSetDiff,
    required String oldArchivePath,
    required String newArchivePath,
  }) async {
    return '';
  }
}
