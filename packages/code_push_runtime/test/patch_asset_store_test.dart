import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_push_runtime/code_push_runtime.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

/// A zip holding `assets/marker.json` with [marker].
List<int> bundleZip(String marker) {
  final body = '{"marker":"$marker"}';
  final archive = Archive()
    ..addFile(
      ArchiveFile('assets/marker.json', body.length, body.codeUnits),
    )
    ..addFile(ArchiveFile('AssetManifest.bin', 2, [0, 1]));
  return ZipEncoder().encode(archive);
}

void main() {
  final environment = ShorebirdEnvironment(
    appId: 'app-1',
    baseUrl: Uri.parse('https://cps.test/'),
  );

  group(PatchAssetStore, () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('cpr_assets');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    /// A store whose control plane serves [zip] for the patch, unless
    /// [available] is false or [status] is not 200.
    PatchAssetStore storeServing({
      List<int>? zip,
      bool available = true,
      int status = HttpStatus.ok,
      String? hashOverride,
      void Function(Map<String, Object?> body)? onDescribe,
    }) {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('patches/assets')) {
          onDescribe?.call(
            jsonDecode(request.body) as Map<String, Object?>,
          );
          if (!available) {
            return http.Response(
              jsonEncode({'assets_available': false, 'assets': null}),
              HttpStatus.ok,
            );
          }
          return http.Response(
            jsonEncode({
              'assets_available': true,
              'assets': {
                'url': 'https://cps.test/download/tok?sig=x',
                'hash':
                    hashOverride ?? sha256.convert(zip ?? <int>[]).toString(),
                'size': (zip ?? <int>[]).length,
              },
            }),
            HttpStatus.ok,
          );
        }
        if (status != HttpStatus.ok) return http.Response('', status);
        return http.Response.bytes(zip ?? <int>[], HttpStatus.ok);
      });

      return PatchAssetStore(
        environment: environment,
        rootDirectory: root,
        httpClient: client,
      );
    }

    test('downloads, unpacks and caches a bundle', () async {
      final store = storeServing(zip: bundleZip('v2'));

      final dir = await store.ensure(patchNumber: 7, releaseVersion: '1.0.0+1');

      expect(dir, isNotNull);
      expect(
        File(p.join(dir!.path, 'assets', 'marker.json')).readAsStringSync(),
        equals('{"marker":"v2"}'),
      );
      expect(store.isCached(7), isTrue);
    });

    test('serves the cache on a second call without refetching', () async {
      var describes = 0;
      final store = storeServing(
        zip: bundleZip('v2'),
        onDescribe: (_) => describes++,
      );

      await store.ensure(patchNumber: 7, releaseVersion: '1.0.0+1');
      await store.ensure(patchNumber: 7, releaseVersion: '1.0.0+1');

      expect(describes, equals(1));
    });

    test('sends the patch number and release it is asking about', () async {
      Map<String, Object?>? body;
      final store = storeServing(
        zip: bundleZip('v2'),
        onDescribe: (b) => body = b,
      );

      await store.ensure(patchNumber: 9, releaseVersion: '2.0.0+3');

      expect(body!['app_id'], equals('app-1'));
      expect(body!['patch_number'], equals(9));
      expect(body!['release_version'], equals('2.0.0+3'));
      expect(body!['platform'], isNotNull);
    });

    test('is null when the patch has no bundle', () async {
      final store = storeServing(available: false);

      await expectLater(
        store.ensure(patchNumber: 7, releaseVersion: '1.0.0+1'),
        completion(isNull),
      );
      expect(store.isCached(7), isFalse);
    });

    test('is null when the download fails', () async {
      final store = storeServing(
        zip: bundleZip('v2'),
        status: HttpStatus.internalServerError,
      );

      await expectLater(
        store.ensure(patchNumber: 7, releaseVersion: '1.0.0+1'),
        completion(isNull),
      );
    });

    test('rejects a bundle whose hash does not match', () async {
      // Catches a truncated transfer before it becomes a cached directory that
      // looks complete and serves broken assets on every later launch.
      final store = storeServing(
        zip: bundleZip('v2'),
        hashOverride: 'not-the-real-hash',
      );

      await expectLater(
        store.ensure(patchNumber: 7, releaseVersion: '1.0.0+1'),
        completion(isNull),
      );
      expect(store.isCached(7), isFalse);
    });

    test('leaves nothing cached when the payload is not a zip', () async {
      final store = storeServing(zip: 'definitely not a zip'.codeUnits);

      await expectLater(
        store.ensure(patchNumber: 7, releaseVersion: '1.0.0+1'),
        completion(isNull),
      );
      // Half-unpacked state must never be published under the real name.
      expect(store.isCached(7), isFalse);
      expect(store.directoryFor(7).existsSync(), isFalse);
    });

    group('rollback safety', () {
      test('a different running patch evicts the older bundle', () async {
        // The invariant: assets from a patch that is no longer running would
        // pair new assets with old code.
        final store = storeServing(zip: bundleZip('v2'));
        await store.ensure(patchNumber: 7, releaseVersion: '1.0.0+1');
        expect(store.isCached(7), isTrue);

        await store.ensure(patchNumber: 8, releaseVersion: '1.0.0+1');

        expect(store.isCached(7), isFalse);
        expect(store.directoryFor(7).existsSync(), isFalse);
      });

      test('eviction happens even when the new patch has no bundle', () async {
        final serving = storeServing(zip: bundleZip('v2'));
        await serving.ensure(patchNumber: 7, releaseVersion: '1.0.0+1');
        expect(serving.isCached(7), isTrue);

        // Rolling back to a patch with no assets of its own must still drop the
        // newer bundle, which is why eviction is unconditional.
        final empty = storeServing(available: false);
        await empty.ensure(patchNumber: 8, releaseVersion: '1.0.0+1');

        expect(empty.isCached(7), isFalse);
      });

      test('evictAll drops everything when no patch is running', () async {
        final store = storeServing(zip: bundleZip('v2'));
        await store.ensure(patchNumber: 7, releaseVersion: '1.0.0+1');

        store.evictAll();

        expect(store.isCached(7), isFalse);
        expect(root.listSync().whereType<Directory>(), isEmpty);
      });
    });

    test('ignores zip entries that escape the bundle', () async {
      const body = 'pwned';
      final archive = Archive()
        ..addFile(
          ArchiveFile('../../escaped.txt', body.length, body.codeUnits),
        )
        ..addFile(ArchiveFile('ok.txt', 2, [0, 1]));
      final zip = ZipEncoder().encode(archive);

      final store = storeServing(zip: zip);
      final dir = await store.ensure(
        patchNumber: 7,
        releaseVersion: '1.0.0+1',
      );

      expect(dir, isNotNull);
      expect(File(p.join(dir!.path, 'ok.txt')).existsSync(), isTrue);
      expect(
        File(p.join(root.parent.path, 'escaped.txt')).existsSync(),
        isFalse,
      );
    });
  });
}
