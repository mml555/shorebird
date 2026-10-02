import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/metadata/metadata.dart';
import 'package:test/test.dart';

void main() {
  group(BuildEnvironmentMetadata, () {
    test('can be (de)serialized', () {
      const metadata = BuildEnvironmentMetadata(
        flutterRevision: '853d13d954df3b6e9c2f07b72062f33c52a9a64b',
        operatingSystem: 'macos',
        operatingSystemVersion: '1.2.3',
        shorebirdVersion: '4.5.6',
        shorebirdYaml: ShorebirdYaml(appId: 'app-id'),
        usesShorebirdCodePushPackage: false,
        xcodeVersion: '15.0',
      );
      expect(
        BuildEnvironmentMetadata.fromJson(metadata.toJson()).toJson(),
        equals(metadata.toJson()),
      );
    });

    test('round-trips engineRevision, and omits it when absent', () {
      // The control plane could not previously say WHICH engine produced a
      // release: flutterRevision does not answer it, because two Route B cells
      // can share one Flutter revision and differ in capability. Verified on a
      // real release — 88, Wonderous — whose server record carried
      // flutter_revision and no engine field, while the shipped route_b.json
      // recorded engineRevision 40eaa0ef.
      const withEngine = BuildEnvironmentMetadata(
        flutterRevision: '853d13d954df3b6e9c2f07b72062f33c52a9a64b',
        operatingSystem: 'macos',
        operatingSystemVersion: '1.2.3',
        shorebirdVersion: '4.5.6',
        shorebirdYaml: ShorebirdYaml(appId: 'app-id'),
        usesShorebirdCodePushPackage: false,
        engineRevision: '40eaa0ef6cb6485833bf2e10ac97224ca82cbf25',
      );
      expect(
        withEngine.toJson()['engine_revision'],
        equals('40eaa0ef6cb6485833bf2e10ac97224ca82cbf25'),
      );
      expect(
        BuildEnvironmentMetadata.fromJson(withEngine.toJson()).engineRevision,
        equals('40eaa0ef6cb6485833bf2e10ac97224ca82cbf25'),
      );

      // Nullable on purpose: records written before this field existed must
      // still deserialize.
      const withoutEngine = BuildEnvironmentMetadata(
        flutterRevision: '853d13d954df3b6e9c2f07b72062f33c52a9a64b',
        operatingSystem: 'macos',
        operatingSystemVersion: '1.2.3',
        shorebirdVersion: '4.5.6',
        shorebirdYaml: ShorebirdYaml(appId: 'app-id'),
        usesShorebirdCodePushPackage: false,
      );
      expect(withoutEngine.engineRevision, isNull);
      expect(
        BuildEnvironmentMetadata.fromJson(
          withoutEngine.toJson(),
        ).engineRevision,
        isNull,
      );

      // And it must participate in equality, or two records naming different
      // engines would compare equal.
      expect(withEngine, isNot(equals(withoutEngine)));
    });

    group('copyWith', () {
      test('creates a copy with the same fields', () {
        const metadata = BuildEnvironmentMetadata(
          flutterRevision: '853d13d954df3b6e9c2f07b72062f33c52a9a64b',
          operatingSystem: 'macos',
          operatingSystemVersion: '1.2.3',
          shorebirdVersion: '4.5.6',
          shorebirdYaml: ShorebirdYaml(appId: 'app-id'),
          usesShorebirdCodePushPackage: false,
          xcodeVersion: '15.0',
        );

        expect(metadata.copyWith(), equals(metadata));
      });

      test('returns a new instance with the given fields replaced', () {
        const metadata = BuildEnvironmentMetadata(
          flutterRevision: '853d13d954df3b6e9c2f07b72062f33c52a9a64b',
          operatingSystem: 'macos',
          operatingSystemVersion: '1.2.3',
          shorebirdVersion: '4.5.6',
          shorebirdYaml: ShorebirdYaml(appId: 'app-id'),
          usesShorebirdCodePushPackage: false,
          xcodeVersion: '15.0',
        );
        final newMetadata = metadata.copyWith(
          flutterRevision: 'asdf',
          operatingSystem: 'windows',
          operatingSystemVersion: '11',
          shorebirdVersion: '1.2.3',
          shorebirdYaml: const ShorebirdYaml(appId: 'app-id2'),
          usesShorebirdCodePushPackage: true,
          xcodeVersion: '14.0',
        );
        expect(
          newMetadata,
          equals(
            const BuildEnvironmentMetadata(
              flutterRevision: 'asdf',
              operatingSystem: 'windows',
              operatingSystemVersion: '11',
              shorebirdVersion: '1.2.3',
              shorebirdYaml: ShorebirdYaml(appId: 'app-id2'),
              usesShorebirdCodePushPackage: true,
              xcodeVersion: '14.0',
            ),
          ),
        );
      });
    });

    group('equatable', () {
      test('two metadatas with the same properties are equal', () {
        const metadata = BuildEnvironmentMetadata(
          flutterRevision: '853d13d954df3b6e9c2f07b72062f33c52a9a64b',
          operatingSystem: 'macos',
          operatingSystemVersion: '1.2.3',
          shorebirdVersion: '4.5.6',
          shorebirdYaml: ShorebirdYaml(appId: 'app-id'),
          usesShorebirdCodePushPackage: true,
          xcodeVersion: '15.0',
        );
        const otherMetadata = BuildEnvironmentMetadata(
          flutterRevision: '853d13d954df3b6e9c2f07b72062f33c52a9a64b',
          operatingSystem: 'macos',
          operatingSystemVersion: '1.2.3',
          shorebirdVersion: '4.5.6',
          shorebirdYaml: ShorebirdYaml(appId: 'app-id'),
          usesShorebirdCodePushPackage: true,
          xcodeVersion: '15.0',
        );
        expect(metadata, equals(otherMetadata));
      });

      test('two metadatas with different properties are not equal', () {
        const metadata = BuildEnvironmentMetadata(
          flutterRevision: '853d13d954df3b6e9c2f07b72062f33c52a9a64b',
          operatingSystem: 'macos',
          operatingSystemVersion: '1.2.3',
          shorebirdVersion: '4.5.6',
          shorebirdYaml: ShorebirdYaml(appId: 'app-id'),
          usesShorebirdCodePushPackage: true,
          xcodeVersion: '15.0',
        );
        const otherMetadata = BuildEnvironmentMetadata(
          flutterRevision: '853d13d954df3b6e9c2f07b72062f33c52a9a64b',
          operatingSystem: 'macos',
          operatingSystemVersion: '1.2.3',
          shorebirdVersion: '4.5.6',
          shorebirdYaml: ShorebirdYaml(appId: 'app-id2'),
          usesShorebirdCodePushPackage: true,
          xcodeVersion: '15.1',
        );
        expect(metadata, isNot(equals(otherMetadata)));
      });
    });
  });
}
