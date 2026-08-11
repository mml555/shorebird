import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/route_b_provenance.dart';
import 'package:test/test.dart';

void main() {
  group('route_b provenance', () {
    late Directory supplement;

    setUp(() {
      supplement = Directory.systemTemp.createTempSync('supplement');
    });

    group('round trip', () {
      test('survives write then read', () {
        const provenance = RouteBReleaseProvenance(
          engineRevision: 'engine-abc',
          flutterRevision: 'flutter-def',
          patchableCallSites: 7109,
          patchableCallSitesPerMiB: 1788.5,
        );

        writeRouteBReleaseProvenance(supplement, provenance);
        final read = readRouteBReleaseProvenance(supplement)!;

        expect(read.engineRevision, 'engine-abc');
        expect(read.flutterRevision, 'flutter-def');
        expect(read.patchableCallSites, 7109);
        expect(read.patchableCallSitesPerMiB, 1788.5);
      });

      test('creates the supplement directory if it is missing', () {
        final missing = Directory(p.join(supplement.path, 'nested'));

        final file = writeRouteBReleaseProvenance(
          missing,
          const RouteBReleaseProvenance(
            engineRevision: 'engine-abc',
            flutterRevision: 'flutter-def',
            patchableCallSites: 1,
            patchableCallSitesPerMiB: 1,
          ),
        );

        expect(file.existsSync(), isTrue);
      });
    });

    group('artifacts', () {
      RouteBReleaseProvenance record(Map<String, String> artifacts) =>
          RouteBReleaseProvenance(
            engineRevision: 'engine-abc',
            flutterRevision: 'flutter-def',
            patchableCallSites: 1,
            patchableCallSitesPerMiB: 1,
            artifacts: artifacts,
          );

      test('round-trips through the sidecar', () {
        writeRouteBReleaseProvenance(
          supplement,
          record({routeBReleaseKernelFileName: 'a' * 64}),
        );

        expect(
          readRouteBReleaseProvenance(supplement)!.artifacts,
          {routeBReleaseKernelFileName: 'a' * 64},
        );
      });

      test('throws when an artifact has no hash', () {
        File(
          p.join(supplement.path, routeBProvenanceFileName),
        ).writeAsStringSync(
          '{"engineRevision":"e","flutterRevision":"f",'
          '"artifacts":{"release_app.dill":null}}',
        );

        expect(
          () => readRouteBReleaseProvenance(supplement),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('no hash for release_app.dill'),
            ),
          ),
        );
      });

      test('captures a kernel and verifies it back', () {
        final built = File(p.join(supplement.path, 'source.dill'))
          ..writeAsStringSync('KERNEL');
        final hash = captureRouteBReleaseKernel(supplement, built);

        final resolved = verifyRouteBReleaseArtifacts(
          supplement,
          record({routeBReleaseKernelFileName: hash}),
        );

        expect(
          resolved[routeBReleaseKernelFileName]!.readAsStringSync(),
          'KERNEL',
        );
      });

      test('throws when a recorded artifact was never uploaded', () {
        // The supplement is a second network call after the primary artifact,
        // so "recorded" and "uploaded" are genuinely different claims.
        expect(
          () => verifyRouteBReleaseArtifacts(
            supplement,
            record({routeBReleaseKernelFileName: 'a' * 64}),
          ),
          throwsA(
            isA<RouteBReleaseArtifactException>().having(
              (e) => e.message,
              'message',
              contains('did not upload it'),
            ),
          ),
        );
      });

      test('throws when the uploaded bytes are not the recorded ones', () {
        final built = File(p.join(supplement.path, 'source.dill'))
          ..writeAsStringSync('KERNEL');
        captureRouteBReleaseKernel(supplement, built);

        expect(
          () => verifyRouteBReleaseArtifacts(
            supplement,
            record({routeBReleaseKernelFileName: 'a' * 64}),
          ),
          throwsA(
            isA<RouteBReleaseArtifactException>().having(
              (e) => e.message,
              'message',
              contains('does not match the hash the release recorded'),
            ),
          ),
        );
      });
    });

    group('hasRouteBReleaseProvenance', () {
      test('is false when the release carries none', () {
        expect(hasRouteBReleaseProvenance(supplement), isFalse);
      });

      test('is true even when the sidecar is malformed', () {
        // A release whose provenance is corrupt is still a Route B release and
        // needs the Route B diagnosis, not a silent fall through to the
        // private AOT linker.
        File(
          p.join(supplement.path, routeBProvenanceFileName),
        ).writeAsStringSync('{not json');

        expect(hasRouteBReleaseProvenance(supplement), isTrue);
      });
    });

    group('readRouteBReleaseProvenance', () {
      test('is null when the release carries none', () {
        // Distinct from a parse failure: "no provenance" means the release
        // predates the record, which is a different remediation.
        expect(readRouteBReleaseProvenance(supplement), isNull);
      });

      void writeSidecar(String contents) => File(
        p.join(supplement.path, routeBProvenanceFileName),
      ).writeAsStringSync(contents);

      test('throws on invalid JSON', () {
        writeSidecar('{not json');
        expect(
          () => readRouteBReleaseProvenance(supplement),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws when the payload is not an object', () {
        writeSidecar('[]');
        expect(
          () => readRouteBReleaseProvenance(supplement),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('not a JSON object'),
            ),
          ),
        );
      });

      test('throws when the engine revision is missing', () {
        // The one field the whole record exists to carry. Defaulting it would
        // hand the resolver an empty hash and produce a confusing 404 instead
        // of naming the release as the thing to fix.
        writeSidecar('{"flutterRevision": "flutter-def"}');
        expect(
          () => readRouteBReleaseProvenance(supplement),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('no engineRevision'),
            ),
          ),
        );
      });

      test('throws when the engine revision is empty', () {
        writeSidecar('{"engineRevision": "", "flutterRevision": "f"}');
        expect(
          () => readRouteBReleaseProvenance(supplement),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('no engineRevision'),
            ),
          ),
        );
      });

      test('throws when the flutter revision is missing', () {
        writeSidecar('{"engineRevision": "engine-abc"}');
        expect(
          () => readRouteBReleaseProvenance(supplement),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('no flutterRevision'),
            ),
          ),
        );
      });

      test('tolerates missing call-site counts', () {
        // Evidence, not a gate — the patch side re-counts from the shipped
        // bytes, so their absence must not make a release unpatchable.
        writeSidecar('{"engineRevision": "e", "flutterRevision": "f"}');

        final read = readRouteBReleaseProvenance(supplement)!;

        expect(read.patchableCallSites, 0);
        expect(read.patchableCallSitesPerMiB, 0);
      });
    });
  });
}
