import 'package:checked_yaml/checked_yaml.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:test/test.dart';

void main() {
  group('ShorebirdYaml', () {
    test('can be deserialized without flavors', () {
      const yaml = '''
app_id: test_app_id
base_url: https://example.com
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, 'test_app_id');
      expect(shorebirdYaml.flavors, isNull);
      expect(shorebirdYaml.baseUrl, 'https://example.com');
    });

    group('channel', () {
      // The native updater has always read `channel:` from the bundled
      // shorebird.yaml; this model did not declare it and the generated parser
      // is disallowUnrecognizedKeys, so the documented key was rejected and
      // there was no supported config path onto a non-stable track.
      test('is accepted', () {
        const yaml = '''
app_id: test_app_id
channel: beta
''';
        final shorebirdYaml = checkedYamlDecode(
          yaml,
          (m) => ShorebirdYaml.fromJson(m!),
        );
        expect(shorebirdYaml.channel, 'beta');
      });

      test('accepts a custom track name, not just stable/beta/staging', () {
        // The server allows arbitrary track names and `shorebird patches
        // set-track` documents that; a config that only accepted the three
        // built-ins would be narrower than the control plane.
        const yaml = '''
app_id: test_app_id
channel: my_custom_track
''';
        final shorebirdYaml = checkedYamlDecode(
          yaml,
          (m) => ShorebirdYaml.fromJson(m!),
        );
        expect(shorebirdYaml.channel, 'my_custom_track');
      });

      test('is null when omitted, leaving the updater default of stable', () {
        const yaml = '''
app_id: test_app_id
''';
        final shorebirdYaml = checkedYamlDecode(
          yaml,
          (m) => ShorebirdYaml.fromJson(m!),
        );
        expect(shorebirdYaml.channel, isNull);
      });

      test('survives a toJson/fromJson round trip', () {
        const original = ShorebirdYaml(appId: 'test_app_id', channel: 'beta');
        final restored = ShorebirdYaml.fromJson(original.toJson());
        expect(restored.channel, 'beta');
        expect(restored.appId, 'test_app_id');
      });

      test('round trip preserves a null channel as null', () {
        const original = ShorebirdYaml(appId: 'test_app_id');
        final restored = ShorebirdYaml.fromJson(original.toJson());
        expect(restored.channel, isNull);
      });

      test('coexists with every other key', () {
        const yaml = '''
app_id: test_app_id
channel: beta
base_url: https://example.com
auto_update: false
patch_verification: install_only
flavors:
  development: dev_id
''';
        final shorebirdYaml = checkedYamlDecode(
          yaml,
          (m) => ShorebirdYaml.fromJson(m!),
        );
        expect(shorebirdYaml.channel, 'beta');
        expect(shorebirdYaml.baseUrl, 'https://example.com');
        expect(shorebirdYaml.autoUpdate, isFalse);
        expect(
          shorebirdYaml.patchVerification,
          PatchVerification.installOnly,
        );
        expect(shorebirdYaml.flavors, {'development': 'dev_id'});
      });

      test('an unrelated unknown key is STILL rejected', () {
        // The mutation that proves the previous tests are not passing because
        // the parser became permissive: adding `channel` must not have turned
        // disallowUnrecognizedKeys off.
        const yaml = '''
app_id: test_app_id
channel: beta
not_a_real_key: value
''';
        expect(
          () => checkedYamlDecode(yaml, (m) => ShorebirdYaml.fromJson(m!)),
          throwsA(isA<ParsedYamlException>()),
        );
      });
    });

    test('can be deserialized with flavors', () {
      const yaml = '''
app_id: test_app_id1
flavors:
  development: test_app_id1
  production: test_app_id2
base_url: https://example.com
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, equals('test_app_id1'));
      expect(shorebirdYaml.flavors, {
        'development': 'test_app_id1',
        'production': 'test_app_id2',
      });
      expect(shorebirdYaml.baseUrl, 'https://example.com');
    });

    test('can be deserialized without auto-update', () {
      const yaml = '''
app_id: test_app_id
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, 'test_app_id');
      expect(shorebirdYaml.flavors, isNull);
      expect(shorebirdYaml.baseUrl, isNull);
      expect(shorebirdYaml.autoUpdate, isNull);
    });

    test('can be deserialized with auto-update', () {
      const yaml = '''
app_id: test_app_id
auto_update: true
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, 'test_app_id');
      expect(shorebirdYaml.flavors, isNull);
      expect(shorebirdYaml.baseUrl, isNull);
      expect(shorebirdYaml.autoUpdate, isTrue);
    });

    test('can be deserialized without patch_verification', () {
      const yaml = '''
app_id: test_app_id
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, 'test_app_id');
      expect(shorebirdYaml.patchVerification, isNull);
    });

    test('can be deserialized with patch_verification: strict', () {
      const yaml = '''
app_id: test_app_id
patch_verification: strict
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, 'test_app_id');
      expect(shorebirdYaml.patchVerification, PatchVerification.strict);
    });

    test('can be deserialized with patch_verification: install_only', () {
      const yaml = '''
app_id: test_app_id
patch_verification: install_only
''';
      final shorebirdYaml = checkedYamlDecode(
        yaml,
        (m) => ShorebirdYaml.fromJson(m!),
      );
      expect(shorebirdYaml.appId, 'test_app_id');
      expect(shorebirdYaml.patchVerification, PatchVerification.installOnly);
    });

    test('throws when patch_verification has invalid value', () {
      const yaml = '''
app_id: test_app_id
patch_verification: invalid_value
''';
      expect(
        () => checkedYamlDecode(yaml, (m) => ShorebirdYaml.fromJson(m!)),
        throwsA(
          isA<ParsedYamlException>().having(
            (e) => e.message,
            'message',
            contains('patch_verification'),
          ),
        ),
      );
    });

    group('AppIdExtension', () {
      test('getAppId returns base app id when no flavor is provided', () {
        const shorebirdYaml = ShorebirdYaml(appId: 'test_app_id');
        expect(shorebirdYaml.getAppId(), 'test_app_id');
      });

      test('getAppId returns base app id when flavor is not found', () {
        const shorebirdYaml = ShorebirdYaml(
          appId: 'test_app_id',
          flavors: {
            'development': 'test_app_id1',
            'production': 'test_app_id2',
          },
        );
        expect(shorebirdYaml.getAppId(flavor: 'staging'), 'test_app_id');
      });

      test('getAppId returns app id for flavor', () {
        const shorebirdYaml = ShorebirdYaml(
          appId: 'test_app_id',
          flavors: {
            'development': 'test_app_id1',
            'production': 'test_app_id2',
          },
        );
        expect(shorebirdYaml.getAppId(flavor: 'development'), 'test_app_id1');
        expect(shorebirdYaml.getAppId(flavor: 'production'), 'test_app_id2');
      });
    });
  });
}
