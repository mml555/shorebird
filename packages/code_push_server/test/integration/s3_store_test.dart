@Tags(['integration'])
library;

import 'dart:io';
import 'dart:math';

import 'package:code_push_server/src/artifact_store.dart';
import 'package:code_push_server/src/config.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

/// Runs every operation the server issues against a real S3-compatible store.
/// Opt-in: set `INTEGRATION=1` and `S3_ENDPOINT` (plus `S3_ACCESS_KEY`,
/// `S3_SECRET_KEY`, and optionally `S3_BUCKET`, `S3_REGION`, `S3_PATH_STYLE`).
///
///   INTEGRATION=1 S3_ENDPOINT=http://localhost:8333 S3_ACCESS_KEY=cps \
///   S3_SECRET_KEY=... dart test --tags integration test/integration/s3_store_test.dart
void main() {
  final env = Platform.environment;
  final skip = env['INTEGRATION'] != '1' || (env['S3_ENDPOINT'] ?? '').isEmpty
      ? 'opt-in: set INTEGRATION=1 and S3_ENDPOINT'
      : null;

  group('S3ArtifactStore against a live store', () {
    late ArtifactStore store;
    final key = 'it/${DateTime.now().microsecondsSinceEpoch}/obj';
    // 1 MiB of non-repeating bytes, so a wrong range cannot pass by accident.
    final rnd = Random(7);
    final data = List<int>.generate(1 << 20, (_) => rnd.nextInt(256));

    setUpAll(() async {
      final bucket = 'cps-it-${DateTime.now().millisecondsSinceEpoch}';
      store = await ArtifactStore.open(
        Config.fromEnv({...env, 'S3_BUCKET': bucket, 'STORAGE_BACKEND': 's3'}),
      );
    });

    test('ping, put, exists, size, verify', () async {
      expect(await store.ping(), isTrue);
      expect(await store.exists(key), isFalse);
      await store.put(key, data);
      expect(await store.exists(key), isTrue);
      expect(await store.size(key), data.length);
      final hash = sha256.convert(data).toString();
      expect(
        await store.verify(key, hash, data.length, checkHash: true),
        isNull,
      );
      expect(
        await store.verify(key, 'deadbeef', data.length, checkHash: true),
        contains('hash mismatch'),
      );
    });

    test('ranged reads return exactly the requested bytes', () async {
      Future<List<int>> read({int? o, int? l}) async =>
          (await (await store.openRead(
            key,
            offset: o,
            length: l,
          )).expand((c) => c).toList());
      expect(await read(), data);
      expect(await read(o: 0, l: 4), data.sublist(0, 4));
      expect(await read(o: 1000, l: 5000), data.sublist(1000, 6000));
      expect(await read(o: data.length - 10), data.sublist(data.length - 10));
    });

    test('resumable staging commits to the store', () async {
      const token = 'it-token';
      await store.stageChunk(token, 0, data.sublist(0, 1000));
      expect(store.stagedSize(token), 1000);
      await store.stageChunk(token, 1000, data.sublist(1000, 5000));
      await store.commitStaged(token, '$key-staged');
      expect(await store.size('$key-staged'), 5000);
      await store.delete('$key-staged');
    });

    test('delete removes the object and tolerates a repeat', () async {
      await store.delete(key);
      await store.delete(key);
      expect(await store.exists(key), isFalse);
      await expectLater(store.size(key), throwsException);
      await expectLater(store.openRead(key), throwsException);
    });
  }, skip: skip);
}
