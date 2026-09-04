// FLUTTER-STORAGE-AUTHORITY-1.
//
// `ArtifactOrigin` is the single authority for where artifact bytes come from.
// These tests exist for two distinct jobs: pin the resolution rules, and stop a
// FUTURE download path from quietly escaping the authority — which is the
// failure mode that made this lane necessary in the first place. Before it, the
// origins were assigned in four places under two differently-named variables.
import 'dart:io' as io;

import 'package:mocktail/mocktail.dart';
import 'package:platform/platform.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/artifact_origin.dart';
import 'package:shorebird_cli/src/cache.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:test/test.dart';

import 'mocks.dart';

void main() {
  group(ArtifactOrigin, () {
    late Platform platform;

    R runWithEnv<R>(Map<String, String> env, R Function() body) {
      platform = MockPlatform();
      when(() => platform.environment).thenReturn(env);
      // `Cache`'s constructor reads the OS to pick its artifact set; unrelated
      // to the origin, but it has to answer for the consumer test below.
      when(() => platform.isMacOS).thenReturn(true);
      when(() => platform.isWindows).thenReturn(false);
      when(() => platform.isLinux).thenReturn(false);
      when(() => platform.operatingSystem).thenReturn('macos');
      return runScoped(
        body,
        values: {platformRef.overrideWith(() => platform)},
      );
    }

    group('with nothing set — upstream behaviour is unchanged', () {
      test("resolves exactly upstream Shorebird's origins", () {
        runWithEnv(const {}, () {
          expect(
            ArtifactOrigin.flutterStorageBaseUrl(),
            'https://download.shorebird.dev',
          );
          expect(
            ArtifactOrigin.shorebirdStorageBaseUrl(),
            'https://storage.googleapis.com',
          );
          expect(
            ArtifactOrigin.shorebirdStorageBucket(),
            'download.shorebird.dev',
          );
          expect(ArtifactOrigin.isOverridden, isFalse);
        });
      });
    });

    group('the single authority', () {
      test('SHOREBIRD_ARTIFACT_ORIGIN moves BOTH halves', () {
        runWithEnv(const {'SHOREBIRD_ARTIFACT_ORIGIN': 'http://cdn.test'}, () {
          expect(ArtifactOrigin.flutterStorageBaseUrl(), 'http://cdn.test');
          expect(ArtifactOrigin.shorebirdStorageBaseUrl(), 'http://cdn.test');
          expect(ArtifactOrigin.isOverridden, isTrue);
        });
      });

      test('it leaves the BUCKET segment alone', () {
        // The self-host CDN mirrors upstream's `<bucket>/shorebird/<engine>/…`
        // path shape (its `@must_be_local` matcher begins `[^/]+/shorebird/`),
        // so only the base moves. Rewriting the bucket too would ask the mirror
        // for a path it does not serve.
        runWithEnv(const {'SHOREBIRD_ARTIFACT_ORIGIN': 'http://cdn.test'}, () {
          expect(
            ArtifactOrigin.shorebirdStorageBucket(),
            'download.shorebird.dev',
          );
        });
      });

      test('a specific variable beats it, per half', () {
        runWithEnv(
          const {
            'SHOREBIRD_ARTIFACT_ORIGIN': 'http://cdn.test',
            'FLUTTER_STORAGE_BASE_URL': 'http://flutter-only.test',
          },
          () {
            expect(
              ArtifactOrigin.flutterStorageBaseUrl(),
              'http://flutter-only.test',
            );
            expect(ArtifactOrigin.shorebirdStorageBaseUrl(), 'http://cdn.test');
          },
        );
        runWithEnv(
          const {
            'SHOREBIRD_ARTIFACT_ORIGIN': 'http://cdn.test',
            'SHOREBIRD_STORAGE_BASE_URL': 'http://shorebird-only.test',
          },
          () {
            expect(ArtifactOrigin.flutterStorageBaseUrl(), 'http://cdn.test');
            expect(
              ArtifactOrigin.shorebirdStorageBaseUrl(),
              'http://shorebird-only.test',
            );
          },
        );
      });

      test('a trailing slash is trimmed so joins never double up', () {
        runWithEnv(
          const {'SHOREBIRD_ARTIFACT_ORIGIN': 'http://cdn.test///'},
          () {
            expect(ArtifactOrigin.flutterStorageBaseUrl(), 'http://cdn.test');
          },
        );
      });

      test('an EMPTY value reads as absent, not as an empty origin', () {
        // `FLUTTER_STORAGE_BASE_URL=` in a profile or a CI job would otherwise
        // resolve to '' and every artifact URL would lose its host — a
        // configuration fault that looks like a network fault.
        runWithEnv(
          const {
            'FLUTTER_STORAGE_BASE_URL': '',
            'SHOREBIRD_ARTIFACT_ORIGIN': '   ',
            'SHOREBIRD_STORAGE_BUCKET': '',
          },
          () {
            expect(
              ArtifactOrigin.flutterStorageBaseUrl(),
              'https://download.shorebird.dev',
            );
            expect(
              ArtifactOrigin.shorebirdStorageBucket(),
              'download.shorebird.dev',
            );
            expect(ArtifactOrigin.isOverridden, isFalse);
          },
        );
      });
    });

    group('every consumer is subordinate to it', () {
      test("Cache's URL builders resolve through the authority", () {
        runWithEnv(const {'SHOREBIRD_ARTIFACT_ORIGIN': 'http://cdn.test'}, () {
          final cache = Cache();
          expect(cache.storageBaseUrl, 'http://cdn.test');
          expect(cache.storageBucket, 'download.shorebird.dev');
        });
      });

      test('the child-process environment carries the resolved value', () {
        // Flutter fetches engine artifacts ITSELF, so the value has to be
        // handed to the child. The variable NAME is Flutter's own, which is
        // what makes the handover work.
        expect(ArtifactOrigin.flutterStorageKey, 'FLUTTER_STORAGE_BASE_URL');
      });
    });

    group('no forgotten code path', () {
      // THE ENFORCEMENT CONTROL. A new download site that hard-codes an origin
      // would escape the authority silently, and nothing else in this suite
      // would notice. So the literals are banned outside the authority itself.
      const literals = ['download.shorebird.dev', 'storage.googleapis.com'];

      /// Files permitted to contain an origin literal, each with its reason.
      const allowed = <String, String>{
        'lib/src/artifact_origin.dart':
            'the authority itself — this is where the defaults live',
        'lib/src/route_b_compiler.dart':
            'a manifest MEMBER NAME, part of the preimage a cell address is '
            'computed over. Not a URL that is ever fetched; rewriting it would '
            'change cell addresses.',
        'lib/src/commands/release/aar_releaser.dart':
            'user-facing text: the maven URL we tell a developer to add to '
            'their own build.gradle, which is their file and not our fetch.',
      };

      test('origin literals appear only where they are allowed', () {
        final offenders = <String>[];
        for (final entity in io.Directory('lib').listSync(recursive: true)) {
          if (entity is! io.File || !entity.path.endsWith('.dart')) continue;
          final relative = entity.path.replaceAll(r'\', '/');
          if (allowed.containsKey(relative)) continue;
          final source = entity.readAsStringSync();
          for (final literal in literals) {
            if (source.contains(literal)) {
              offenders.add('$relative contains "$literal"');
            }
          }
        }
        expect(
          offenders,
          isEmpty,
          reason:
              'A hard-coded artifact origin escapes ArtifactOrigin, which is '
              'the single authority. Resolve it through ArtifactOrigin, or — '
              'if it genuinely is not a fetched URL — add the file to '
              '`allowed` above WITH the reason.',
        );
      });

      test('the allowlist is not stale', () {
        // An entry that no longer contains a literal is an invitation to keep
        // adding entries; it must be removed when the reason stops applying.
        for (final path in allowed.keys) {
          final file = io.File(path);
          expect(file.existsSync(), isTrue, reason: '$path no longer exists');
          expect(
            literals.any(file.readAsStringSync().contains),
            isTrue,
            reason:
                '$path no longer contains an origin literal — remove it '
                'from the allowlist rather than leaving a standing exemption',
          );
        }
      });

      test('the shell bootstrap resolves the same authority', () {
        // `third_party/flutter/bin/internal/shared.sh` runs BEFORE any Dart
        // exists — it is the download that produces the Dart SDK — so it
        // duplicates the resolution in shell. Duplication is only safe if it
        // is pinned, which is what this asserts.
        final shared = io.File(
          '../../third_party/flutter/bin/internal/shared.sh',
        );
        expect(shared.existsSync(), isTrue);
        final source = shared.readAsStringSync();
        expect(
          source,
          contains(
            r'FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-'
            r'${SHOREBIRD_ARTIFACT_ORIGIN:-'
            'https://download.shorebird.dev}}"',
          ),
          reason:
              'the bootstrap must resolve FLUTTER_STORAGE_BASE_URL, then '
              'SHOREBIRD_ARTIFACT_ORIGIN, then the upstream default — the same '
              'order and the same default as ArtifactOrigin',
        );
        expect(source, contains(ArtifactOrigin.originKey));
      });
    });
  });
}
