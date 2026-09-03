import 'dart:convert';
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

      test('carries the defines FLUTTER injects, which no user typed', () {
        // G4.1c. Flutter appends these after parsing the command line
        // (`flutter_command.dart` _addFlutterVersionToDartDefines), so the
        // shipped kernel has them and, until this landed, no Route B kernel did.
        // Measured on a CLEAN `flutter create` app -- no flavor, no
        // --dart-define -- where the release still receives six.
        expect(
          RouteBReleaseKernelBuilder.forwardedArgs(
            const [],
            injectedDefines: const {
              'FLUTTER_VERSION': '3.44.8',
              'FLUTTER_ENGINE_REVISION': '11e5695710',
            },
          ),
          const [
            '-DFLUTTER_VERSION=3.44.8',
            '-DFLUTTER_ENGINE_REVISION=11e5695710',
          ],
        );
      });

      test('emits nothing extra when no injected map is supplied', () {
        // THE NEGATIVE CONTROL for the test above, and the state this fixed.
        // Without it, the assertion there would pass just as well against an
        // implementation that emitted FLUTTER_* defines unconditionally from a
        // hard-coded list -- which is precisely the hand-reconstruction this
        // seam exists to avoid.
        expect(RouteBReleaseKernelBuilder.forwardedArgs(const []), isEmpty);
        expect(
          RouteBReleaseKernelBuilder.forwardedArgs(
            const [],
            injectedDefines: const {},
          ),
          isEmpty,
        );
      });

      test('leaves an ordinary user define untouched by the injected set', () {
        // THE CONTROL the brief requires: threading Flutter's defines must not
        // change how a user's own define is carried. Same input, same output,
        // with and without the injected map.
        const userOnly = ['--dart-define=API=https://x'];
        expect(
          RouteBReleaseKernelBuilder.forwardedArgs(userOnly),
          const ['-DAPI=https://x'],
        );
        expect(
          RouteBReleaseKernelBuilder.forwardedArgs(
            userOnly,
            injectedDefines: const {'FLUTTER_VERSION': '3.44.8'},
          ),
          const ['-DFLUTTER_VERSION=3.44.8', '-DAPI=https://x'],
        );
      });

      test('still appends the resolved flavor LAST', () {
        // The injected map must not displace the flavor from the end of the
        // list, where gen_kernel's last-wins handling is what makes it decisive.
        expect(
          RouteBReleaseKernelBuilder.forwardedArgs(
            const ['--dart-define=API=https://x'],
            flavor: 'prod',
            injectedDefines: const {'FLUTTER_VERSION': '3.44.8'},
          )!.last,
          '-DFLUTTER_APP_FLAVOR=prod',
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
        releaseProbe: File(
          p.join(cell.path, 'route_b_release_probe.aot'),
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

      // The input shape here is the real one and is deliberately NOT changed:
      // Flutter supplies POSIX-style targets, so `lib/main.dart` is what this
      // code is handed on every host, Windows included.
      //
      // WINDOWS IS THE DISCRIMINATING ENVIRONMENT. A bare join there produced
      // `C:\…\project\lib/main.dart` — separators mixed inside one path — while
      // on POSIX join and normalize already agree, so this can only fail on
      // Windows. Asserted against the invariant rather than the symptom: a path
      // built for a downstream compiler is canonical for its host.
      test('canonicalises a POSIX-style entrypoint for the host', () {
        final target = capturedArgs().last;

        expect(target, p.normalize(target), reason: 'already canonical');
        expect(p.isAbsolute(target), isTrue);
        expect(
          target.contains(p.style == p.Style.windows ? '/' : r'\'),
          isFalse,
          reason: 'no foreign separator survives inside the path',
        );
      });

      test('carries the release\'s defines through', () {
        expect(
          capturedArgs(buildArgs: ['--dart-define=FLAVOR=prod']),
          contains('-DFLAVOR=prod'),
        );
      });

      test('carries the injected defines into the IMPORT kernel', () {
        // G4.1c. A patch is COMPILED AND BOUND against this kernel, so a define
        // the release had and this lacks makes the patch a different program
        // from the one it is replacing bodies in.
        late List<String> args;
        runWithOverrides(
          () => const RouteBReleaseKernelBuilder().build(
            compiler: compiler(),
            projectRoot: projectRoot,
            entrypoint: 'lib/main.dart',
            buildArgs: const [],
            outputFile: output,
            injectedDefines: const {'FLUTTER_VERSION': '3.44.8'},
            run: (executable, arguments) {
              args = arguments;
              output.writeAsStringSync('KERNEL');
              return ProcessResult(0, 0, '', '');
            },
          ),
        );

        expect(args, contains('-DFLUTTER_VERSION=3.44.8'));
        // The negative half: the SAME call without the map must not carry it,
        // or the assertion above cannot fail and certifies nothing.
        expect(capturedArgs(), isNot(contains('-DFLUTTER_VERSION=3.44.8')));
      });

      test('carries the injected defines into the PREPASS', () {
        // The prepass decides RETENTION -- what a future patch is allowed to
        // name. Route B's own coverage analyzer reports `main` as CHANGED
        // between a prepass compiled with these and one compiled without, on an
        // app with no flavor and no user defines at all.
        late List<String> args;
        runWithOverrides(
          () => const RouteBReleaseKernelBuilder().buildPrepass(
            compiler: compiler(),
            projectRoot: projectRoot,
            entrypoint: 'lib/main.dart',
            buildArgs: const [],
            outputFile: output,
            injectedDefines: const {'FLUTTER_VERSION': '3.44.8'},
            run: (executable, arguments) {
              args = arguments;
              output.writeAsStringSync('KERNEL');
              return ProcessResult(0, 0, '', '');
            },
          ),
        );

        expect(args, containsAll(['--aot', '-DFLUTTER_VERSION=3.44.8']));
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
        releaseProbe: File(
          p.join(cell.path, 'route_b_release_probe.aot'),
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

      // EXACT CONSTRUCTOR RETENTION, derived by the RELEASE ITSELF.
      //
      // The rule is that a patch may reuse a private construction only when the
      // released version of that same method already performed it, which is
      // worth nothing unless the release retains those exact constructors. A
      // qualification notebook that runs a census by hand and passes
      // --grant-constructor is not a product feature; PLATFORM-PRECACHE taught
      // that. These tests exist at the release path so the derivation cannot
      // quietly stop happening.
      group('derives exact constructor grants from its own methods', () {
        /// A `run` that answers the census with [rows] and records the
        /// generator's argv.
        List<String> generatorArgvFor(List<Map<String, Object?>> rows) {
          late List<String> generatorArgs;
          runWithOverrides(
            () => const RouteBReleaseKernelBuilder().generateDynamicInterface(
              compiler: compiler(),
              prepassKernel: prepass,
              outputFile: output,
              appPackageName: 'my_app',
              run: (executable, arguments) {
                if (arguments.contains('--census')) {
                  final out = arguments[arguments.indexOf('--out') + 1];
                  File(out).writeAsStringSync(
                    [
                      jsonEncode({'censusVersion': 2}),
                      for (final row in rows) jsonEncode(row),
                    ].join('\n'),
                  );
                  return ProcessResult(0, 0, '', '');
                }
                generatorArgs = arguments;
                output.writeAsStringSync('callable:');
                return ProcessResult(0, 0, '', '');
              },
            ),
          );
          return generatorArgs;
        }

        Map<String, Object?> row(String target, List<String> keys) => {
          'target': target,
          'privateConstructions': [
            for (final key in keys)
              {
                'offset': 0,
                'library': 'package:my_app/main.dart',
                'class': key.split('#').last.split('.').first,
                'constructor': 'new',
                'key': key,
              },
          ],
        };

        test('asks the analyzer, over the same prepass kernel', () {
          late List<String> censusArgs;
          runWithOverrides(
            () => const RouteBReleaseKernelBuilder().generateDynamicInterface(
              compiler: compiler(),
              prepassKernel: prepass,
              outputFile: output,
              appPackageName: 'my_app',
              run: (executable, arguments) {
                if (arguments.contains('--census')) censusArgs = arguments;
                output.writeAsStringSync('callable:');
                return ProcessResult(0, 0, '', '');
              },
            ),
          );
          expect(censusArgs, contains('--census'));
          expect(censusArgs, containsAllInOrder(['--dill', prepass.path]));
          expect(
            censusArgs,
            containsAllInOrder(['--include', 'package:my_app/']),
          );
        });

        test('grants exactly what release methods construct', () {
          final args = generatorArgvFor([
            row('package:my_app/main.dart#A.build', [
              'package:my_app/main.dart#_One.new',
            ]),
            row('package:my_app/main.dart#B.build', [
              'package:my_app/main.dart#_Two.new',
            ]),
          ]);
          expect(
            args,
            containsAllInOrder([
              '--grant-constructor',
              'package:my_app/main.dart#_One.new',
            ]),
          );
          expect(
            args,
            containsAllInOrder([
              '--grant-constructor',
              'package:my_app/main.dart#_Two.new',
            ]),
          );
        });

        test('grants each constructor once, in a stable order', () {
          // Two methods constructing the same class must not produce two
          // grants, and the order must not depend on census row order, or the
          // same inputs would not produce the same release.
          final args = generatorArgvFor([
            row('package:my_app/main.dart#B.build', [
              'package:my_app/main.dart#_Two.new',
              'package:my_app/main.dart#_One.new',
            ]),
            row('package:my_app/main.dart#A.build', [
              'package:my_app/main.dart#_One.new',
            ]),
          ]);
          final granted = [
            for (var i = 0; i < args.length; i++)
              if (args[i] == '--grant-constructor') args[i + 1],
          ];
          expect(granted, [
            'package:my_app/main.dart#_One.new',
            'package:my_app/main.dart#_Two.new',
          ]);
        });

        test('grants NOTHING when no method constructs privately', () {
          final args = generatorArgvFor([
            row('package:my_app/main.dart#A.build', const []),
          ]);
          expect(args, isNot(contains('--grant-constructor')));
        });

        test(
          'an analyzer that cannot enumerate leaves the release narrower',
          () {
            // A cell whose analyzer predates this reports nothing. The release
            // must be exactly what it was before — narrower, never broken.
            late List<String> generatorArgs;
            final result = runWithOverrides(
              () => const RouteBReleaseKernelBuilder().generateDynamicInterface(
                compiler: compiler(),
                prepassKernel: prepass,
                outputFile: output,
                appPackageName: 'my_app',
                run: (executable, arguments) {
                  if (arguments.contains('--census')) {
                    return ProcessResult(0, 1, '', 'unknown option --census');
                  }
                  generatorArgs = arguments;
                  output.writeAsStringSync('callable:');
                  return ProcessResult(0, 0, '', '');
                },
              ),
            );
            expect(result, isNotNull);
            expect(generatorArgs, isNot(contains('--grant-constructor')));
          },
        );
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
