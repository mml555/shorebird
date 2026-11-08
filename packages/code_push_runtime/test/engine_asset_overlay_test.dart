import 'dart:io';

import 'package:code_push_runtime/src/engine_asset_overlay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group(EngineAssetOverlay, () {
    late Directory tempDir;
    late Directory root;
    late Directory bundle;

    const appId = 'app-id';

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('overlay');
      root = Directory(p.join(tempDir.path, 'root'))..createSync();
      bundle = Directory(p.join(tempDir.path, 'bundle'))..createSync();
      File(p.join(bundle.path, 'assets', 'logo.png'))
        ..createSync(recursive: true)
        ..writeAsStringSync('PATCHED');
      File(p.join(bundle.path, 'fonts', 'Probe.ttf'))
        ..createSync(recursive: true)
        ..writeAsStringSync('FONT');
    });

    tearDown(() => tempDir.deleteSync(recursive: true));

    EngineAssetOverlay overlay() =>
        EngineAssetOverlay(appId: appId, searchRoots: [root]);

    Directory makeAndroidPatchDir(int n) =>
        Directory(p.join(root.path, 'shorebird_updater', 'patches', '$n'))
          ..createSync(recursive: true);

    Directory makeAppIdPatchDir(int n) => Directory(
      p.join(root.path, 'shorebird_updater', appId, 'patches', '$n'),
    )..createSync(recursive: true);

    group('patchDirectory', () {
      test('finds the Android layout, which omits the app id', () {
        final dir = makeAndroidPatchDir(1);
        expect(overlay().patchDirectory(1)?.path, equals(dir.path));
      });

      test('finds the desktop/iOS layout, which includes the app id', () {
        final dir = makeAppIdPatchDir(1);
        expect(overlay().patchDirectory(1)?.path, equals(dir.path));
      });

      test('returns null rather than inventing a directory', () {
        // The updater owns this tree; creating a patch directory it does not
        // consider installed would be writing into someone else's state.
        expect(overlay().patchDirectory(1), isNull);
      });
    });

    group('install', () {
      test('places the tree where the engine resolver reads it', () {
        final patchDir = makeAndroidPatchDir(1);

        expect(
          overlay().install(patchNumber: 1, bundle: bundle),
          isTrue,
        );

        final installed = p.join(patchDir.path, 'flutter_assets');
        expect(
          File(p.join(installed, 'assets', 'logo.png')).readAsStringSync(),
          equals('PATCHED'),
        );
        expect(
          File(p.join(installed, 'fonts', 'Probe.ttf')).readAsStringSync(),
          equals('FONT'),
        );
      });

      test('leaves no staging directory behind', () {
        final patchDir = makeAndroidPatchDir(1);
        overlay().install(patchNumber: 1, bundle: bundle);
        final staging = Directory(
          p.join(patchDir.path, 'flutter_assets.staging'),
        );
        expect(staging.existsSync(), isFalse);
      });

      test('replaces an existing overlay rather than merging into it', () {
        final patchDir = makeAndroidPatchDir(1);
        final stale =
            File(p.join(patchDir.path, 'flutter_assets', 'assets', 'gone.png'))
              ..createSync(recursive: true)
              ..writeAsStringSync('STALE');

        overlay().install(patchNumber: 1, bundle: bundle);

        // A merge would leave assets from a previous patch resolving over the
        // app's, which is the mismatch the whole design exists to avoid.
        expect(stale.existsSync(), isFalse);
      });

      test('omits dotfiles, which the engine would read as assets', () {
        final patchDir = makeAndroidPatchDir(1);
        File(p.join(bundle.path, '.complete')).writeAsStringSync('');

        overlay().install(patchNumber: 1, bundle: bundle);

        expect(
          File(
            p.join(patchDir.path, 'flutter_assets', '.complete'),
          ).existsSync(),
          isFalse,
        );
      });

      test('does nothing when the updater has no directory for the patch', () {
        expect(overlay().install(patchNumber: 9, bundle: bundle), isFalse);
      });

      test('does nothing, and does not throw, for a missing bundle', () {
        makeAndroidPatchDir(1);
        expect(
          overlay().install(
            patchNumber: 1,
            bundle: Directory(p.join(tempDir.path, 'nope')),
          ),
          isFalse,
        );
      });

      test('reports failure for an empty bundle instead of publishing it', () {
        final patchDir = makeAndroidPatchDir(1);
        final empty = Directory(p.join(tempDir.path, 'empty'))..createSync();

        expect(overlay().install(patchNumber: 1, bundle: empty), isFalse);
        expect(
          Directory(p.join(patchDir.path, 'flutter_assets')).existsSync(),
          isFalse,
        );
      });
    });
  });
}
