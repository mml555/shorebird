import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/archive_analysis/archive_analysis.dart';
import 'package:shorebird_cli/src/archive_analysis/archive_differ.dart';
import 'package:shorebird_cli/src/http_client/http_client.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/patch_diff_checker.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:test/test.dart';

import 'fakes.dart';
import 'mocks.dart';

void main() {
  group(PatchDiffChecker, () {
    const assetsDiffPrettyString = 'assets diff pretty string';
    const nativeDiffPrettyString = 'native diff pretty string';
    final localArtifact = File('local.artifact');
    final releaseArtifact = File('release.artifact');

    late ArchiveDiffer archiveDiffer;
    late FileSetDiff assetsFileSetDiff;
    late FileSetDiff nativeFileSetDiff;
    late FileSetDiff unclassifiedFileSetDiff;
    late http.Client httpClient;
    late ShorebirdLogger logger;
    late Progress progress;
    late ShorebirdEnv shorebirdEnv;
    late PatchDiffChecker patchDiffChecker;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {
          httpClientRef.overrideWith(() => httpClient),
          loggerRef.overrideWith(() => logger),
          shorebirdEnvRef.overrideWith(() => shorebirdEnv),
        },
      );
    }

    setUpAll(() {
      registerFallbackValue(FileSetDiff.empty());
      registerFallbackValue(FakeBaseRequest());
    });

    setUp(() {
      archiveDiffer = MockArchiveDiffer();
      assetsFileSetDiff = MockFileSetDiff();
      nativeFileSetDiff = MockFileSetDiff();
      unclassifiedFileSetDiff = MockFileSetDiff();
      httpClient = MockHttpClient();
      logger = MockShorebirdLogger();
      progress = MockProgress();
      shorebirdEnv = MockShorebirdEnv();
      patchDiffChecker = PatchDiffChecker();

      when(
        () => archiveDiffer.changedFiles(any(), any()),
      ).thenAnswer((_) async => FileSetDiff.empty());
      when(
        () => archiveDiffer.assetsFileSetDiff(any()),
      ).thenReturn(assetsFileSetDiff);
      when(
        () => archiveDiffer.nativeFileSetDiff(any()),
      ).thenReturn(nativeFileSetDiff);
      when(
        () => archiveDiffer.containsPotentiallyBreakingAssetDiffs(any()),
      ).thenReturn(false);
      when(
        () => archiveDiffer.containsPotentiallyBreakingNativeDiffs(any()),
      ).thenReturn(false);
      when(
        () => archiveDiffer.availableAssetDiffs(
          fileSetDiff: any(named: 'fileSetDiff'),
          oldArchivePath: any(named: 'oldArchivePath'),
          newArchivePath: any(named: 'newArchivePath'),
        ),
      ).thenAnswer((_) async => '');
      // Default: nothing dropped, nothing unclassified. Individual groups
      // override these to exercise the two new warnings.
      when(() => assetsFileSetDiff.addedPaths).thenReturn(<String>{});
      when(
        () => archiveDiffer.assetKeysReferencedByDart(
          archivePath: any(named: 'archivePath'),
          assetKeys: any(named: 'assetKeys'),
        ),
      ).thenAnswer((_) async => <String>{});
      when(
        () => archiveDiffer.unclassifiedFileSetDiff(any()),
      ).thenReturn(unclassifiedFileSetDiff);
      when(() => unclassifiedFileSetDiff.isEmpty).thenReturn(true);

      when(() => httpClient.send(any())).thenAnswer(
        (_) async => http.StreamedResponse(const Stream.empty(), HttpStatus.ok),
      );

      when(
        () => logger.confirm(any(), hint: any(named: 'hint')),
      ).thenReturn(true);
      when(() => logger.progress(any())).thenReturn(progress);

      when(() => shorebirdEnv.canAcceptUserInput).thenReturn(true);

      when(
        () => assetsFileSetDiff.prettyString,
      ).thenReturn(assetsDiffPrettyString);
      when(
        () => nativeFileSetDiff.prettyString,
      ).thenReturn(nativeDiffPrettyString);
    });

    group('confirmUnpatchableDiffsIfNecessary', () {
      group('when native diffs are detected', () {
        setUp(() {
          when(
            () => archiveDiffer.containsPotentiallyBreakingNativeDiffs(any()),
          ).thenReturn(true);
        });

        test('logs warning', () async {
          await runWithOverrides(
            () => patchDiffChecker.confirmUnpatchableDiffsIfNecessary(
              localArchive: localArtifact,
              releaseArchive: releaseArtifact,
              archiveDiffer: archiveDiffer,
              allowAssetChanges: false,
              allowNativeChanges: false,
            ),
          );

          verify(
            () => logger.warn(
              '''Your app contains native changes, which cannot be applied with a patch.''',
            ),
          ).called(1);
          verify(
            () => logger.info(yellow.wrap(nativeDiffPrettyString)),
          ).called(1);
          verify(
            () => logger.info(
              any(
                that: contains(
                  "If you don't know why you're seeing this error",
                ),
              ),
            ),
          ).called(1);
        });

        test('prompts user if allowNativeChanges is false', () async {
          await runWithOverrides(
            () => patchDiffChecker.confirmUnpatchableDiffsIfNecessary(
              localArchive: localArtifact,
              releaseArchive: releaseArtifact,
              archiveDiffer: archiveDiffer,
              allowAssetChanges: false,
              allowNativeChanges: false,
            ),
          );

          verify(
            () => logger.confirm('Continue anyway?', hint: any(named: 'hint')),
          ).called(1);
        });

        test('does not prompt user if allowNativeChanges is true', () async {
          await runWithOverrides(
            () => patchDiffChecker.confirmUnpatchableDiffsIfNecessary(
              localArchive: localArtifact,
              releaseArchive: releaseArtifact,
              archiveDiffer: archiveDiffer,
              allowAssetChanges: false,
              allowNativeChanges: true,
            ),
          );

          verifyNever(
            () => logger.confirm('Continue anyway?', hint: any(named: 'hint')),
          );
        });

        test(
          'throws UserCancelledException if user declines to continue',
          () async {
            when(
              () => logger.confirm(any(), hint: any(named: 'hint')),
            ).thenReturn(false);

            await expectLater(
              runWithOverrides(
                () => patchDiffChecker.confirmUnpatchableDiffsIfNecessary(
                  localArchive: localArtifact,
                  releaseArchive: releaseArtifact,
                  archiveDiffer: archiveDiffer,
                  allowAssetChanges: false,
                  allowNativeChanges: false,
                ),
              ),
              throwsA(isA<UserCancelledException>()),
            );

            verify(
              () =>
                  logger.confirm('Continue anyway?', hint: any(named: 'hint')),
            ).called(1);
          },
        );

        test('does not prompt when unable to accept user input', () async {
          when(() => shorebirdEnv.canAcceptUserInput).thenReturn(false);

          await expectLater(
            () => runWithOverrides(
              () => patchDiffChecker.confirmUnpatchableDiffsIfNecessary(
                localArchive: localArtifact,
                releaseArchive: releaseArtifact,
                archiveDiffer: archiveDiffer,
                allowAssetChanges: false,
                allowNativeChanges: false,
              ),
            ),
            throwsA(isA<UnpatchableChangeException>()),
          );

          verifyNever(
            () => logger.confirm(any(), hint: any(named: 'hint')),
          );
        });
      });

      group('when asset diffs are detected', () {
        setUp(() {
          when(
            () => archiveDiffer.containsPotentiallyBreakingAssetDiffs(any()),
          ).thenReturn(true);
        });

        test('logs warning', () async {
          await runWithOverrides(
            () => patchDiffChecker.confirmUnpatchableDiffsIfNecessary(
              localArchive: localArtifact,
              releaseArchive: releaseArtifact,
              archiveDiffer: archiveDiffer,
              allowAssetChanges: false,
              allowNativeChanges: false,
            ),
          );

          verify(
            () => logger.warn(
              '''Your app contains asset changes, which will not be included in the patch.''',
            ),
          ).called(1);
          verify(
            () => archiveDiffer.availableAssetDiffs(
              fileSetDiff: any(named: 'fileSetDiff'),
              oldArchivePath: any(named: 'oldArchivePath'),
              newArchivePath: any(named: 'newArchivePath'),
            ),
          ).called(1);
          verify(
            () => logger.info(yellow.wrap(assetsDiffPrettyString)),
          ).called(1);
        });

        test('prompts user if allowAssetChanges is false', () async {
          await runWithOverrides(
            () => patchDiffChecker.confirmUnpatchableDiffsIfNecessary(
              localArchive: localArtifact,
              releaseArchive: releaseArtifact,
              archiveDiffer: archiveDiffer,
              allowAssetChanges: false,
              allowNativeChanges: false,
            ),
          );

          verify(
            () => logger.confirm('Continue anyway?', hint: any(named: 'hint')),
          ).called(1);
        });

        test('does not prompt user if allowAssetChanges is true', () async {
          await runWithOverrides(
            () => patchDiffChecker.confirmUnpatchableDiffsIfNecessary(
              localArchive: localArtifact,
              releaseArchive: releaseArtifact,
              archiveDiffer: archiveDiffer,
              allowAssetChanges: true,
              allowNativeChanges: false,
            ),
          );

          verifyNever(
            () => logger.confirm('Continue anyway?', hint: any(named: 'hint')),
          );
        });

        test(
          'throws UserCancelledException if user declines to continue',
          () async {
            when(
              () => logger.confirm(any(), hint: any(named: 'hint')),
            ).thenReturn(false);

            await expectLater(
              runWithOverrides(
                () => patchDiffChecker.confirmUnpatchableDiffsIfNecessary(
                  localArchive: localArtifact,
                  releaseArchive: releaseArtifact,
                  archiveDiffer: archiveDiffer,
                  allowAssetChanges: false,
                  allowNativeChanges: false,
                ),
              ),
              throwsA(isA<UserCancelledException>()),
            );

            verify(
              () =>
                  logger.confirm('Continue anyway?', hint: any(named: 'hint')),
            ).called(1);
          },
        );

        test('does not prompt when unable to accept user input', () async {
          when(() => shorebirdEnv.canAcceptUserInput).thenReturn(false);

          await expectLater(
            () => runWithOverrides(
              () => patchDiffChecker.confirmUnpatchableDiffsIfNecessary(
                localArchive: localArtifact,
                releaseArchive: releaseArtifact,
                archiveDiffer: archiveDiffer,
                allowAssetChanges: false,
                allowNativeChanges: false,
              ),
            ),
            throwsA(isA<UnpatchableChangeException>()),
          );

          verifyNever(
            () => logger.confirm(any(), hint: any(named: 'hint')),
          );
        });
      });

      test(
        'returns true if no potentially breaking diffs are detected',
        () async {
          await expectLater(
            runWithOverrides(
              () => patchDiffChecker.confirmUnpatchableDiffsIfNecessary(
                localArchive: localArtifact,
                releaseArchive: releaseArtifact,
                archiveDiffer: archiveDiffer,
                allowAssetChanges: false,
                allowNativeChanges: false,
              ),
            ),
            completes,
          );
        },
      );
    });

    group('when dropped assets are still referenced by the patched Dart', () {
      setUp(() {
        when(
          () => archiveDiffer.containsPotentiallyBreakingAssetDiffs(any()),
        ).thenReturn(true);
        when(() => assetsFileSetDiff.addedPaths).thenReturn({
          'base/assets/flutter_assets/assets/images/logo.png',
        });
        when(
          () => archiveDiffer.assetKeysReferencedByDart(
            archivePath: any(named: 'archivePath'),
            assetKeys: any(named: 'assetKeys'),
          ),
        ).thenAnswer((_) async => {'assets/images/logo.png'});
      });

      test('warns and names the asset', () async {
        await runWithOverrides(
          () => patchDiffChecker.confirmUnpatchableDiffsIfNecessary(
            localArchive: localArtifact,
            releaseArchive: releaseArtifact,
            archiveDiffer: archiveDiffer,
            allowAssetChanges: true,
            allowNativeChanges: false,
          ),
        );

        verify(
          () => logger.warn(
            any(that: contains('still referenced by the patched Dart')),
          ),
        ).called(1);
        verify(
          () => logger.info(
            any(that: contains('assets/images/logo.png')),
          ),
        ).called(1);
      });

      test('scans for the Dart asset key, not the archive path', () async {
        await runWithOverrides(
          () => patchDiffChecker.confirmUnpatchableDiffsIfNecessary(
            localArchive: localArtifact,
            releaseArchive: releaseArtifact,
            archiveDiffer: archiveDiffer,
            allowAssetChanges: true,
            allowNativeChanges: false,
          ),
        );

        // Dart asks for `assets/images/logo.png`; the archive stores it under
        // `base/assets/flutter_assets/`. Searching the snapshot for the
        // archive path would never match.
        verify(
          () => archiveDiffer.assetKeysReferencedByDart(
            archivePath: localArtifact.path,
            assetKeys: {'assets/images/logo.png'},
          ),
        ).called(1);
      });

      test(
        'does not warn when nothing references the dropped assets',
        () async {
          when(
            () => archiveDiffer.assetKeysReferencedByDart(
              archivePath: any(named: 'archivePath'),
              assetKeys: any(named: 'assetKeys'),
            ),
          ).thenAnswer((_) async => <String>{});

          await runWithOverrides(
            () => patchDiffChecker.confirmUnpatchableDiffsIfNecessary(
              localArchive: localArtifact,
              releaseArchive: releaseArtifact,
              archiveDiffer: archiveDiffer,
              allowAssetChanges: true,
              allowNativeChanges: false,
            ),
          );

          verifyNever(
            () => logger.warn(
              any(that: contains('still referenced by the patched Dart')),
            ),
          );
        },
      );

      test('a failed scan never fails the patch', () async {
        when(
          () => archiveDiffer.assetKeysReferencedByDart(
            archivePath: any(named: 'archivePath'),
            assetKeys: any(named: 'assetKeys'),
          ),
        ).thenThrow(Exception('unreadable archive'));

        await expectLater(
          runWithOverrides(
            () => patchDiffChecker.confirmUnpatchableDiffsIfNecessary(
              localArchive: localArtifact,
              releaseArchive: releaseArtifact,
              archiveDiffer: archiveDiffer,
              allowAssetChanges: true,
              allowNativeChanges: false,
            ),
          ),
          completes,
        );
      });
    });

    group('when changed files match no classifier', () {
      setUp(() {
        when(() => unclassifiedFileSetDiff.isEmpty).thenReturn(false);
        when(() => unclassifiedFileSetDiff.addedPaths).thenReturn(<String>{});
        when(() => unclassifiedFileSetDiff.removedPaths).thenReturn(<String>{});
        when(() => unclassifiedFileSetDiff.changedPaths).thenReturn({
          'Products/Applications/Runner.app/Info.plist',
        });
        when(
          () => unclassifiedFileSetDiff.prettyString,
        ).thenReturn('unclassified pretty string');
      });

      test('reports them instead of dropping them silently', () async {
        await runWithOverrides(
          () => patchDiffChecker.confirmUnpatchableDiffsIfNecessary(
            localArchive: localArtifact,
            releaseArchive: releaseArtifact,
            archiveDiffer: archiveDiffer,
            allowAssetChanges: false,
            allowNativeChanges: false,
          ),
        );

        verify(
          () => logger.info(
            any(
              that: contains(
                '1 file(s) changed that are neither assets, Dart, nor '
                'recognized native code.',
              ),
            ),
          ),
        ).called(1);
      });
    });
  });
}
