import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/flutter_injected_defines.dart';
import 'package:test/test.dart';

void main() {
  group(FlutterInjectedDefines, () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('injected');
    });

    /// Writes an xcconfig whose DART_DEFINES line is encoded the way Flutter
    /// encodes it: base64 `K=V`, comma separated (`build_info.dart:396`).
    File writeXcconfig(Map<String, String> defines) {
      final encoded = defines.entries
          .map((e) => base64.encode(utf8.encode('${e.key}=${e.value}')))
          .join(',');
      return File(p.join(tempDir.path, 'Generated.xcconfig'))
        ..writeAsStringSync('''
// This is a generated file; do not edit or check into version control.
FLUTTER_ROOT=/does/not/matter
DART_DEFINES=$encoded
''');
    }

    group('selectFrom', () {
      test('picks exactly the keys Flutter injects', () {
        // The real set, measured on a clean `flutter create` app with no flavor
        // and no --dart-define: six defines the prepass never saw.
        final resolved = {
          'FLUTTER_VERSION': '3.44.8',
          'FLUTTER_CHANNEL': '[user-branch]',
          'FLUTTER_GIT_URL': 'unknown source',
          'FLUTTER_FRAMEWORK_REVISION': 'c15ef63794',
          'FLUTTER_ENGINE_REVISION': '11e5695710',
          'FLUTTER_DART_VERSION': '3.12.2',
        };

        expect(FlutterInjectedDefines.selectFrom(resolved), resolved);
      });

      test("leaves the user's own defines alone", () {
        // They already reach the kernel through `forwardedArgs`, from the
        // command line. Taking them from the xcconfig as well would give one
        // value two sources of truth.
        expect(
          FlutterInjectedDefines.selectFrom(const {
            'API_URL': 'https://example.com',
            'FLUTTER_VERSION': '3.44.8',
          }),
          const {'FLUTTER_VERSION': '3.44.8'},
        );
      });

      test('excludes FLUTTER_APP_FLAVOR, which has its own threading', () {
        // Deliberate, and measured: Flutter rewrites this define at the
        // xcodebuild stage from the Xcode CONFIGURATION, so the xcconfig holds
        // the CLI token (`foo`) while the shipped kernel holds the scheme's
        // casing (`Foo`). Reading it here would reintroduce the casing
        // divergence f06fa056 closed.
        expect(
          FlutterInjectedDefines.selectFrom(const {
            'FLUTTER_APP_FLAVOR': 'foo',
            'FLUTTER_VERSION': '3.44.8',
          }),
          const {'FLUTTER_VERSION': '3.44.8'},
        );
      });

      test('omits a key Flutter did not emit rather than defaulting it', () {
        // FLUTTER_ENABLED_FEATURE_FLAGS is absent from the build entirely when
        // no enabled feature has a runtimeId. `String.fromEnvironment`
        // distinguishes unset from empty, and a program may branch on the
        // difference, so inventing an empty value would be its own wrong
        // program.
        final selected = FlutterInjectedDefines.selectFrom(const {
          'FLUTTER_VERSION': '3.44.8',
        });

        expect(selected.containsKey('FLUTTER_ENABLED_FEATURE_FLAGS'), isFalse);
      });

      test('carries the feature flags when Flutter did emit them', () {
        expect(
          FlutterInjectedDefines.selectFrom(const {
            'FLUTTER_ENABLED_FEATURE_FLAGS': 'a,b',
          }),
          const {'FLUTTER_ENABLED_FEATURE_FLAGS': 'a,b'},
        );
      });
    });

    group('fromGeneratedXcconfig', () {
      test("reads Flutter's own answer for this build", () {
        final xcconfig = writeXcconfig(const {
          'FLUTTER_VERSION': '3.44.8',
          'FLUTTER_ENGINE_REVISION': '11e5695710',
          'API_URL': 'https://example.com',
        });

        expect(FlutterInjectedDefines.fromGeneratedXcconfig(xcconfig), const {
          'FLUTTER_VERSION': '3.44.8',
          'FLUTTER_ENGINE_REVISION': '11e5695710',
        });
      });

      test('returns null for a missing file rather than an empty map', () {
        // The distinction is the whole safety property. Null makes the caller
        // decline to produce kernels; an empty map would make it produce kernels
        // for the wrong program, silently -- which is the bug being closed.
        expect(
          FlutterInjectedDefines.fromGeneratedXcconfig(
            File(p.join(tempDir.path, 'absent.xcconfig')),
          ),
          isNull,
        );
      });

      test('returns null when the file carries no DART_DEFINES line', () {
        final xcconfig = File(p.join(tempDir.path, 'Generated.xcconfig'))
          ..writeAsStringSync('FLUTTER_ROOT=/does/not/matter\n');

        expect(FlutterInjectedDefines.fromGeneratedXcconfig(xcconfig), isNull);
      });

      test('an engine revision is read, never derived from Shorebird\'s', () {
        // The trap this seam exists for. FLUTTER_ENGINE_REVISION comes from the
        // engine's own engine_stamp.json (`version.dart:681`), which on the
        // pinned cell reads 11e5695710 while Shorebird's engine.version reads
        // 40eaa0ef6cb6485833bf2e10ac97224ca82cbf25. Anything that derived the
        // define from the latter would be plausibly, silently wrong.
        final xcconfig = writeXcconfig(const {
          'FLUTTER_ENGINE_REVISION': '11e5695710',
        });

        final injected = FlutterInjectedDefines.fromGeneratedXcconfig(xcconfig);

        expect(injected!['FLUTTER_ENGINE_REVISION'], '11e5695710');
        expect(
          injected['FLUTTER_ENGINE_REVISION'],
          isNot(startsWith('40eaa0ef')),
        );
      });
    });
  });
}
