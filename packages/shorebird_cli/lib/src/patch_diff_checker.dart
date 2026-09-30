// cspell:words dexdump arsc
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/archive_analysis/android_archive_differ.dart';
import 'package:shorebird_cli/src/archive_analysis/archive_differ.dart';
import 'package:shorebird_cli/src/archive_analysis/file_set_diff.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_documentation.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';

/// Hint shown when a user can bypass a native-diff warning interactively.
const String allowNativeDiffsHint =
    'Warning: Native changes in a patch are likely to crash your app. '
    'Pass --allow-native-diffs to force this patch.';

/// Hint shown when a user can bypass an asset-diff warning interactively.
const String allowAssetDiffsHint =
    'Warning: Asset changes will not be included in this patch. '
    'Pass --allow-asset-diffs to force this patch.';

/// {@template diff_status}
/// Describes the types of changes that have been detected between a patch
/// and its release.
/// {@endtemplate}
class DiffStatus {
  /// {@macro diff_status}
  const DiffStatus({
    required this.hasAssetChanges,
    required this.hasNativeChanges,
  });

  /// Whether the patch contains asset changes.
  final bool hasAssetChanges;

  /// Whether the patch contains native code changes.
  final bool hasNativeChanges;
}

/// Thrown when an unpatchable change is detected in an environment where the
/// user cannot be prompted to continue.
class UnpatchableChangeException implements Exception {}

/// Thrown when the user cancels after being prompted to continue.
class UserCancelledException implements Exception {}

/// A reference to a [PatchDiffChecker] instance.
ScopedRef<PatchDiffChecker> patchDiffCheckerRef = create(PatchDiffChecker.new);

/// The [PatchDiffChecker] instance available in the current zone.
PatchDiffChecker get patchDiffChecker => read(patchDiffCheckerRef);

/// {@template patch_verifier}
/// Verifies that a patch can successfully be applied to a release artifact.
/// {@endtemplate}
class PatchDiffChecker {
  /// Checks for differences that could cause issues when applying the
  /// [localArchive] patch to the [releaseArchive].
  Future<DiffStatus> confirmUnpatchableDiffsIfNecessary({
    required File localArchive,
    required File releaseArchive,
    required ArchiveDiffer archiveDiffer,
    required bool allowAssetChanges,
    required bool allowNativeChanges,
    bool confirmNativeChanges = true,
  }) async {
    final progress = logger.progress(
      'Verifying patch can be applied to release',
    );

    final contentDiffs = await archiveDiffer.changedFiles(
      releaseArchive.path,
      localArchive.path,
    );
    progress.complete();

    final status = DiffStatus(
      hasAssetChanges: archiveDiffer.containsPotentiallyBreakingAssetDiffs(
        contentDiffs,
      ),
      hasNativeChanges: archiveDiffer.containsPotentiallyBreakingNativeDiffs(
        contentDiffs,
      ),
    );

    if (status.hasNativeChanges && confirmNativeChanges) {
      logger
        ..warn(
          '''Your app contains native changes, which cannot be applied with a patch.''',
        )
        ..info(
          yellow.wrap(
            archiveDiffer.nativeFileSetDiff(contentDiffs).prettyString,
          ),
        );

      // Show detailed DEX diff information if available.
      if (contentDiffs is AndroidFileSetDiff &&
          contentDiffs.dexDiffResults.isNotEmpty) {
        for (final dexPath
            in archiveDiffer
                .nativeFileSetDiff(contentDiffs)
                .changedPaths
                .where((p) => p.endsWith('.dex'))) {
          final dexResult = contentDiffs.dexDiffResults[dexPath];
          if (dexResult != null) {
            logger.info(yellow.wrap(dexResult.describe()));
          }
        }
        logger.info(
          yellow.wrap(
            '\nFor detailed DEX disassembly, run: dexdump -d <file>',
          ),
        );
      }

      logger.info(
        yellow.wrap(
          '''

If you don't know why you're seeing this error, visit our troubleshooting page at ${nativeChangesTroubleshootingUrl.toLink()}''',
        ),
      );

      if (!allowNativeChanges) {
        if (!shorebirdEnv.canAcceptUserInput) {
          throw UnpatchableChangeException();
        }

        if (!logger.confirm(
          'Continue anyway?',
          hint: allowNativeDiffsHint,
        )) {
          throw UserCancelledException();
        }
      }
    }

    if (status.hasAssetChanges) {
      logger
        ..warn(
          '''Your app contains asset changes, which will not be included in the patch.''',
        )
        ..info(
          yellow.wrap(
            archiveDiffer.assetsFileSetDiff(contentDiffs).prettyString,
          ),
        );

      final diffs = await archiveDiffer.availableAssetDiffs(
        fileSetDiff: contentDiffs,
        oldArchivePath: releaseArchive.path,
        newArchivePath: localArchive.path,
      );
      if (diffs.isNotEmpty) {
        logger.info(diffs);
      }

      await _warnAboutDroppedAssetsStillReferenced(
        localArchive: localArchive,
        archiveDiffer: archiveDiffer,
        contentDiffs: contentDiffs,
      );

      logger.info(
        yellow.wrap(
          '''

If you don't know why you're seeing this error, visit our troubleshooting page at ${assetChangesTroubleshootingUrl.toLink()}''',
        ),
      );

      if (!allowAssetChanges) {
        if (!shorebirdEnv.canAcceptUserInput) {
          throw UnpatchableChangeException();
        }

        if (!logger.confirm(
          'Continue anyway?',
          hint: allowAssetDiffsHint,
        )) {
          throw UserCancelledException();
        }
      }
    }

    _warnAboutUnclassifiedChanges(
      archiveDiffer: archiveDiffer,
      contentDiffs: contentDiffs,
    );

    return status;
  }

  /// Warns when the patched Dart still references assets the patch drops.
  ///
  /// `--allow-asset-diffs` reads as "cosmetic assets won't update", but when
  /// the same patch ships code that loads those assets it means "this patch
  /// will fail to find files at runtime". Those are very different risks, and
  /// the second one is quiet: a failed `Image.asset` renders an empty box
  /// rather than crashing, so it reaches users looking like a design bug.
  ///
  /// Only *added* assets are considered. A changed asset still resolves — to
  /// the release's older bytes — while an added one has nothing to resolve to.
  Future<void> _warnAboutDroppedAssetsStillReferenced({
    required File localArchive,
    required ArchiveDiffer archiveDiffer,
    required FileSetDiff contentDiffs,
  }) async {
    final addedKeys = archiveDiffer
        .assetsFileSetDiff(contentDiffs)
        .addedPaths
        .map(ArchiveDiffer.assetKeyForArchivePath)
        .nonNulls
        .toSet();
    if (addedKeys.isEmpty) return;

    final Set<String> referenced;
    try {
      referenced = await archiveDiffer.assetKeysReferencedByDart(
        archivePath: localArchive.path,
        assetKeys: addedKeys,
      );
    } on Object catch (error) {
      // Advisory only. A patch must never fail to build because this extra
      // check could not read an archive.
      logger.detail('Unable to scan for dropped asset references: $error');
      return;
    }
    if (referenced.isEmpty) return;

    logger
      ..warn(
        '''${referenced.length} asset(s) dropped from this patch are still referenced by the patched Dart code.''',
      )
      ..info(
        yellow.wrap('''
    These will fail to load at runtime:
${referenced.sorted().map((String k) => '        $k').join('\n')}

    Ship them with --assets, or guard the load sites, or cut a new release.'''),
      );
  }

  /// Warns about changed files that no other warning covers.
  ///
  /// Every path is classified as asset, Dart, or native, and anything matching
  /// none of the three was silently dropped. `Info.plist` is the case that
  /// motivated this: it is in the built app and therefore in the diff, but it
  /// matches no classifier, so an iOS native change could pass review unseen
  /// while the equivalent Android change (which lands in `.dex`) was reported
  /// in detail. Android has the same hole for `AndroidManifest.xml`.
  ///
  /// Informational, not a gate: these files are frequently benign, and the
  /// point is to stop them being invisible.
  void _warnAboutUnclassifiedChanges({
    required ArchiveDiffer archiveDiffer,
    required FileSetDiff contentDiffs,
  }) {
    final unclassified = archiveDiffer.unclassifiedFileSetDiff(contentDiffs);
    if (unclassified.isEmpty) return;

    final count =
        unclassified.addedPaths.length +
        unclassified.changedPaths.length +
        unclassified.removedPaths.length;
    logger
      ..info(
        '''\n$count file(s) changed that are neither assets, Dart, nor recognized native code.''',
      )
      ..detail(unclassified.prettyString);
  }
}
