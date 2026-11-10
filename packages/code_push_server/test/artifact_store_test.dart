import 'dart:async';
import 'dart:io';

import 'package:code_push_server/src/artifact_store.dart';
import 'package:test/test.dart';

void main() {
  group('FilesystemArtifactStore.put', () {
    late Directory tmp;
    late FilesystemArtifactStore store;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('cps_store');
      store = FilesystemArtifactStore(
        Directory('${tmp.path}/artifacts')..createSync(),
        Directory('${tmp.path}/staging')..createSync(),
      );
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('is atomic: a reader never sees a partial object', () async {
      const size = 48 * 1024 * 1024;
      final bytes = List<int>.filled(size, 7);
      final target = File('${tmp.path}/artifacts/patch/1/tok');
      await store.put('patch/1/tok', [1, 2, 3]);

      var done = false;
      final writing = store.put('patch/1/tok', bytes).whenComplete(() {
        done = true;
      });
      final seen = <int>{};
      while (!done) {
        try {
          seen.add(target.lengthSync());
        } on FileSystemException {
          // Missing is also a state a reader must not see mid-write.
          seen.add(-1);
        }
        await Future<void>.delayed(Duration.zero);
      }
      await writing;

      // Old object, then the whole new one; never empty, missing or a prefix.
      expect(seen.difference({3, size}), isEmpty);
      expect(target.lengthSync(), size);
    });

    test(
      'the sweep removes old temp files and keeps young ones and objects',
      () async {
        await store.put('patch/1/tok', [1, 2, 3]);
        final dir = '${tmp.path}/artifacts/patch/1';
        final old = File('$dir/tok.tmp-aaaa')..writeAsBytesSync([1]);
        old.setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 3)),
        );
        final young = File('$dir/tok.tmp-bbbb')..writeAsBytesSync([1]);

        FilesystemArtifactStore.sweepTempFiles(
          Directory('${tmp.path}/artifacts'),
        );

        expect(old.existsSync(), isFalse);
        expect(young.existsSync(), isTrue);
        expect(File('$dir/tok').existsSync(), isTrue);
      },
    );

    test('leaves no temp file behind', () async {
      await store.put('patch/1/tok', [1, 2, 3]);
      final names = Directory(
        '${tmp.path}/artifacts/patch/1',
      ).listSync().map((e) => e.uri.pathSegments.last).toList();
      expect(names, ['tok']);
    });
  });
}
