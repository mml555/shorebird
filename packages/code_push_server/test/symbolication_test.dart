// Unit tests for `lib/src/symbolication.dart`.
//
// The arch-selection logic is the part worth guarding hardest: picking the
// wrong symbol file does not fail, it silently resolves every frame to a wrong
// address, which is worse than not symbolicating at all.
// cspell:words symbolicate symbolicated symbolication armeabi
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_push_server/src/artifact_store.dart';
import 'package:code_push_server/src/domain.dart';
import 'package:code_push_server/src/repository.dart';
import 'package:code_push_server/src/symbolication.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A zip containing one entry per name, each holding [contents].
List<int> zipWith(List<String> names, {String contents = 'not-real-dwarf'}) {
  final archive = Archive();
  for (final name in names) {
    archive.addFile(ArchiveFile(name, contents.length, contents.codeUnits));
  }
  return ZipEncoder().encode(archive);
}

Archive archiveWith(List<String> names) =>
    ZipDecoder().decodeBytes(zipWith(names));

ArtifactRow symbolsRow({required String storageKey, int id = 1}) => ArtifactRow(
  id: id,
  token: 'tok-$id',
  ownerKind: 'patch',
  ownerId: 1,
  arch: symbolsArch,
  platform: 'android',
  hash: 'deadbeef',
  size: 0,
  hashSignature: null,
  podfileLockHash: null,
  canSideload: false,
  status: ArtifactStatus.verified,
  storageKey: storageKey,
  createdAt: '2026-07-29T00:00:00.000Z',
);

void main() {
  group('archToken', () {
    test('maps every spelling in circulation', () {
      // The value comes from a device, and three naming schemes are in play:
      // the CLI's artifact names, Android ABI names, and Flutter target names.
      for (final arch in ['arm64', 'aarch64', 'arm64-v8a', 'ARM64']) {
        expect(Symbolizer.archToken(arch), equals('arm64'), reason: arch);
      }
      for (final arch in ['arm', 'arm32', 'armv7', 'armeabi-v7a']) {
        expect(Symbolizer.archToken(arch), equals('arm'), reason: arch);
      }
      for (final arch in ['x64', 'x86_64']) {
        expect(Symbolizer.archToken(arch), equals('x64'), reason: arch);
      }
    });

    test('is null for unknown or absent values', () {
      expect(Symbolizer.archToken(null), isNull);
      expect(Symbolizer.archToken(''), isNull);
      expect(Symbolizer.archToken('riscv64'), isNull);
    });
  });

  group('selectEntry', () {
    const androidEntries = [
      'app.android-arm.symbols',
      'app.android-arm64.symbols',
      'app.android-x64.symbols',
    ];

    test('takes the only entry regardless of arch', () {
      // Apple retains a single file for both iOS and macOS, so the common case
      // needs no matching at all.
      final archive = archiveWith(['app.ios-arm64.symbols']);

      expect(
        Symbolizer.selectEntry(archive, 'arm64')?.name,
        equals('app.ios-arm64.symbols'),
      );
      expect(
        Symbolizer.selectEntry(archive, null)?.name,
        equals('app.ios-arm64.symbols'),
      );
    });

    test('does not hand arm64 symbols to an arm32 crash', () {
      // The regression this guards: `contains('arm')` matches
      // `app.android-arm64.symbols`, which resolves every frame wrongly.
      final archive = archiveWith(androidEntries);

      expect(
        Symbolizer.selectEntry(archive, 'arm')?.name,
        equals('app.android-arm.symbols'),
      );
      expect(
        Symbolizer.selectEntry(archive, 'armeabi-v7a')?.name,
        equals('app.android-arm.symbols'),
      );
    });

    test('picks the matching entry for each arch', () {
      final archive = archiveWith(androidEntries);

      expect(
        Symbolizer.selectEntry(archive, 'aarch64')?.name,
        equals('app.android-arm64.symbols'),
      );
      expect(
        Symbolizer.selectEntry(archive, 'x86_64')?.name,
        equals('app.android-x64.symbols'),
      );
    });

    test('refuses to guess between several entries', () {
      // Confidently wrong line numbers are worse than an unresolved trace.
      final archive = archiveWith(androidEntries);

      expect(Symbolizer.selectEntry(archive, null), isNull);
      expect(Symbolizer.selectEntry(archive, 'riscv64'), isNull);
    });

    test('is null when nothing looks like a symbol file', () {
      expect(
        Symbolizer.selectEntry(archiveWith(['README.md']), 'arm64'),
        isNull,
      );
      expect(Symbolizer.selectEntry(Archive(), 'arm64'), isNull);
    });
  });

  group('symbolicate', () {
    late Directory tmp;
    late ArtifactStore store;
    late Symbolizer symbolizer;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('cps_symbolication');
      store = await ArtifactStore.open(sqliteConfig(tmp.path));
      symbolizer = Symbolizer(store: store);
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    /// Stores [bytes] and returns a row pointing at them.
    Future<ArtifactRow> stored(List<int> bytes, {int id = 1}) async {
      final key = 'patch/1/symbols-$id';
      await store.put(key, bytes);
      return symbolsRow(storageKey: key, id: id);
    }

    const stack = '''
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
pid: 1234, tid: 5678, name 1.ui
    #00 abs 00000000006a1b2c virt 00000000002a1b2c''';

    test('is null when the artifact is empty', () async {
      final row = await stored(<int>[]);

      await expectLater(
        symbolizer.symbolicate(stack: stack, symbols: row, arch: 'arm64'),
        completion(isNull),
      );
    });

    test('is null when the zip carries no symbol file', () async {
      final row = await stored(zipWith(['README.md']));

      await expectLater(
        symbolizer.symbolicate(stack: stack, symbols: row, arch: 'arm64'),
        completion(isNull),
      );
    });

    test('is null, not an exception, on unparseable symbol bytes', () async {
      // A symbol file that is not valid ELF/Mach-O must degrade, because the
      // raw stack is still worth showing.
      final row = await stored(zipWith(['app.android-arm64.symbols']));

      await expectLater(
        symbolizer.symbolicate(stack: stack, symbols: row, arch: 'arm64'),
        completion(isNull),
      );
    });

    test('is null, not an exception, when the artifact is not a zip', () async {
      final row = await stored('this is not a zip at all'.codeUnits);

      await expectLater(
        symbolizer.symbolicate(stack: stack, symbols: row, arch: 'arm64'),
        completion(isNull),
      );
    });

    test('is null when arch cannot pick between several entries', () async {
      final row = await stored(
        zipWith(['app.android-arm.symbols', 'app.android-arm64.symbols']),
      );

      await expectLater(
        symbolizer.symbolicate(stack: stack, symbols: row, arch: null),
        completion(isNull),
      );
    });

    test('repeated failures stay null and do not throw', () async {
      // Exercises the negative cache: a broken artifact must not be re-fetched
      // and re-parsed on every request, and must answer the same each time.
      final row = await stored(zipWith(['app.android-arm64.symbols']));

      for (var i = 0; i < 3; i++) {
        await expectLater(
          symbolizer.symbolicate(stack: stack, symbols: row, arch: 'arm64'),
          completion(isNull),
        );
      }
    });
  });
}
