import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/executables/executables.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';
import 'package:test/test.dart';

import '../mocks.dart';

void main() {
  group(XcodeBuild, () {
    late ShorebirdProcess process;
    late XcodeBuild xcodeBuild;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(body, values: {processRef.overrideWith(() => process)});
    }

    setUp(() {
      process = MockShorebirdProcess();
      xcodeBuild = runWithOverrides(XcodeBuild.new);
    });

    group('flavorScheme', () {
      const projectPath = '/app/ios/Runner.xcodeproj';
      const args = ['-list', '-json', '-project', projectPath];

      void stubList(String stdout, {int exitCode = 0}) {
        when(() => process.run('xcodebuild', args)).thenAnswer(
          (_) async => ShorebirdProcessResult(
            exitCode: exitCode,
            stdout: stdout,
            stderr: '',
          ),
        );
      }

      // The behaviour under test, and the whole reason this method exists:
      // Flutter ships FLUTTER_APP_FLAVOR spelled as the SCHEME, not as the token
      // the user typed (xcode_project.dart's parseFlavorFromConfiguration
      // returns schemeName). Passing the token to Route B's own kernels would
      // describe a different Dart program than the one that ships.
      test('returns the scheme spelling, not the typed token', () async {
        stubList('{"project":{"schemes":["Runner","Foo","Bar"]}}');
        await expectLater(
          runWithOverrides(
            () => xcodeBuild.flavorScheme(
              projectPath: projectPath,
              flavor: 'foo',
            ),
          ),
          completion(equals('Foo')),
        );
      });

      test('matches case-insensitively in both directions', () async {
        stubList('{"project":{"schemes":["Runner","lowercased"]}}');
        await expectLater(
          runWithOverrides(
            () => xcodeBuild.flavorScheme(
              projectPath: projectPath,
              flavor: 'LOWERCASED',
            ),
          ),
          completion(equals('lowercased')),
        );
      });

      test('returns the flavor unchanged when no scheme matches', () async {
        stubList('{"project":{"schemes":["Runner","Other"]}}');
        await expectLater(
          runWithOverrides(
            () => xcodeBuild.flavorScheme(
              projectPath: projectPath,
              flavor: 'foo',
            ),
          ),
          completion(equals('foo')),
        );
      });

      // FAILS SOFT. Each of these is the pre-existing behaviour, and is correct
      // whenever the scheme is spelled like the token; failing loudly would turn
      // a cosmetic mismatch into a failed release.
      test('returns the flavor unchanged when xcodebuild fails', () async {
        stubList('', exitCode: ExitCode.software.code);
        await expectLater(
          runWithOverrides(
            () => xcodeBuild.flavorScheme(
              projectPath: projectPath,
              flavor: 'foo',
            ),
          ),
          completion(equals('foo')),
        );
      });

      test('returns the flavor unchanged on unparseable output', () async {
        stubList('not json');
        await expectLater(
          runWithOverrides(
            () => xcodeBuild.flavorScheme(
              projectPath: projectPath,
              flavor: 'foo',
            ),
          ),
          completion(equals('foo')),
        );
      });

      test('returns the flavor unchanged when schemes are absent', () async {
        stubList('{"project":{}}');
        await expectLater(
          runWithOverrides(
            () => xcodeBuild.flavorScheme(
              projectPath: projectPath,
              flavor: 'foo',
            ),
          ),
          completion(equals('foo')),
        );
      });

      test('does not shell out for an empty flavor', () async {
        await expectLater(
          runWithOverrides(
            () => xcodeBuild.flavorScheme(projectPath: projectPath, flavor: ''),
          ),
          completion(isEmpty),
        );
        verifyNever(() => process.run('xcodebuild', any()));
      });
    });

    group('version', () {
      group('when command exits with non-zero code', () {
        setUp(() {
          when(() => process.run('xcodebuild', ['-version'])).thenAnswer(
            (_) async => ShorebirdProcessResult(
              exitCode: ExitCode.software.code,
              stdout: '',
              stderr: 'error',
            ),
          );
        });

        test('throws ProcessException', () async {
          expect(
            () => runWithOverrides(xcodeBuild.version),
            throwsA(isA<ProcessException>()),
          );
        });
      });

      group('when command exits with success code', () {
        setUp(() {
          when(() => process.run('xcodebuild', ['-version'])).thenAnswer(
            (_) async => ShorebirdProcessResult(
              exitCode: ExitCode.success.code,
              stdout: '''
Xcode 15.3
Build version 15E204a
''',
              stderr: '',
            ),
          );
        });

        test('returns output lines joined by spaces', () async {
          expect(
            await runWithOverrides(xcodeBuild.version),
            equals('Xcode 15.3 Build version 15E204a'),
          );
        });
      });
    });
  });
}
