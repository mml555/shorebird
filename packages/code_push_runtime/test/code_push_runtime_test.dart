import 'dart:io';

import 'package:code_push_runtime/code_push_runtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

class _MockUpdater extends Mock implements ShorebirdUpdater {}

class _MockAssetStore extends Mock implements PatchAssetStore {}

void main() {
  group(CodePushRuntime, () {
    final environment = ShorebirdEnvironment(
      appId: 'app-1',
      baseUrl: Uri.parse('https://cps.test/'),
    );

    late _MockUpdater updater;
    late _MockAssetStore store;

    setUp(() {
      updater = _MockUpdater();
      store = _MockAssetStore();
      when(
        () => store.ensure(
          patchNumber: any(named: 'patchNumber'),
          releaseVersion: any(named: 'releaseVersion'),
        ),
      ).thenAnswer((_) async => null);
      // Default to "no assets-only patch active". Left unstubbed, the throw
      // from an unmatched call is swallowed by initialize's catch-all and shows
      // up as some unrelated assertion failing.
      when(
        () => store.discoverAssetsOnlyPatch(
          releaseVersion: any(named: 'releaseVersion'),
          clientId: any(named: 'clientId'),
        ),
      ).thenAnswer((_) async => null);
      when(store.evictAll).thenReturn(null);
    });

    /// Initializes with a patch running, or none when [patch] is null.
    Future<CodePushRuntime> init({int? patch, bool reportCrashes = true}) {
      when(updater.readCurrentPatch).thenAnswer(
        (_) async => patch == null ? null : Patch(number: patch),
      );
      return CodePushRuntime.initialize(
        readReleaseVersion: () async => '1.0.0+1',
        reportCrashes: reportCrashes,
        environment: environment,
        updater: updater,
        assetStore: store,
      );
    }

    group('crash reporting scope', () {
      test('reports while a patch is running', () async {
        final runtime = await init(patch: 4);
        addTearDown(() => runtime.crashReporter?.uninstall());

        expect(runtime.patchNumber, equals(4));
        expect(runtime.crashReporter, isNotNull);
      });

      test('reports nothing on an unpatched release', () async {
        // The scope is "did the patch I shipped break something?", not crash
        // reporting in general. An app on a plain release already has whatever
        // reporter it chose, and a report from one could never be symbolicated
        // here anyway, because symbols are retained per patch.
        final runtime = await init();

        expect(runtime.patchNumber, isNull);
        expect(runtime.crashReporter, isNull);
      });

      test('leaves the app error handlers alone when unpatched', () async {
        final before = FlutterError.onError;

        await init();

        expect(FlutterError.onError, same(before));
      });

      test('honors reportCrashes: false even while patched', () async {
        final runtime = await init(patch: 4, reportCrashes: false);

        expect(runtime.crashReporter, isNull);
      });
    });

    group('assets', () {
      test('falls back to the app bundle when the patch has none', () async {
        final runtime = await init(patch: 4);
        addTearDown(() => runtime.crashReporter?.uninstall());

        expect(runtime.assetBundle, isNot(isA<PatchAssetBundle>()));
      });

      test('serves the patch bundle when there is one', () async {
        final dir = Directory.systemTemp.createTempSync('cpr_runtime');
        addTearDown(() => dir.deleteSync(recursive: true));
        when(
          () => store.ensure(
            patchNumber: any(named: 'patchNumber'),
            releaseVersion: any(named: 'releaseVersion'),
          ),
        ).thenAnswer((_) async => dir);

        final runtime = await init(patch: 4);
        addTearDown(() => runtime.crashReporter?.uninstall());

        expect(runtime.assetBundle, isA<PatchAssetBundle>());
      });

      test('evicts every bundle when no patch is running', () async {
        // Rollback safety: a bundle from a patch that is gone must not outlive
        // it, even though there is nothing to fetch in its place.
        await init();

        verify(store.evictAll).called(1);
      });

      test('serves an assets-only patch the updater cannot see', () async {
        // The case this whole path exists for, and the only way an assets-only
        // patch reaches an iOS device: the native updater reports no patch
        // because the patch carries no code, so without asking the control
        // plane directly the bundle would never be fetched and publishing the
        // patch would silently change nothing.
        final dir = Directory.systemTemp.createTempSync('cpr_assets_only');
        addTearDown(() => dir.deleteSync(recursive: true));
        when(
          () => store.discoverAssetsOnlyPatch(
            releaseVersion: any(named: 'releaseVersion'),
            clientId: any(named: 'clientId'),
          ),
        ).thenAnswer((_) async => 7);
        when(
          () => store.ensure(
            patchNumber: any(named: 'patchNumber'),
            releaseVersion: any(named: 'releaseVersion'),
          ),
        ).thenAnswer((_) async => dir);

        final runtime = await init();
        addTearDown(() => runtime.crashReporter?.uninstall());

        expect(runtime.assetBundle, isA<PatchAssetBundle>());
        expect(runtime.assetsPatchNumber, equals(7));
        // No code is patched, so this stays null and no reporter is installed:
        // an assets-only patch retains no symbols to resolve a frame against.
        expect(runtime.patchNumber, isNull);
        expect(runtime.crashReporter, isNull);
        verify(
          () => store.ensure(patchNumber: 7, releaseVersion: '1.0.0+1'),
        ).called(1);
      });

      test('reports no assets patch when the bundle fetch fails', () async {
        // Discovery succeeding must not be mistaken for assets being served.
        when(
          () => store.discoverAssetsOnlyPatch(
            releaseVersion: any(named: 'releaseVersion'),
            clientId: any(named: 'clientId'),
          ),
        ).thenAnswer((_) async => 7);

        final runtime = await init();

        expect(runtime.assetBundle, isNot(isA<PatchAssetBundle>()));
        expect(runtime.assetsPatchNumber, isNull);
      });

      test('does not ask for assets while a code patch runs', () async {
        // The updater owns that patch; its bundle (if any) comes with it.
        final runtime = await init(patch: 4);
        addTearDown(() => runtime.crashReporter?.uninstall());

        verifyNever(
          () => store.discoverAssetsOnlyPatch(
            releaseVersion: any(named: 'releaseVersion'),
            clientId: any(named: 'clientId'),
          ),
        );
      });
    });

    test('is inert with no self-hosted control plane', () async {
      // No base_url means the hosted service, which offers neither endpoint.
      when(updater.readCurrentPatch).thenAnswer((_) async => null);

      final runtime = await CodePushRuntime.initialize(
        readReleaseVersion: () async => '1.0.0+1',
        environment: null,
        updater: updater,
        assetStore: store,
      );

      expect(runtime.crashReporter, isNull);
      expect(runtime.assetBundle, isNot(isA<PatchAssetBundle>()));
    });
  });
}
