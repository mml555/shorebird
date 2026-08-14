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

      test('synthesises the resolved flavor as a define', () {
        // G4.2. It must be SYNTHESISED and cannot be forwarded: Flutter exits
        // if a user supplies FLUTTER_APP_FLAVOR via --dart-define, so a legal
        // invocation can never carry it among buildArgs.
        expect(
          RouteBReleaseKernelBuilder.forwardedArgs(
            ['--dart-define=API=https://x'],
            flavor: 'prod',
          ),
          ['-DAPI=https://x', '-DFLUTTER_APP_FLAVOR=prod'],
        );
      });

      test('appends the flavor LAST so it wins', () {
        // Mirrors Flutter's own xcodebuild-stage removeWhere-then-add
        // (flutter/issues/169598) and gen_kernel's measured last-wins duplicate
        // handling, so the define that reaches the compiler is the resolved
        // flavor and not a stale same-named one.
        expect(
          RouteBReleaseKernelBuilder.forwardedArgs(
            ['--dart-define=FLUTTER_APP_FLAVOR=stale'],
            flavor: 'fresh',
          )!.last,
          '-DFLUTTER_APP_FLAVOR=fresh',
        );
      });

      test('synthesises nothing for an absent or empty flavor', () {
        // The negative half of the pair. Without it the two tests above would
        // pass just as well against a version that always emitted the define.
        expect(RouteBReleaseKernelBuilder.forwardedArgs([]), isEmpty);
        expect(
          RouteBReleaseKernelBuilder.forwardedArgs([], flavor: ''),
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
        interfaceGenerator: File(
          p.join(cell.path, 'route_b_gen_dynamic_interface.aot'),
        ),
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

    // THIS GROUP EXISTS BECAUSE ITS ABSENCE SHIPPED A REGRESSION.
    //
    // generateDynamicInterface had no tests at all, and nothing asserted the
    // argv it builds. So when the generator began emitting private classes by
    // default, this call site -- which passed no --include, and therefore asked
    // for EVERY non-`dart:` library -- started producing an interface that does
    // not compile, and every existing test still passed. The breadth flag is
    // the whole product policy; it belongs under assertion.
    group('generateDynamicInterface', () {
      late Directory cell;
      late ShorebirdLogger logger;
      late File prepass;
      late File output;

      RouteBCompiler compiler() => RouteBCompiler(
        runtime: File(p.join(cell.path, 'dartaotruntime')),
        compilerSnapshot: File(p.join(cell.path, 'dart2bytecode.aot')),
        platformDill: File(p.join(cell.path, 'vm_platform.dill')),
        analyzer: File(p.join(cell.path, 'route_b_analyze.aot')),
        frontend: File(p.join(cell.path, 'route_b_gen_kernel.aot')),
        interfaceGenerator: File(
          p.join(cell.path, 'route_b_gen_dynamic_interface.aot'),
        ),
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
        cell = Directory.systemTemp.createTempSync('cell');
        logger = MockShorebirdLogger();
        final work = Directory.systemTemp.createTempSync('work');
        prepass = File(p.join(work.path, 'prepass.dill'))
          ..writeAsStringSync('KERNEL');
        output = File(p.join(work.path, 'dynamic_interface.yaml'));
      });

      test('restricts breadth to the app package', () {
        // Without this the generator treats every non-`dart:` library as the
        // app: 598 library items on the acceptance fixture, the breadth
        // measured at +275% -- and, with private classes emitted, an interface
        // that does not build at all.
        late List<String> args;
        final result = runWithOverrides(
          () => const RouteBReleaseKernelBuilder().generateDynamicInterface(
            compiler: compiler(),
            prepassKernel: prepass,
            outputFile: output,
            appPackageName: 'my_app',
            run: (executable, arguments) {
              args = arguments;
              output.writeAsStringSync('callable:');
              return ProcessResult(0, 0, '', '');
            },
          ),
        );

        expect(result, isNotNull);
        expect(args, containsAllInOrder(['--include', 'package:my_app/']));
      });

      // THE RETENTION-POLICY ARGV, and the same argument that created the group
      // above applies one level deeper.
      //
      // `--include` was pinned after it shipped a regression. The three flags
      // below decide as much and were pinned by nothing: `--private-dill` is
      // the difference between an interface that builds on a real app and one
      // that does not (PARITY.md section 4 -- `get:_file` for
      // ThrottledSaveLoadMixin),
      // `--policy` is the whole permission decision, and `--manifest` is the
      // only thing the patch side accepts a private reference against.
      //
      // The releaser's own tests assert the PARAMETER --
      // privateEnumerationKernel
      // isNotNull under agreement, isNull under fallback. Nothing asserted the
      // TRANSLATION from that parameter to argv, which is where a retention
      // policy actually stops being applied.
      List<String> interfaceArgs({
        File? privateEnumerationKernel,
        File? manifestFile,
        List<String> sdkMembers = routeBRetainedSdkMembers,
      }) {
        late List<String> args;
        final result = runWithOverrides(
          () => const RouteBReleaseKernelBuilder().generateDynamicInterface(
            compiler: compiler(),
            prepassKernel: prepass,
            outputFile: output,
            appPackageName: 'my_app',
            privateEnumerationKernel: privateEnumerationKernel,
            manifestFile: manifestFile,
            sdkMembers: sdkMembers,
            run: (executable, arguments) {
              args = arguments;
              output.writeAsStringSync('callable:');
              return ProcessResult(0, 0, '', '');
            },
          ),
        );
        expect(result, isNotNull);
        return args;
      }

      test('enumerates privates from the kernel it is handed', () {
        // The positive half. Without it the prepass supplies the private list,
        // and the prepass has had fields lowered into accessors -- so it yields
        // `get:_file` where the annotator's pre-transform component has `_file`
        // bare, and a single unresolvable entry fails the WHOLE interface.
        final privates = File(p.join(prepass.parent.path, 'early_import.dill'))
          ..writeAsStringSync('IMPORT-KERNEL');

        expect(
          interfaceArgs(privateEnumerationKernel: privates),
          containsAllInOrder(['--private-dill', privates.path]),
        );
      });

      test('passes no --private-dill when the caller withheld one', () {
        // The matched negative, and it is the half that stops the pair passing
        // vacuously. The caller withholds the kernel exactly when it disagreed
        // with the prepass, and the release must then fall back to prepass-only
        // enumeration -- a NARROWER release rather than one built from private
        // names describing a program it does not contain.
        expect(interfaceArgs(), isNot(contains('--private-dill')));
      });

      test('names the chosen policy rather than taking the default', () {
        // P2 is a decision with a recorded cost (+7.83% on Wonderous) and a
        // recorded alternative (P3, NON-VIABLE). Relying on the generator's
        // default would let that decision move in the generator.
        expect(interfaceArgs(), containsAllInOrder(['--policy', 'p2']));
      });

      test('asks for the manifest when given somewhere to put it', () {
        final manifest = File(p.join(prepass.parent.path, 'capabilities.json'));

        expect(
          interfaceArgs(manifestFile: manifest),
          containsAllInOrder(['--manifest', manifest.path]),
        );
        // And omits the flag entirely otherwise, so an absent manifest reads as
        // "granted nothing provable" rather than as an empty grant.
        expect(interfaceArgs(), isNot(contains('--manifest')));
      });

      test('retains SDK symbols BY NAME, never by library', () {
        // A whole `dart:core` item was measured at +310% -- a four-fold
        // snapshot. `--sdk-libraries` stays reachable for debugging and must
        // never be what a release asks for.
        final args = interfaceArgs();

        expect(
          args,
          containsAllInOrder([
            '--sdk-members',
            routeBRetainedSdkMembers.join(','),
          ]),
        );
        expect(args, isNot(contains('--sdk-libraries')));
        // The budget is small on purpose; every release pays for every name in
        // it, forever. This pins the list so a widening cannot be silent.
        expect(routeBRetainedSdkMembers, [
          'dart:core#print',
          'dart:core#DateTime.now',
          'dart:core#DateTime.get:millisecondsSinceEpoch',
          'dart:core#identical',
        ]);
      });

      test('does not generate an interface without a package name', () {
        // Refusing beats guessing. A release that cannot declare retention is
        // still a good release -- it just cannot be patched with a body that
        // names anything -- whereas a release built from an all-libraries
        // interface does not compile.
        final result = runWithOverrides(
          () => const RouteBReleaseKernelBuilder().generateDynamicInterface(
            compiler: compiler(),
            prepassKernel: prepass,
            outputFile: output,
            appPackageName: '',
            run: (_, _) => throw StateError('should not run'),
          ),
        );

        expect(result, isNull);
        verify(
          () => logger.warn(any(that: contains('package name'))),
        ).called(1);
      });
    });
  });
}
