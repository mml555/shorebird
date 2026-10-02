import 'dart:convert';
import 'dart:io';

import 'package:code_push_runtime/code_push_runtime.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A bundle serving a fixed set of keys, standing in for the app's compiled-in
/// assets.
class _FakeBundle extends CachingAssetBundle {
  _FakeBundle(this.entries);

  final Map<String, String> entries;
  final loadedKeys = <String>[];

  @override
  Future<ByteData> load(String key) async {
    loadedKeys.add(key);
    final value = entries[key];
    if (value == null) throw Exception('missing: $key');
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(value)));
  }
}

void main() {
  group(PatchAssetBundle, () {
    late Directory dir;
    late _FakeBundle fallback;
    late PatchAssetBundle bundle;

    void write(String relative, String contents) {
      File(p.join(dir.path, relative))
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);
    }

    setUp(() {
      dir = Directory.systemTemp.createTempSync('cpr_bundle');
      fallback = _FakeBundle({
        'assets/marker.json': '{"marker":"release"}',
        'assets/only_in_release.json': '{"kept":true}',
      });
      bundle = PatchAssetBundle(directory: dir, fallback: fallback);
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('prefers the patch bundle over the compiled-in asset', () async {
      write('assets/marker.json', '{"marker":"patched"}');

      await expectLater(
        bundle.loadString('assets/marker.json'),
        completion(equals('{"marker":"patched"}')),
      );
      expect(fallback.loadedKeys, isEmpty);
    });

    test('falls back for a key the patch does not carry', () async {
      write('assets/marker.json', '{"marker":"patched"}');

      // Overlay, not replacement: a patch that ships one changed asset must not
      // make every other asset disappear.
      await expectLater(
        bundle.loadString('assets/only_in_release.json'),
        completion(equals('{"kept":true}')),
      );
      expect(fallback.loadedKeys, contains('assets/only_in_release.json'));
    });

    test('load() reads bytes from the patch bundle', () async {
      write('a.txt', 'hello');

      final data = await bundle.load('a.txt');

      expect(utf8.decode(data.buffer.asUint8List()), equals('hello'));
    });

    test('load() falls back when absent', () async {
      final data = await bundle.load('assets/marker.json');

      expect(
        utf8.decode(data.buffer.asUint8List()),
        equals('{"marker":"release"}'),
      );
    });

    test('loadStructuredData parses from the patch bundle', () async {
      write('assets/marker.json', '{"marker":"patched"}');

      final decoded = await bundle.loadStructuredData(
        'assets/marker.json',
        (value) async => jsonDecode(value) as Map<String, Object?>,
      );

      expect(decoded['marker'], equals('patched'));
    });

    test('loadBuffer reads the patch bundle', () async {
      write('a.txt', 'hello');

      final buffer = await bundle.loadBuffer('a.txt');

      expect(buffer.length, equals(5));
    });

    group('key traversal', () {
      test('a key escaping the bundle falls back instead of reading', () async {
        // `../` in a key must never reach outside the unpacked bundle.
        File(
          p.join(dir.parent.path, 'outside.txt'),
        ).writeAsStringSync('secret');
        fallback.entries['../outside.txt'] = 'from-fallback';

        await expectLater(
          bundle.loadString('../outside.txt'),
          completion(equals('from-fallback')),
        );
      });
    });
  });
}
