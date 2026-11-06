// FLUTTER-STORAGE-AUTHORITY-1.
//
// `ArtifactOrigin` is the single authority for where artifact bytes come from.
// These tests exist for two distinct jobs: pin the resolution rules, and stop a
// FUTURE download path from quietly escaping the authority — which is the
// failure mode that made this lane necessary in the first place. Before it, the
// origins were assigned in four places under two differently-named variables.
import 'dart:io' as io;

import 'package:path/path.dart' as p;
import 'package:platform/testing.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/artifact_origin.dart';
import 'package:shorebird_cli/src/cache.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';
import 'package:test/test.dart';
import 'helpers.dart';

void main() {
  useTempWorkingDirectory();
  group(ArtifactOrigin, () {
    late NativePlatform platform;

    R runWithEnv<R>(Map<String, String> env, R Function() body) {
      // `Cache`'s constructor reads the OS to pick its artifact set; unrelated
      // to the origin, but it has to answer for the consumer test below.
      platform = TestNativePlatform(
        environment: env,
        operatingSystem: NativePlatform.macOS,
      );
      return runScoped(
        body,
        values: {
          platformRef.overrideWith(() => platform),
          shorebirdEnvRef.overrideWith(ShorebirdEnv.new),
        },
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

      test('an absolute flutter path still gets the origin', () {
        // THE BUG THIS LANE ACTUALLY FOUND. `ShorebirdFlutter._precache` — the
        // one call that downloads engine artifacts — invokes the target
        // revision's ABSOLUTE binary path with `useVendedFlutter: false`, so
        // the old `executable == 'flutter'` test never matched and the origin
        // was never injected. It only looked fine when the operator had set
        // FLUTTER_STORAGE_BASE_URL in their own shell, which the child
        // inherits regardless.
        runWithEnv(const {'SHOREBIRD_ARTIFACT_ORIGIN': 'http://cdn.test'}, () {
          final process = ShorebirdProcess();
          final env = process.testEnvironmentOverrides(
            executable: '/some/where/bin/cache/flutter/abc123/bin/flutter',
            useVendedFlutter: false,
          );
          expect(env, {'FLUTTER_STORAGE_BASE_URL': 'http://cdn.test'});
        });
      });

      test('with nothing configured, useVendedFlutter:false stays empty', () {
        // Upstream behaviour, unchanged. This is the half that keeps the
        // default identical rather than merely similar.
        runWithEnv(const {}, () {
          final process = ShorebirdProcess();
          expect(
            process.testEnvironmentOverrides(
              executable: '/abs/path/bin/flutter',
              useVendedFlutter: false,
            ),
            isEmpty,
          );
        });
      });

      test('a non-flutter executable never gets the origin', () {
        runWithEnv(const {'SHOREBIRD_ARTIFACT_ORIGIN': 'http://cdn.test'}, () {
          final process = ShorebirdProcess();
          expect(
            process.testEnvironmentOverrides(
              executable: '/usr/bin/git',
              useVendedFlutter: true,
            ),
            isEmpty,
          );
        });
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
        'lib/src/shorebird_env.dart':
            'the upstream default constant `defaultDownloadUrl`, the value '
            'ArtifactOrigin falls back to; ShorebirdEnv.downloadUrl resolves '
            'through ArtifactOrigin.',
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
        for (final entity in io.Directory(
          packagePath('lib'),
        ).listSync(recursive: true)) {
          if (entity is! io.File || !entity.path.endsWith('.dart')) continue;
          final relative = p
              .relative(entity.path, from: packagePath(''))
              .replaceAll(r'\', '/');
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
          final file = io.File(packagePath(path));
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

      test('the shell bootstrap resolves the same authority, and warns the '
          'same way', () {
        // `third_party/flutter/bin/internal/shared.sh` runs BEFORE any Dart
        // exists — it is the download that produces the Dart SDK — so it
        // duplicates the resolution in shell. Duplication is only safe if it
        // is pinned: run the real function over a matrix and compare it to
        // ArtifactOrigin, URL and warning both.
        final shared = packagePath(
          '../../third_party/flutter/bin/internal/shared.sh',
        );
        expect(io.File(shared).existsSync(), isTrue);
        const dl = ArtifactOrigin.downloadUrlKey;
        const fl = ArtifactOrigin.flutterStorageKey;
        const or = ArtifactOrigin.originKey;
        for (final env in <Map<String, String>>[
          {},
          {dl: 'https://a.example/'},
          {fl: 'https://b.example'},
          {or: 'https://c.example//'},
          {dl: '', fl: '  ', or: ''},
          {fl: '  https://b.example/  '},
          {dl: 'https://a.example', fl: 'https://a.example/'},
          {dl: 'https://a.example', fl: 'https://b.example'},
          {fl: 'https://b.example', or: 'https://c.example'},
          {dl: 'https://a.example', fl: 'https://b.example', or: 'https://c'},
          {
            fl: 'https://b.example',
            or: 'https://c.example',
            ArtifactOrigin.shorebirdBucketKey: 'bkt',
          },
        ]) {
          final result = io.Process.runSync(
            'bash',
            [
              '-c',
              // `set -u`: the Flutter wrapper scripts may run under `set -u`, and
              // most of the variables read here are unset in most matrix rows.
              'set -u; source "\$1"; resolve_download_url',
              'bash',
              shared,
            ],
            environment: {
              'PATH': io.Platform.environment['PATH']!,
              ...env,
            },
            includeParentEnvironment: false,
          );
          expect(result.exitCode, 0, reason: '$env ${result.stderr}');
          runWithEnv(env, () {
            expect(
              result.stdout,
              ArtifactOrigin.flutterStorageBaseUrl(),
              reason: '$env',
            );
            final warning = ArtifactOrigin.conflictWarning();
            expect(
              (result.stderr as String).trim(),
              warning ?? '',
              reason: '$env',
            );
          });
        }
      });

      group('conflictWarning', () {
        test('is null when nothing, one, or agreeing variables are set', () {
          for (final env in <Map<String, String>>[
            {},
            {ArtifactOrigin.originKey: 'https://c.example'},
            {
              ArtifactOrigin.downloadUrlKey: 'https://a.example/',
              ArtifactOrigin.flutterStorageKey: 'https://a.example',
            },
          ]) {
            runWithEnv(
              env,
              () => expect(ArtifactOrigin.conflictWarning(), isNull),
            );
          }
        });

        test('names the winner and the upstream layout', () {
          runWithEnv(
            {
              ArtifactOrigin.downloadUrlKey: 'https://a.example',
              ArtifactOrigin.flutterStorageKey: 'https://b.example',
            },
            () {
              final warning = ArtifactOrigin.conflictWarning()!;
              expect(
                warning,
                contains('SHOREBIRD_DOWNLOAD_URL=https://a.example wins'),
              );
              expect(
                warning,
                contains(
                  'upstream layout: https://a.example/shorebird/<engine>/',
                ),
              );
              expect(
                warning,
                contains('Ignored: FLUTTER_STORAGE_BASE_URL=https://b.example'),
              );
            },
          );
        });

        test('names the winner and the fork layout', () {
          runWithEnv(
            {
              ArtifactOrigin.flutterStorageKey: 'https://b.example',
              ArtifactOrigin.originKey: 'https://c.example',
            },
            () {
              final warning = ArtifactOrigin.conflictWarning()!;
              expect(
                warning,
                contains('FLUTTER_STORAGE_BASE_URL=https://b.example wins'),
              );
              expect(
                warning,
                contains(
                  'fork layout: https://c.example/download.shorebird.dev/shorebird/<engine>/',
                ),
              );
            },
          );
        });
      });
    });
  });
}
