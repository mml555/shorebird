import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/metadata/metadata.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';
import 'package:test/test.dart';

void main() {
  const environment = BuildEnvironmentMetadata(
    flutterRevision: '853d13d954df3b6e9c2f07b72062f33c52a9a64b',
    operatingSystem: 'macos',
    operatingSystemVersion: '1.2.3',
    shorebirdVersion: '4.5.6',
    shorebirdYaml: ShorebirdYaml(appId: 'app-id'),
    usesShorebirdCodePushPackage: false,
    xcodeVersion: '15.0',
  );

  group(CreatePatchPlatformMetadata, () {
    test('can be (de)serialized', () {
      const metadata = CreatePatchPlatformMetadata(
        hasAssetChanges: true,
        hasNativeChanges: false,
        linkPercentage: 99.9,
        linkMetadata: {'link': 'metadata'},
        buildTraceSummary: {'total_ms': 1234},
      );
      expect(
        CreatePatchPlatformMetadata.fromJson(metadata.toJson()).toJson(),
        equals(metadata.toJson()),
      );
    });

    group('copyWith', () {
      test('creates a copy with the same fields', () {
        const metadata = CreatePatchPlatformMetadata(
          hasAssetChanges: true,
          hasNativeChanges: false,
          linkPercentage: 99.9,
        );

        expect(metadata.copyWith(), equals(metadata));
      });

      test('creates a copy with the given fields replaced', () {
        const metadata = CreatePatchPlatformMetadata(
          hasAssetChanges: false,
          hasNativeChanges: false,
          linkPercentage: 99.9,
        );

        expect(
          metadata.copyWith(hasNativeChanges: true, linkPercentage: 99.8),
          equals(
            const CreatePatchPlatformMetadata(
              hasAssetChanges: false,
              hasNativeChanges: true,
              linkPercentage: 99.8,
            ),
          ),
        );
      });
    });
  });

  group(CreatePatchMetadata, () {
    const androidMetadata = CreatePatchPlatformMetadata(
      hasAssetChanges: false,
      hasNativeChanges: false,
    );
    const iosMetadata = CreatePatchPlatformMetadata(
      hasAssetChanges: false,
      hasNativeChanges: false,
      linkPercentage: 99.9,
    );

    test('can be (de)serialized', () {
      const metadata = CreatePatchMetadata(
        platforms: {
          ReleasePlatform.android: androidMetadata,
          ReleasePlatform.ios: iosMetadata,
        },
        usedIgnoreAssetChangesFlag: false,
        usedIgnoreNativeChangesFlag: false,
        inferredReleaseVersion: false,
        isSigned: false,
        environment: environment,
      );
      expect(
        CreatePatchMetadata.fromJson(metadata.toJson()).toJson(),
        equals(metadata.toJson()),
      );
    });

    test('keys serialized platforms by their wire value', () {
      const metadata = CreatePatchMetadata(
        platforms: {
          ReleasePlatform.android: androidMetadata,
          ReleasePlatform.ios: iosMetadata,
        },
        usedIgnoreAssetChangesFlag: false,
        usedIgnoreNativeChangesFlag: false,
        inferredReleaseVersion: false,
        isSigned: false,
        environment: environment,
      );

      expect(
        (metadata.toJson()['platforms']! as Map).keys,
        containsAll(<String>['android', 'ios']),
      );
    });

    test('round-trips a patch covering a single platform', () {
      const metadata = CreatePatchMetadata(
        platforms: {ReleasePlatform.android: androidMetadata},
        usedIgnoreAssetChangesFlag: true,
        usedIgnoreNativeChangesFlag: true,
        inferredReleaseVersion: true,
        isSigned: true,
        environment: environment,
      );

      // Compared as JSON rather than as objects: ShorebirdYaml has no ==, so
      // a deserialized BuildEnvironmentMetadata never equals the original.
      expect(
        CreatePatchMetadata.fromJson(metadata.toJson()).toJson(),
        equals(metadata.toJson()),
      );
    });

    group('copyWith', () {
      const metadata = CreatePatchMetadata(
        platforms: {ReleasePlatform.android: androidMetadata},
        usedIgnoreAssetChangesFlag: false,
        usedIgnoreNativeChangesFlag: false,
        inferredReleaseVersion: false,
        isSigned: false,
        environment: environment,
      );

      test('creates a copy with the same fields', () {
        expect(metadata.copyWith(), equals(metadata));
      });

      test('creates a copy with the given fields replaced', () {
        final newMetadata = metadata.copyWith(
          platforms: {ReleasePlatform.ios: iosMetadata},
          usedIgnoreAssetChangesFlag: true,
          usedIgnoreNativeChangesFlag: true,
          isSigned: true,
        );

        expect(
          newMetadata,
          equals(
            const CreatePatchMetadata(
              platforms: {ReleasePlatform.ios: iosMetadata},
              usedIgnoreAssetChangesFlag: true,
              usedIgnoreNativeChangesFlag: true,
              inferredReleaseVersion: false,
              isSigned: true,
              environment: environment,
            ),
          ),
        );
      });
    });

    group('withPlatform', () {
      test('adds a platform without disturbing the others', () {
        const metadata = CreatePatchMetadata(
          platforms: {ReleasePlatform.android: androidMetadata},
          usedIgnoreAssetChangesFlag: false,
          usedIgnoreNativeChangesFlag: false,
          inferredReleaseVersion: false,
          isSigned: false,
          environment: environment,
        );

        expect(
          metadata.withPlatform(ReleasePlatform.ios, iosMetadata).platforms,
          equals({
            ReleasePlatform.android: androidMetadata,
            ReleasePlatform.ios: iosMetadata,
          }),
        );
      });

      test('replaces an existing platform', () {
        const metadata = CreatePatchMetadata(
          platforms: {ReleasePlatform.ios: androidMetadata},
          usedIgnoreAssetChangesFlag: false,
          usedIgnoreNativeChangesFlag: false,
          inferredReleaseVersion: false,
          isSigned: false,
          environment: environment,
        );

        expect(
          metadata.withPlatform(ReleasePlatform.ios, iosMetadata).platforms,
          equals({ReleasePlatform.ios: iosMetadata}),
        );
      });
    });

    group('equatable', () {
      test('two metadatas with the same properties are equal', () {
        const metadata = CreatePatchMetadata(
          platforms: {ReleasePlatform.android: androidMetadata},
          usedIgnoreAssetChangesFlag: false,
          usedIgnoreNativeChangesFlag: false,
          inferredReleaseVersion: false,
          isSigned: true,
          environment: environment,
        );
        const otherMetadata = CreatePatchMetadata(
          platforms: {ReleasePlatform.android: androidMetadata},
          usedIgnoreAssetChangesFlag: false,
          usedIgnoreNativeChangesFlag: false,
          inferredReleaseVersion: false,
          isSigned: true,
          environment: environment,
        );
        expect(metadata, equals(otherMetadata));
      });

      test('metadatas covering different platforms are not equal', () {
        const metadata = CreatePatchMetadata(
          platforms: {ReleasePlatform.android: androidMetadata},
          usedIgnoreAssetChangesFlag: false,
          usedIgnoreNativeChangesFlag: false,
          inferredReleaseVersion: false,
          isSigned: true,
          environment: environment,
        );
        const otherMetadata = CreatePatchMetadata(
          platforms: {
            ReleasePlatform.android: androidMetadata,
            ReleasePlatform.ios: iosMetadata,
          },
          usedIgnoreAssetChangesFlag: false,
          usedIgnoreNativeChangesFlag: false,
          inferredReleaseVersion: false,
          isSigned: true,
          environment: environment,
        );
        expect(metadata, isNot(equals(otherMetadata)));
      });
    });
  });
}
