import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_release_kernels.dart';
import 'package:test/test.dart';

import 'mocks.dart';

void main() {
  group(RouteBReleaseKernelBuilder, () {
    group('forwardedArgs', () {
      test('translates dart-defines into gen_kernel -D flags', () {
        // Flutter spells them --dart-define=K=V, gen_kernel spells them -DK=V.
        // Same values, same order, one translation in one place.
        expect(
          RouteBReleaseKernelBuilder.forwardedArgs([
            '--dart-define=FLAVOR=prod',
            '--dart-define=API=https://x',
          ]),
          ['-DFLAVOR=prod', '-DAPI=https://x'],
        );
      });

      test('forwards language experiments unchanged', () {
        expect(
          RouteBReleaseKernelBuilder.forwardedArgs([
            '--enable-experiment=macros',
          ]),
          ['--enable-experiment=macros'],
        );
      });

      test('ignores options that do not change kernel semantics', () {
        expect(
          RouteBReleaseKernelBuilder.forwardedArgs([
            '--split-debug-info=build/symbols',
            '--obfuscate',
          ]),
          isEmpty,
        );
      });

      test('declines entirely on an option it cannot carry', () {
        // Flutter parses --dart-define-from-file's .json/.env shapes with its
        // own rules. Reimplementing that to expand it into -D flags is exactly
        // the hand-reconstruction this avoids, so it declines rather than
        // produce a plausible wrong kernel.
        expect(
          RouteBReleaseKernelBuilder.forwardedArgs([
            '--dart-define=OK=1',
            '--dart-define-from-file=env.json',
          ]),
          isNull,
        );
      });
    });

    group('build', () {
      late Directory projectRoot;
      late Directory cell;
      late ShorebirdLogger logger;
      late File output;

      RouteBCompiler compiler() => RouteBCompiler(
        runtime: File(p.join(cell.path, 'dartaotruntime')),
        compilerSnapshot: File(p.join(cell.path, 'dart2bytecode.aot')),
        platformDill: File(p.join(cell.path, 'vm_platform.dill')),
        analyzer: File(p.join(cell.path, 'route_b_analyze.aot')),
        frontend: File(p.join(cell.path, 'route_b_gen_kernel.aot')),
        flutterPlatformDill: File(
          p.join(cell.path, 'flutter_platform_strong.dill'),
        ),
        provenance: '',
      );

      R runWithOverrides<R>(R Function() body) => runScoped(
        body,
        values: {loggerRef.overrideWith(() => logger)},
      );

      setUp(() {
        projectRoot = Directory.systemTemp.createTempSync('project');
        cell = Directory.systemTemp.createTempSync('cell');
        logger = MockShorebirdLogger();
        output = File(
          p.join(
            Directory.systemTemp.createTempSync('out').path,
            'release_import.dill',
          ),
        );
        File(p.join(projectRoot.path, '.dart_tool', 'package_config.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync('{}');
      });

      List<String> capturedArgs({List<String> buildArgs = const []}) {
        late List<String> args;
        runWithOverrides(
          () => const RouteBReleaseKernelBuilder().build(
            compiler: compiler(),
            projectRoot: projectRoot,
            entrypoint: 'lib/main.dart',
            buildArgs: buildArgs,
            outputFile: output,
            run: (executable, arguments) {
              args = arguments;
              output.writeAsStringSync('KERNEL');
              return ProcessResult(0, 0, '', '');
            },
          ),
        );
        return args;
      }

      test('compiles against the FLUTTER platform from the cell', () {
        // Not vm_platform.dill, and not one found on this machine: bytecode
        // compiled against a different platform does not bind, and that
        // failure surfaces on device rather than here.
        final args = capturedArgs();

        expect(
          args,
          containsAllInOrder([
            '--platform',
            p.join(cell.path, 'flutter_platform_strong.dill'),
          ]),
        );
        expect(args, containsAllInOrder(['--target', 'flutter']));
      });

      test('differs from the release only in the mode', () {
        final args = capturedArgs();

        expect(args, containsAll(['--no-aot', '--no-link-platform']));
        expect(
          args,
          containsAllInOrder([
            '--packages',
            p.join(projectRoot.path, '.dart_tool', 'package_config.json'),
          ]),
        );
        // Absolute: gen_kernel resolves a relative path against the CWD,
        // which is wherever `shorebird release` was invoked from.
        expect(args.last, p.join(projectRoot.path, 'lib', 'main.dart'));
      });

      test('carries the release\'s defines through', () {
        expect(
          capturedArgs(buildArgs: ['--dart-define=FLAVOR=prod']),
          contains('-DFLAVOR=prod'),
        );
      });

      test('returns null and warns when the frontend fails', () {
        final result = runWithOverrides(
          () => const RouteBReleaseKernelBuilder().build(
            compiler: compiler(),
            projectRoot: projectRoot,
            entrypoint: 'lib/main.dart',
            buildArgs: const [],
            outputFile: output,
            run: (_, _) => ProcessResult(0, 1, '', 'boom'),
          ),
        );

        expect(result, isNull);
        verify(
          () => logger.warn(
            any(that: contains('patches for this release will be refused')),
          ),
        ).called(1);
      });

      test('carries the build\'s Dart plugin registrant', () {
        // Flutter adds these three whenever the build generated a registrant,
        // so the release kernel contains it and everything it pulls in.
        // Omitting them cost 59 non-accessor members on the reference app --
        // caught by agreesWith, not by a device.
        final registrant =
            File(
                p.join(
                  projectRoot.path,
                  '.dart_tool',
                  'flutter_build',
                  'dart_plugin_registrant.dart',
                ),
              )
              ..createSync(recursive: true)
              ..writeAsStringSync('// generated');

        final args = capturedArgs();

        expect(
          args,
          containsAllInOrder([
            '--source',
            registrant.uri.toString(),
            '--source',
            'package:flutter/src/dart_plugin_registrant.dart',
            '-Dflutter.dart_plugin_registrant=${registrant.uri}',
          ]),
        );
      });

      test('omits them when the build generated no registrant', () {
        expect(capturedArgs(), isNot(contains('--source')));
      });

      test('returns null when there is no package config', () {
        File(
          p.join(projectRoot.path, '.dart_tool', 'package_config.json'),
        ).deleteSync();

        final result = runWithOverrides(
          () => const RouteBReleaseKernelBuilder().build(
            compiler: compiler(),
            projectRoot: projectRoot,
            entrypoint: 'lib/main.dart',
            buildArgs: const [],
            outputFile: output,
            run: (_, _) => throw StateError('should not run'),
          ),
        );

        expect(result, isNull);
      });
    });
  });
}
