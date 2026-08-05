import 'package:mocktail/mocktail.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/dd_support.dart';
import 'package:shorebird_cli/src/shorebird_artifacts.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';
import 'package:test/test.dart';

import 'mocks.dart';

void main() {
  group(DdSupport, () {
    const genSnapshotPath = '/path/to/gen_snapshot_arm64';
    late ShorebirdArtifacts shorebirdArtifacts;
    late ShorebirdProcess process;
    late DdSupport ddSupport;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        () => body(),
        values: {
          shorebirdArtifactsRef.overrideWith(() => shorebirdArtifacts),
          processRef.overrideWith(() => process),
        },
      );
    }

    void stubExitCode(int exitCode) {
      when(
        () => process.runSync(any(), any()),
      ).thenReturn(
        ShorebirdProcessResult(exitCode: exitCode, stdout: '', stderr: ''),
      );
    }

    setUpAll(() {
      registerFallbackValue(ShorebirdArtifact.genSnapshotIos);
    });

    setUp(() {
      shorebirdArtifacts = MockShorebirdArtifacts();
      process = MockShorebirdProcess();
      ddSupport = DdSupport();
      when(
        () => shorebirdArtifacts.getArtifactPath(
          artifact: any(named: 'artifact'),
        ),
      ).thenReturn(genSnapshotPath);
    });

    group('isSupportedBy', () {
      test('returns true when gen_snapshot accepts the DD flag', () {
        stubExitCode(0);
        expect(
          runWithOverrides(
            () => ddSupport.isSupportedBy(ShorebirdArtifact.genSnapshotIos),
          ),
          isTrue,
        );
      });

      test('returns false when gen_snapshot rejects the DD flag', () {
        // A vanilla-Dart gen_snapshot exits 255 with
        // "Unrecognized flags: print_dd_function_identity_to".
        stubExitCode(255);
        expect(
          runWithOverrides(
            () => ddSupport.isSupportedBy(ShorebirdArtifact.genSnapshotIos),
          ),
          isFalse,
        );
      });

      test('probes with --version so nothing is compiled or written', () {
        stubExitCode(0);
        runWithOverrides(
          () => ddSupport.isSupportedBy(ShorebirdArtifact.genSnapshotIos),
        );
        final captured = verify(
          () => process.runSync(captureAny(), captureAny()),
        ).captured;
        expect(captured.first, equals(genSnapshotPath));
        expect(
          captured.last,
          equals(const [
            '--print_dd_function_identity_to=/dev/null',
            '--version',
          ]),
        );
      });

      test('caches the answer per artifact', () {
        stubExitCode(0);
        runWithOverrides(() {
          ddSupport
            ..isSupportedBy(ShorebirdArtifact.genSnapshotIos)
            ..isSupportedBy(ShorebirdArtifact.genSnapshotIos);
        });
        verify(() => process.runSync(any(), any())).called(1);
      });

      test('assumes supported when the artifact path cannot be resolved', () {
        when(
          () => shorebirdArtifacts.getArtifactPath(
            artifact: any(named: 'artifact'),
          ),
        ).thenThrow(Exception('missing'));
        expect(
          runWithOverrides(
            () => ddSupport.isSupportedBy(ShorebirdArtifact.genSnapshotIos),
          ),
          isTrue,
        );
        verifyNever(() => process.runSync(any(), any()));
      });

      test('assumes supported when the probe itself throws', () {
        when(
          () => process.runSync(any(), any()),
        ).thenThrow(Exception('cannot spawn'));
        expect(
          runWithOverrides(
            () => ddSupport.isSupportedBy(ShorebirdArtifact.genSnapshotIos),
          ),
          isTrue,
        );
      });
    });
  });
}
