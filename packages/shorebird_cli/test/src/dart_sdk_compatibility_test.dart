import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/dart_sdk_compatibility.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:test/test.dart';

import 'mocks.dart';

void main() {
  group(DartSdkCompatibility, () {
    // The iOS pairing from selfhost/cdn/experimental_hashes.map, at the
    // full length both files actually record.
    const knownEngine = '70974f811d448da19a927c581678ef1dbd33605c';
    const matchingSdk = '6b58bb3a72e293e27ff920a61c007bf2e405071e';
    const stockEngine = '69f9831c360d9152862ec3897c67fb09ae843f3b';
    const foreignSdk = 'db98bdaa9d8f8e2250ff83d24abcaf775807244c';

    late Directory flutterDirectory;
    late Directory shorebirdRoot;
    late ShorebirdEnv shorebirdEnv;
    late DartSdkCompatibility compatibility;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        () => body(),
        values: {shorebirdEnvRef.overrideWith(() => shorebirdEnv)},
      );
    }

    void writeSdkRevision(String revision) {
      File(
          p.join(
            flutterDirectory.path,
            'bin',
            'cache',
            'dart-sdk',
            'revision',
          ),
        )
        ..createSync(recursive: true)
        ..writeAsStringSync('$revision\n');
    }

    setUp(() {
      shorebirdRoot = Directory.systemTemp.createTempSync();
      flutterDirectory = Directory(
        p.join(shorebirdRoot.path, 'bin', 'cache', 'flutter', 'rev'),
      )..createSync(recursive: true);
      shorebirdEnv = MockShorebirdEnv();
      compatibility = DartSdkCompatibility();
      when(() => shorebirdEnv.flutterDirectory).thenReturn(flutterDirectory);
      when(() => shorebirdEnv.shorebirdRoot).thenReturn(shorebirdRoot);
    });

    tearDown(() => shorebirdRoot.deleteSync(recursive: true));

    group('validate', () {
      test('does nothing when the engine is not one of ours', () {
        when(() => shorebirdEnv.shorebirdEngineRevision).thenReturn(
          stockEngine,
        );
        // Deliberately not written: an unlisted engine must not even be
        // required to have a readable revision file.
        expect(() => runWithOverrides(compatibility.validate), returnsNormally);
      });

      test('does nothing when the Dart SDK matches the engine', () {
        when(() => shorebirdEnv.shorebirdEngineRevision).thenReturn(
          knownEngine,
        );
        writeSdkRevision(matchingSdk);
        expect(() => runWithOverrides(compatibility.validate), returnsNormally);
      });

      test('throws when the Dart SDK is from a different tree', () {
        when(() => shorebirdEnv.shorebirdEngineRevision).thenReturn(
          knownEngine,
        );
        writeSdkRevision(foreignSdk);
        expect(
          () => runWithOverrides(compatibility.validate),
          throwsA(isA<DartSdkMismatchException>()),
        );
      });

      test('throws when the revision file cannot be read', () {
        when(() => shorebirdEnv.shorebirdEngineRevision).thenReturn(
          knownEngine,
        );
        // Not written at all: unable to confirm is treated as a mismatch.
        expect(
          () => runWithOverrides(compatibility.validate),
          throwsA(
            isA<DartSdkMismatchException>().having(
              (e) => e.actualDartSdkRevision,
              'actualDartSdkRevision',
              isNull,
            ),
          ),
        );
      });

      test('checks every engine in the table', () {
        for (final entry
            in DartSdkCompatibility.expectedDartSdkRevisions.entries) {
          when(
            () => shorebirdEnv.shorebirdEngineRevision,
          ).thenReturn(entry.key);
          writeSdkRevision(foreignSdk);
          expect(
            () => runWithOverrides(compatibility.validate),
            throwsA(isA<DartSdkMismatchException>()),
            reason: 'engine ${entry.key} should be checked',
          );
          writeSdkRevision(entry.value);
          expect(
            () => runWithOverrides(compatibility.validate),
            returnsNormally,
            reason: 'engine ${entry.key} should accept ${entry.value}',
          );
        }
      });
    });

    group(DartSdkMismatchException, () {
      late DartSdkMismatchException exception;

      setUp(() {
        exception = DartSdkMismatchException(
          engineRevision: knownEngine,
          expectedDartSdkRevision: matchingSdk,
          actualDartSdkRevision: foreignSdk,
          flutterDirectory: '/flutter',
          shorebirdRoot: '/shorebird',
        );
      });

      test('names the engine, both revisions, and how to fix it', () {
        expect(
          exception.toString(),
          allOf(
            contains(knownEngine),
            contains(matchingSdk),
            contains(foreignSdk),
            contains('/flutter/bin/internal/engine.version'),
            contains('/flutter/bin/cache/flutter_tools.stamp'),
            contains('/flutter/bin/cache/engine-dart-sdk.stamp'),
            contains('/shorebird/bin/cache/shorebird.stamp'),
          ),
        );
      });

      test('says the build would otherwise succeed', () {
        // The whole reason this check exists: "it compiled" is not evidence.
        expect(exception.toString(), contains('SUCCEEDS'));
      });

      test('reports an unreadable revision rather than an empty one', () {
        expect(
          DartSdkMismatchException(
            engineRevision: knownEngine,
            expectedDartSdkRevision: matchingSdk,
            actualDartSdkRevision: null,
            flutterDirectory: '/flutter',
            shorebirdRoot: '/shorebird',
          ).toString(),
          contains('<unreadable>'),
        );
      });
    });
  });
}
