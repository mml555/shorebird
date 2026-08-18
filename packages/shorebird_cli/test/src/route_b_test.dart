import 'dart:io';
import 'dart:typed_data';

import 'package:shorebird_cli/src/route_b.dart';
import 'package:test/test.dart';

/// Build a fake arm64 binary of [sizeBytes] containing [sites] patchable call
/// sequences, so the density thresholds can be exercised without shipping a
/// multi-megabyte fixture.
File _fakeAppBinary(
  Directory dir, {
  required int sizeBytes,
  required int sites,
  String name = 'App',
}) {
  final words = Uint32List(sizeBytes ~/ 4);
  // Fill with a plausible non-matching instruction (nop) so the scan has to
  // actually match rather than trip over zeroed memory.
  words.fillRange(0, words.length, 0xD503201F);
  // Spread the sites out; adjacency of the pair is what matters, not position.
  final stride = sites == 0 ? words.length : (words.length - 2) ~/ sites;
  for (var i = 0; i < sites; i++) {
    final at = i * stride;
    words[at] = 0xF840701E; // ldur lr, [r0, #7]
    words[at + 1] = 0xD63F03C0; // blr lr
  }
  final file = File('${dir.path}/$name')
    ..writeAsBytesSync(words.buffer.asUint8List());
  return file;
}

void main() {
  group('isRouteBEngine', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('route_b'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('is false when the binary does not exist', () {
      expect(isRouteBEngine(File('${tmp.path}/nope')), isFalse);
    });

    test('is false for an engine without the interpreter', () {
      final f = File('${tmp.path}/Flutter')
        ..writeAsBytesSync(
          Uint8List.fromList('some other engine symbols'.codeUnits),
        );
      expect(isRouteBEngine(f), isFalse);
    });

    test('is true when InterpretCall is present', () {
      final f = File('${tmp.path}/Flutter')
        ..writeAsBytesSync(
          Uint8List.fromList('_InterpretCallStub and friends'.codeUnits),
        );
      expect(isRouteBEngine(f), isTrue);
    });

    test('matches a symbol that spans the middle of the file', () {
      final f = File('${tmp.path}/Flutter')
        ..writeAsBytesSync(
          Uint8List.fromList(
            '${'x' * 5000}InterpretCall${'y' * 5000}'.codeUnits,
          ),
        );
      expect(isRouteBEngine(f), isTrue);
    });
  });

  group('countPatchableCallSites', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('route_b'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('counts only ldur+blr PAIRS, not either instruction alone', () {
      // A lone ldur, and a lone blr, neither adjacent to its partner.
      final words = Uint32List(256)..fillRange(0, 256, 0xD503201F);
      words[10] = 0xF840701E;
      words[100] = 0xD63F03C0;
      final f = File('${tmp.path}/App')
        ..writeAsBytesSync(words.buffer.asUint8List());
      expect(countPatchableCallSites(f).sites, isZero);
    });

    test('handles a file whose length is not a multiple of four', () {
      final bytes = <int>[
        ...Uint32List.fromList([0xF840701E, 0xD63F03C0]).buffer.asUint8List(),
        0xAB, // ragged tail
      ];
      final f = File('${tmp.path}/App')
        ..writeAsBytesSync(Uint8List.fromList(bytes));
      expect(countPatchableCallSites(f).sites, equals(1));
    });
  });

  group('isPatchableRelease', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('route_b'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('is false when the binary does not exist', () {
      expect(isPatchableRelease(File('${tmp.path}/nope')), isFalse);
    });

    // The two data points that motivated a density threshold rather than
    // `> 0`. Release 8.0.0+1 was built WITHOUT --patchable_static_calls and
    // still contained 8 sites, because AOT already dispatches some closure and
    // tear-off calls through entry_point_. Reproducing both densities here is
    // what keeps the threshold honest if anyone retunes it.
    test('rejects the density of a release built without the flag', () {
      final f = _fakeAppBinary(tmp, sizeBytes: 3989024, sites: 8);
      final result = countPatchableCallSites(f);
      expect(result.sites, equals(8));
      expect(result.perMiB, lessThan(10));
      expect(isPatchableRelease(f), isFalse);
    });

    test('accepts the density of a release built with the flag', () {
      final f = _fakeAppBinary(tmp, sizeBytes: 4169856, sites: 7109);
      final result = countPatchableCallSites(f);
      expect(result.sites, equals(7109));
      expect(result.perMiB, greaterThan(1000));
      expect(isPatchableRelease(f), isTrue);
    });

    test('the two real densities sit on opposite sides of the threshold', () {
      final notPatchable = _fakeAppBinary(
        tmp,
        sizeBytes: 3989024,
        sites: 8,
        name: 'AppOld',
      );
      final patchable = _fakeAppBinary(
        tmp,
        sizeBytes: 4169856,
        sites: 7109,
        name: 'AppNew',
      );
      expect(
        countPatchableCallSites(notPatchable).perMiB,
        lessThan(routeBPatchableSitesPerMiBThreshold),
      );
      expect(
        countPatchableCallSites(patchable).perMiB,
        greaterThan(routeBPatchableSitesPerMiBThreshold),
      );
    });
  });
}
