import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:platform/platform.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/src/base/process.dart';
import 'package:shorebird_cli/src/toolchain_coherence.dart';
import 'package:test/test.dart';

import 'mocks.dart';

void main() {
  group(ToolchainCoherence, () {
    const cell = 'ca7d2c0d43bf975db2c42cc0aa6351d527443abf';
    const stock = '69f9831c360d9152862ec3897c67fb09ae843f3b';

    late Directory flutterDir;
    late ToolchainCoherence coherence;

    /// Builds a checkout whose stamps and gen_snapshots are what the arguments
    /// say. Defaults are the COHERENT case, so each test states only its defect.
    void makeCheckout({
      String engineStamp = cell,
      String? dartSdkStamp = cell,
      bool patchableGenSnapshot = true,
    }) {
      final cache = Directory(p.join(flutterDir.path, 'bin', 'cache'))
        ..createSync(recursive: true);
      File(
        p.join(cache.path, 'engine.stamp'),
      ).writeAsStringSync('$engineStamp\n');
      if (dartSdkStamp != null) {
        File(
          p.join(cache.path, 'engine-dart-sdk.stamp'),
        ).writeAsStringSync('$dartSdkStamp\n');
      }
      for (final mode in ['ios', 'ios-profile', 'ios-release']) {
        final dir = Directory(p.join(cache.path, 'artifacts', 'engine', mode))
          ..createSync(recursive: true);
        // A stand-in binary: what the check looks for is the flag NAME as a
        // delimited token, exactly as the VM stores it.
        final body = patchableGenSnapshot
            ? 'xx patchable_static_calls yy'
            : 'xx some_other_flag yy';
        File(p.join(dir.path, 'gen_snapshot_arm64')).writeAsStringSync(body);
      }
    }

    setUp(() {
      flutterDir = Directory.systemTemp.createTempSync('coherence');
      coherence = const ToolchainCoherence();
    });

    tearDown(() {
      if (flutterDir.existsSync()) flutterDir.deleteSync(recursive: true);
    });

    test('reports nothing when the toolchain is coherent', () {
      makeCheckout();
      expect(
        coherence.check(flutterDirectory: flutterDir, engineRevision: cell),
        isEmpty,
      );
    });

    test('catches a stale HOST DART SDK, the defect this exists for', () {
      // engine.version and the engine artifacts agree; only the kernel producer
      // is behind. This is precisely the state that produced an app.dill which
      // aborted the mandatory snapshot-profile writer while gen_snapshot was
      // byte-identical to a known-good one.
      makeCheckout(dartSdkStamp: stock);
      final problems = coherence.check(
        flutterDirectory: flutterDir,
        engineRevision: cell,
      );
      expect(problems, hasLength(1));
      expect(problems.single.code, ToolchainIncoherence.hostDartSdkStale);
      // The identities must be in the message; 'stale' alone is not actionable.
      expect(problems.single.detail, contains(stock));
      expect(problems.single.detail, contains(cell));
    });

    test('catches stale engine artifacts', () {
      makeCheckout(engineStamp: stock);
      final problems = coherence.check(
        flutterDirectory: flutterDir,
        engineRevision: cell,
      );
      expect(
        problems.map((e) => e.code),
        contains(ToolchainIncoherence.engineArtifactsStale),
      );
    });

    test('a MISSING stamp is undeterminable, not coherent', () {
      // Not established is not the same as unchanged.
      makeCheckout(dartSdkStamp: null);
      final problems = coherence.check(
        flutterDirectory: flutterDir,
        engineRevision: cell,
      );
      expect(problems, hasLength(1));
      expect(problems.single.code, ToolchainIncoherence.undeterminable);
    });

    test('catches a stock gen_snapshot', () {
      makeCheckout(patchableGenSnapshot: false);
      final problems = coherence.check(
        flutterDirectory: flutterDir,
        engineRevision: cell,
      );
      expect(problems, hasLength(3)); // one per iOS mode
      expect(problems.map((e) => e.code).toSet(), {
        ToolchainIncoherence.genSnapshotNotPatchable,
      });
    });

    test('does not match the flag name inside a longer identifier', () {
      // Guards the token check itself: a binary mentioning
      // patchable_static_calls_v2 does not advertise this flag.
      final cache = Directory(p.join(flutterDir.path, 'bin', 'cache'))
        ..createSync(recursive: true);
      File(p.join(cache.path, 'engine.stamp')).writeAsStringSync(cell);
      File(p.join(cache.path, 'engine-dart-sdk.stamp')).writeAsStringSync(cell);
      for (final mode in ['ios', 'ios-profile', 'ios-release']) {
        final dir = Directory(p.join(cache.path, 'artifacts', 'engine', mode))
          ..createSync(recursive: true);
        File(
          p.join(dir.path, 'gen_snapshot_arm64'),
        ).writeAsStringSync(' patchable_static_calls_v2 ');
      }
      final problems = coherence.check(
        flutterDirectory: flutterDir,
        engineRevision: cell,
      );
      expect(problems.map((e) => e.code).toSet(), {
        ToolchainIncoherence.genSnapshotNotPatchable,
      });
    });

    group('assertToolchainCoherent', () {
      late ShorebirdEnv shorebirdEnv;
      late ShorebirdLogger logger;
      late Platform platform;

      R runWithOverrides<R>(R Function() body) => runScoped(
        body,
        values: {
          loggerRef.overrideWith(() => logger),
          platformRef.overrideWith(() => platform),
          shorebirdEnvRef.overrideWith(() => shorebirdEnv),
          toolchainCoherenceRef.overrideWith(() => coherence),
        },
      );

      setUp(() {
        shorebirdEnv = MockShorebirdEnv();
        logger = MockShorebirdLogger();
        platform = MockPlatform();
        when(() => platform.environment).thenReturn({});
        when(() => shorebirdEnv.flutterDirectory).thenReturn(flutterDir);
        when(() => shorebirdEnv.shorebirdEngineRevision).thenReturn(cell);
      });

      test('returns normally when coherent', () {
        makeCheckout();
        expect(() => runWithOverrides(coherence.assertCoherent), returnsNormally);
      });

      test(
        'REFUSES before publication when engine-dart-sdk.stamp is incoherent',
        () {
          // The mutation control for the producer gate: this is the state that
          // shipped a release which could not be patched, and it must now stop
          // the build instead of being discovered afterwards.
          makeCheckout(dartSdkStamp: stock);
          expect(
            () => runWithOverrides(coherence.assertCoherent),
            throwsA(isA<ProcessExit>()),
          );
          verify(
            () => logger.err(
              any(that: contains('not coherent with its engine revision')),
            ),
          ).called(1);
        },
      );

      test('refuses when a gen_snapshot is stock', () {
        makeCheckout(patchableGenSnapshot: false);
        expect(
          () => runWithOverrides(coherence.assertCoherent),
          throwsA(isA<ProcessExit>()),
        );
      });
    });
  });
}
