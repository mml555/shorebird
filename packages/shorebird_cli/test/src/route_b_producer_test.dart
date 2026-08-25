import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/route_b_build_config.dart';
import 'package:shorebird_cli/src/route_b_capabilities.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_container.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_survival.dart';
import 'package:shorebird_cli/src/route_b_producer.dart';
import 'package:test/test.dart';

import 'mocks.dart';

void main() {
  group(RouteBProducer, () {
    late Directory cell;
    late Directory work;
    late Directory project;
    late File source;
    late ShorebirdLogger logger;

    const declaration = "String routeBValue() => 'NEW';";

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

    RouteBCoverage coverage({
      List<String> representable = const ['package:app/main.dart#routeBValue'],
      Map<String, Object?>? sources,
    }) => RouteBCoverage.fromJson(
      jsonEncode({
        'analysisVersion': supportedRouteBAnalysisVersion,
        'verdict': 'accept',
        'changed': representable,
        'added': <String>[],
        'removed': <String>[],
        'patchable': representable,
        'conditional': <String>[],
        'sources':
            sources ??
            {
              'package:app/main.dart#routeBValue': {
                'fileUri': source.uri.toString(),
                'start': 0,
                'end': declaration.length,
              },
            },
        'rejections': <Object>[],
        'refusalSummary': null,
      }),
    );

    R runWithOverrides<R>(R Function() body) => runScoped(
      body,
      values: {loggerRef.overrideWith(() => logger)},
    );

    setUp(() {
      cell = Directory.systemTemp.createTempSync('cell');
      work = Directory.systemTemp.createTempSync('work');
      project = Directory.systemTemp.createTempSync('project');
      logger = MockShorebirdLogger();
      source = File(p.join(project.path, 'main.dart'))
        ..writeAsStringSync(declaration);
    });

    /// Stands in for dart2bytecode, writing a deterministic payload.
    ProcessResult compileOk(String executable, List<String> arguments) {
      final output = arguments[arguments.indexOf('-o') + 1];
      File(output).writeAsStringSync('BYTECODE-FOR-${p.basename(output)}');
      return ProcessResult(0, 0, '', '');
    }

    test('writes one replacement library per target, with the pragma', () {
      // One payload is one function: Dart_RouteBActivatePatch attaches the
      // single Function LoadBytecode returns, so a payload has to hold exactly
      // one declaration and it has to be loadable as a dynamic module entry.
      runWithOverrides(
        () => const RouteBProducer().produce(
          compiler: compiler(),
          coverage: coverage(),
          importKernel: File(p.join(cell.path, 'release_import.dill')),
          releaseBuildId: 'deadbeef',
          workingDirectory: work,
          projectRoot: project,
          run: compileOk,
        ),
      );

      final generated = File(
        p.join(work.path, 'replacement_0.dart'),
      ).readAsStringSync();
      expect(generated, contains(RouteBProducer.entryPointPragma));
      expect(generated, contains(declaration));
      // The body may reference other members of the library it replaces a
      // function in, and a synthetic library importing nothing cannot see them
      // — rung A died on exactly that with "Method not found: 'routeBHelper'".
      expect(generated, startsWith("import 'package:app/main.dart';"));
    });

    test(
      'compiles against the FLUTTER platform and the RELEASE import kernel',
      () {
        late List<String> args;
        runWithOverrides(
          () => const RouteBProducer().produce(
            compiler: compiler(),
            coverage: coverage(),
            importKernel: File(p.join(cell.path, 'release_import.dill')),
            releaseBuildId: 'deadbeef',
            workingDirectory: work,
            projectRoot: project,
            run: (executable, arguments) {
              args = arguments;
              return compileOk(executable, arguments);
            },
          ),
        );

        expect(
          args,
          containsAllInOrder([
            '--platform',
            p.join(cell.path, 'flutter_platform_strong.dill'),
          ]),
        );
        expect(args, containsAllInOrder(['--target', 'flutter']));
        // G4.1: with no build config there are no -D args at all, so a
        // release that used no defines does not get an empty one invented.
        expect(args.where((a) => a.startsWith('-D')), isEmpty);
        expect(
          args,
          containsAllInOrder([
            '--import-dill',
            p.join(cell.path, 'release_import.dill'),
          ]),
        );
        // Without --packages the generated `import` cannot resolve a package
        // URI, and dart2bytecode refuses with exit 254 and no stderr.
        expect(
          args,
          containsAllInOrder([
            '--packages',
            p.join(project.path, '.dart_tool', 'package_config.json'),
          ]),
        );
      },
    );

    test('G4.1: threads the release define set into the compile, sorted', () {
      late List<String> args;
      runWithOverrides(
        () => const RouteBProducer().produce(
          compiler: compiler(),
          coverage: coverage(),
          importKernel: File(p.join(cell.path, 'release_import.dill')),
          releaseBuildId: 'deadbeef',
          workingDirectory: work,
          projectRoot: project,
          // Supplied in the "wrong" order deliberately: order is not semantic
          // (probes/g41_define_semantics.sh measured byte-identical kernels), and
          // a deterministic emission order keeps the compile reproducible from
          // the recorded configuration.
          buildConfig: RouteBBuildConfig.fromBuildArgs([
            '--dart-define=b=2',
            '--dart-define=a=1',
          ]),
          run: (executable, arguments) {
            args = arguments;
            return compileOk(executable, arguments);
          },
        ),
      );

      // Without these, a replacement reading
      // `const String.fromEnvironment('a')` compiles against the DEFAULT while
      // the release around it holds '1'. Both are literals by the time anything
      // runs, so no runtime check could ever see the divergence.
      expect(args.where((a) => a.startsWith('-D')).toList(), [
        '-Da=1',
        '-Db=2',
      ]);
    });

    test('G4.1c: threads the INJECTED defines too, ahead of the user ones', () {
      // Link 2. The release's `-D` environment is both maps: the user's defines
      // and the ones Flutter injected. Before this, `compilerArgs` came from
      // `effectiveDefines` alone and a replacement reading FLUTTER_VERSION baked
      // the empty string while the release held 3.44.8.
      late List<String> args;
      runWithOverrides(
        () => const RouteBProducer().produce(
          compiler: compiler(),
          coverage: coverage(),
          importKernel: File(p.join(cell.path, 'release_import.dill')),
          releaseBuildId: 'deadbeef',
          workingDirectory: work,
          projectRoot: project,
          buildConfig: RouteBBuildConfig.fromBuildArgs(
            ['--dart-define=a=1'],
            injectedDefines: const {'FLUTTER_VERSION': '3.44.8'},
          ),
          run: (executable, arguments) {
            args = arguments;
            return compileOk(executable, arguments);
          },
        ),
      );

      expect(args.where((a) => a.startsWith('-D')).toList(), [
        '-DFLUTTER_VERSION=3.44.8',
        '-Da=1',
      ]);
    });

    group('G4.1c: a release that predates the injected-define record', () {
      RouteBBuildConfig legacyConfig() =>
          RouteBBuildConfig.fromJson(<String, dynamic>{
            'rawArgs': <String>[],
            'effectiveDefines': <String, String>{},
          });

      /// A replacement whose body reads the compile-time environment — the one
      /// construct that resolves against the `-D` flags rather than through the
      /// import kernel.
      RouteBCoverage coverageReadingEnvironment() {
        const envDeclaration =
            "String routeBValue() => "
            "const String.fromEnvironment('FLUTTER_VERSION');";
        source.writeAsStringSync(envDeclaration);
        return coverage(
          sources: {
            'package:app/main.dart#routeBValue': {
              'fileUri': source.uri.toString(),
              'start': 0,
              'end': envDeclaration.length,
            },
          },
        );
      }

      List<String> produceWith({
        required RouteBBuildConfig? buildConfig,
        required RouteBCoverage cov,
      }) {
        late List<String> args;
        runWithOverrides(
          () => const RouteBProducer().produce(
            compiler: compiler(),
            coverage: cov,
            importKernel: File(p.join(cell.path, 'release_import.dill')),
            releaseBuildId: 'deadbeef',
            workingDirectory: work,
            projectRoot: project,
            buildConfig: buildConfig,
            run: (executable, arguments) {
              args = arguments;
              return compileOk(executable, arguments);
            },
          ),
        );
        return args;
      }

      test('is still patchable by an ordinary replacement', () {
        // THE CONTROL, and it is the reason the refusal is narrow rather than
        // blanket. Releases 89-95 and every one before them carry no record and
        // can never be given one — refusing all of their patches would strand
        // them permanently to guard against a construct almost none contain.
        expect(
          produceWith(buildConfig: legacyConfig(), cov: coverage()),
          isNotEmpty,
        );
      });

      test('refuses a replacement that reads the compile-time environment', () {
        // The one case that would actually be wrong: this expression compiles
        // against the `-D` flags, and a pre-record release has none to give it.
        expect(
          () => produceWith(
            buildConfig: legacyConfig(),
            cov: coverageReadingEnvironment(),
          ),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.reason,
              'reason',
              contains('predates the record'),
            ),
          ),
        );
      });

      test('accepts the same replacement when the release DID record', () {
        // The discriminator. Without this the refusal above would pass equally
        // against an implementation that refused every environment read.
        expect(
          produceWith(
            buildConfig: RouteBBuildConfig.fromBuildArgs(
              const [],
              injectedDefines: const {'FLUTTER_VERSION': '3.44.8'},
            ),
            cov: coverageReadingEnvironment(),
          ),
          isNotEmpty,
        );
      });
    });

    test('packs a container the reader accepts', () {
      final bytes = runWithOverrides(
        () => const RouteBProducer().produce(
          compiler: compiler(),
          coverage: coverage(),
          importKernel: File(p.join(cell.path, 'release_import.dill')),
          releaseBuildId: 'deadbeef',
          workingDirectory: work,
          projectRoot: project,
          run: compileOk,
        ),
      );

      final container = RouteBContainer.parse(bytes);
      expect(container.releaseBuildId, 'deadbeef');
      expect(container.targets.single.library, 'package:app/main.dart');
      expect(container.targets.single.selector, 'routeBValue');
    });

    test('is deterministic across runs and target order', () {
      // What makes exact SHA equality against the reference packer a fair
      // gate. Targets are sorted, so the caller's ordering cannot change the
      // bytes.
      List<int> build(List<String> order) => runWithOverrides(
        () => const RouteBProducer().produce(
          compiler: compiler(),
          coverage: coverage(
            representable: order,
            sources: {
              for (final key in order)
                key: {
                  'fileUri': source.uri.toString(),
                  'start': 0,
                  'end': declaration.length,
                },
            },
          ),
          importKernel: File(p.join(cell.path, 'release_import.dill')),
          releaseBuildId: 'deadbeef',
          workingDirectory: work,
          projectRoot: project,
          run: compileOk,
        ),
      );

      expect(
        build(['a#one', 'a#two']),
        build(['a#two', 'a#one']),
      );
    });

    group('implicit-this lowering', () {
      const key = 'package:app/main.dart#RouteBThing.value';

      /// Builds coverage for one instance target whose declaration is [decl],
      /// placed after [preamble] so offsets are realistic.
      RouteBCoverage instanceCoverage({
        required String preamble,
        required String decl,
        required String access,
        // The target's own key. Only a test about the target's LIBRARY needs to
        // change it; everything else wants the one shared key.
        String targetKey = key,
        String member = 'label',
        String kind = 'get',
        // A second receiver access, for an argument that itself touches the
        // receiver: `helper(label)` is two accesses, not one.
        String? also,
        String alsoMember = 'label',
        String alsoKind = 'get',
        String receiverType = 'RouteBThing',
        List<String> unsupported = const [],
        // The manifest key the analyzer reports for a PRIVATE access. Set to
        // 'library#Class#name' to make the first access private.
        String? private,
      }) {
        source.writeAsStringSync('$preamble$decl');
        final start = preamble.length;
        return RouteBCoverage.fromJson(
          jsonEncode({
            'analysisVersion': supportedRouteBAnalysisVersion,
            'verdict': 'accept',
            'changed': [targetKey],
            'added': <String>[],
            'removed': <String>[],
            'patchable': <String>[],
            'conditional': [targetKey],
            'sources': {
              targetKey: {
                'fileUri': source.uri.toString(),
                'start': start,
                'end': start + decl.length,
              },
            },
            'lowering': {
              targetKey: {
                'receiverType': receiverType,
                'nameOffset': start + decl.indexOf('value'),
                'accesses': [
                  if (access.isNotEmpty)
                    {
                      // The analyzer points at the IDENTIFIER, which is the
                      // tail of the spelling: `this.label` and `label` differ
                      // only in what precedes it.
                      'offset':
                          start +
                          decl.indexOf(access) +
                          access.length -
                          member.length,
                      'member': member,
                      'kind': kind,
                      if (private != null)
                        'private': {
                          'library': private.split('#')[0],
                          'class': private.split('#')[1],
                          'name': private.split('#')[2],
                        },
                    },
                  if (also != null)
                    {
                      'offset':
                          start +
                          decl.indexOf(also) +
                          also.length -
                          alsoMember.length,
                      'member': alsoMember,
                      'kind': alsoKind,
                    },
                ],
                'unsupported': unsupported,
              },
            },
            'rejections': <Object>[],
            'refusalSummary': null,
          }),
        );
      }

      /// The compiler arguments of the last run, so a test can assert on the
      /// flag as well as on the source.
      var lastArguments = <String>[];

      String lowered(RouteBCoverage coverage, {RouteBCapabilities? granting}) {
        runWithOverrides(
          () => const RouteBProducer().produce(
            compiler: compiler(),
            coverage: coverage,
            importKernel: File(p.join(cell.path, 'release_import.dill')),
            releaseBuildId: 'deadbeef',
            workingDirectory: work,
            projectRoot: project,
            capabilities: granting,
            run: (executable, arguments) {
              lastArguments = arguments;
              return compileOk(executable, arguments);
            },
          ),
        );
        return File(p.join(work.path, 'replacement_0.dart')).readAsStringSync();
      }

      /// A release manifest granting exactly [instance] and [classes].
      RouteBCapabilities grants({
        List<String> instance = const [],
        List<String> classes = const [],
        // Passing this makes the manifest one the CURRENT generator emits: it
        // names each public member of a private class. Omitting it models a
        // release cut before 2026-08-25, which granted them through a bare
        // `class:` item and recorded no list — and telling those two apart is
        // exactly what `recordsClassPublicMembers` is for.
        List<String>? classPublicMembers,
      }) => RouteBCapabilities.fromJson(
        jsonEncode({
          'policy': 'p2',
          'privateInstanceCallable': instance,
          'privateClassesConstructible': classes,
          if (classPublicMembers != null)
            'privateClassPublicMembers': classPublicMembers,
        }),
      );

      test('lowers a bare instance getter', () {
        expect(
          lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: 'String value() => label;',
              access: 'label',
            ),
          ),
          contains('String value(RouteBThing self) => self.label;'),
        );
      });

      test('a private receiver class lowers to `dynamic`', () {
        // `_RouteBState self` would resolve to nothing: privacy is
        // library-scoped and the replacement is its own library. The front end
        // accepts any member name on a dynamic receiver, so `dynamic` lets the
        // private class go unnamed. In Flutter this is the common case, because
        // a StatefulWidget's State class is private by convention.
        expect(
          lowered(
            instanceCoverage(
              preamble: 'class _RouteBState {\n  ',
              decl: 'String value() => label;',
              access: 'label',
              receiverType: '_RouteBState',
            ),
          ),
          contains('String value(dynamic self) => self.label;'),
        );
      });

      test('a public receiver class keeps its concrete type', () {
        // The guard against a regression, not a new behaviour: every spelling
        // already proven on device must lower to byte-identical source, so the
        // substitution has to be conditional rather than universal.
        expect(
          lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: 'String value() => label;',
              access: 'label',
            ),
          ),
          contains('String value(RouteBThing self) => self.label;'),
        );
      });

      test('a private receiver class lowers a write to `dynamic` too', () {
        expect(
          lowered(
            instanceCoverage(
              preamble: 'class _RouteBState {\n  ',
              decl: "String value() => slot = 'NEW';",
              access: 'slot',
              member: 'slot',
              kind: 'set',
              receiverType: '_RouteBState',
            ),
          ),
          contains("String value(dynamic self) => self.slot = 'NEW';"),
        );
      });

      test('lowers an explicit this.label', () {
        // The SAME Kernel node as the bare form; only the source distinguishes
        // them, which is why the producer reads the text and the analyzer does
        // not try to report it.
        expect(
          lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: 'String value() => this.label;',
              access: 'this.label',
            ),
          ),
          contains('String value(RouteBThing self) => self.label;'),
        );
      });

      test('is exact under non-ASCII text before the target', () {
        // The offsets are code units. Byte-slicing drifted 6 bytes on the real
        // fixture and produced a library that began mid-word.
        expect(
          lowered(
            instanceCoverage(
              preamble: '// em dashes — — — before it\nclass RouteBThing {\n  ',
              decl: 'String value() => label;',
              access: 'label',
            ),
          ),
          contains('String value(RouteBThing self) => self.label;'),
        );
      });

      test('finds the parameter list past an annotation', () {
        // @pragma('vm:never-inline') has parentheses of its own, earlier in
        // the slice than the method's.
        expect(
          lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: "@pragma('vm:never-inline')\n  String value() => label;",
              access: 'label',
            ),
          ),
          contains('String value(RouteBThing self) => self.label;'),
        );
      });

      test('touches nothing the kernel did not report', () {
        // A local, a top-level symbol and a static member are different Kernel
        // nodes and never appear as receiver accesses, so they must survive
        // verbatim. This is the whole reason meaning comes from the kernel.
        final out = lowered(
          instanceCoverage(
            preamble: 'class RouteBThing {\n  ',
            decl:
                'String value() { final label = topLevel + Cls.stat; '
                'return label; }',
            access: '',
          ),
        );
        expect(out, contains('final label = topLevel + Cls.stat;'));
        expect(out, contains('return label; }'));
        expect(out, isNot(contains('self.label')));
        expect(out, contains('String value(RouteBThing self)'));
      });

      test('lowers a bare zero-argument receiver call', () {
        expect(
          lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: 'String value() => helper();',
              access: 'helper',
              member: 'helper',
              kind: 'invoke',
            ),
          ),
          contains('String value(RouteBThing self) => self.helper();'),
        );
      });

      test('lowers an explicit this.helper()', () {
        expect(
          lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: 'String value() => this.helper();',
              access: 'this.helper',
              member: 'helper',
              kind: 'invoke',
            ),
          ),
          contains('String value(RouteBThing self) => self.helper();'),
        );
      });

      test('lowers a call exactly under non-ASCII text before it', () {
        expect(
          lowered(
            instanceCoverage(
              preamble:
                  '// em dashes \u2014 \u2014 before it\nclass RouteBThing {\n  ',
              decl: 'String value() => helper();',
              access: 'helper',
              member: 'helper',
              kind: 'invoke',
            ),
          ),
          contains('String value(RouteBThing self) => self.helper();'),
        );
      });

      test('lowers a call with one positional argument', () {
        // The argument list is not rewritten, understood, or reconstructed —
        // it is the source's own text, carried across.
        expect(
          lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: "String value() => helper('ARG');",
              access: 'helper',
              member: 'helper',
              kind: 'invoke',
            ),
          ),
          contains("String value(RouteBThing self) => self.helper('ARG');"),
        );
      });

      test('lowers an argument that is itself a receiver read', () {
        // Two accesses, and the edits are applied right-to-left so the earlier
        // offset is still valid when it is reached.
        expect(
          lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: 'String value() => helper(label);',
              access: 'helper',
              member: 'helper',
              kind: 'invoke',
              also: '(label',
            ),
          ),
          contains(
            'String value(RouteBThing self) => self.helper(self.label);',
          ),
        );
      });

      test('lowers this.helper with an argument', () {
        expect(
          lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: "String value() => this.helper('x');",
              access: 'this.helper',
              member: 'helper',
              kind: 'invoke',
            ),
          ),
          contains("String value(RouteBThing self) => self.helper('x');"),
        );
      });

      test('leaves a named argument exactly as written', () {
        // Nothing here is parsed. If the edit is only `helper` -> `self.helper`,
        // named arguments and nesting cannot be disturbed — this pins that.
        expect(
          lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: "String value() => helper('a', b: f(1, 2), c: [3]);",
              access: 'helper',
              member: 'helper',
              kind: 'invoke',
            ),
          ),
          contains(
            "String value(RouteBThing self) => "
            "self.helper('a', b: f(1, 2), c: [3]);",
          ),
        );
      });

      test('lowers a call with arguments under non-ASCII text', () {
        expect(
          lowered(
            instanceCoverage(
              preamble:
                  '// dashes \u2014 \u2014 \u2014\nclass RouteBThing {\n  ',
              decl: "String value() => helper('ARG');",
              access: 'helper',
              member: 'helper',
              kind: 'invoke',
            ),
          ),
          contains("String value(RouteBThing self) => self.helper('ARG');"),
        );
      });

      test('lowers a bare receiver write', () {
        expect(
          lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: "String value() => label = 'NEW-SET';",
              access: 'label',
              kind: 'set',
            ),
          ),
          contains(
            "String value(RouteBThing self) => self.label = 'NEW-SET';",
          ),
        );
      });

      test('G3.7: keeps the target\'s own parameters and puts self first', () {
        // The entry-point contract permits any number of required positionals
        // (patch 0006), so the receiver is inserted IN FRONT of the existing
        // list rather than into an empty one. The list is copied verbatim: no
        // type is parsed and no name is rewritten.
        expect(
          lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: "String tagged(String x) => 'NEW-\$x' + label;",
              access: 'label',
              kind: 'get',
            ),
          ),
          contains(
            "String tagged(RouteBThing self, String x) => 'NEW-\$x' + self.label;",
          ),
        );
      });

      test(
        'G3.7: a multi-parameter target keeps every parameter, in order',
        () {
          expect(
            lowered(
              instanceCoverage(
                preamble: 'class RouteBThing {\n  ',
                decl: 'String pair(String a, int b) => label;',
                access: 'label',
                kind: 'get',
              ),
            ),
            contains(
              'String pair(RouteBThing self, String a, int b) => self.label;',
            ),
          );
        },
      );

      test('lowers an explicit this write', () {
        expect(
          lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: "String value() => this.label = 'NEW-SET';",
              access: 'this.label',
              kind: 'set',
            ),
          ),
          contains(
            "String value(RouteBThing self) => self.label = 'NEW-SET';",
          ),
        );
      });

      test('leaves the right-hand side untouched', () {
        // The RHS is never parsed. A receiver use inside it is its own reported
        // access, which is why the read here is rewritten too.
        expect(
          lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: "String value() => label = label + f(1, 'x');",
              access: 'label',
              kind: 'set',
              also: '= label',
            ),
          ),
          contains(
            "String value(RouteBThing self) => "
            "self.label = self.label + f(1, 'x');",
          ),
        );
      });

      test('refuses a read and a write at one position', () {
        // `label += 'X'`, `count++` and `maybe ??= 'Z'` each report a read AND a
        // write at the same identifier — measured, not assumed. Two insertions
        // there would produce `self.self.label`. The analyzer refuses it; this
        // is the producer's backstop for the two disagreeing.
        expect(
          () => lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: "String value() => label += 'X';",
              access: 'label',
              kind: 'set',
              also: 'label',
              alsoKind: 'get',
            ),
          ),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.reason,
              'reason',
              contains('twice at one position'),
            ),
          ),
        );
      });

      test('refuses a target the release did not grant', () {
        // P4.2. The target is the member being REPLACED, and until now nothing
        // checked its own grant — so an ungranted target published, downloaded,
        // and failed at ATTACH on the device with a message about attachment.
        // This moves that failure left, to a named refusal before upload.
        expect(
          () => lowered(
            instanceCoverage(
              targetKey: 'package:app/main.dart#_RouteBState.value',
              preamble: 'class _RouteBState {\n  ',
              decl: 'String value() => label;',
              access: 'label',
              receiverType: '_RouteBState',
            ),
            granting: grants(
              // Names OTHER members of the class but not `value` — the shape a
              // release has when the target was never retained.
              classPublicMembers: [
                'package:app/main.dart#_RouteBState#somethingElse',
              ],
            ),
          ),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.reason,
              'reason',
              contains('did not grant'),
            ),
          ),
        );
      });

      test('accepts a target the release granted by name', () {
        expect(
          lowered(
            instanceCoverage(
              targetKey: 'package:app/main.dart#_RouteBState.value',
              preamble: 'class _RouteBState {\n  ',
              decl: 'String value() => label;',
              access: 'label',
              receiverType: '_RouteBState',
            ),
            granting: grants(
              classPublicMembers: ['package:app/main.dart#_RouteBState#value'],
            ),
          ),
          contains('String value(dynamic self) => self.label;'),
        );
      });

      test('accepts a private-class target on a pre-2026-08-25 release', () {
        // A REGRESSION GUARD, and the reason the check is conditional. Such a
        // release granted the class's public members through a bare `class:`
        // item and recorded no per-member list, so it genuinely granted this
        // target and simply cannot be asked member by member. Refusing it would
        // be a regression dressed as a safety check.
        expect(
          lowered(
            instanceCoverage(
              targetKey: 'package:app/main.dart#_RouteBState.value',
              preamble: 'class _RouteBState {\n  ',
              decl: 'String value() => label;',
              access: 'label',
              receiverType: '_RouteBState',
            ),
            granting: grants(classes: ['package:app/main.dart#_RouteBState']),
          ),
          contains('String value(dynamic self) => self.label;'),
        );
      });

      test('refuses a target in a platform library', () {
        // The value passed as `--resolve-private-names-in-library` is the
        // target's own library, so a `dart:` target would ask the front end for
        // the PLATFORM's private namespace. That is a strictly wider grant than
        // "compile as part of the library being replaced", and until 2026-08-25
        // the compiler accepted it -- measured by arm A5 of
        // `selfhost/engine/route_b/probes/p1_private_scope_controls.sh`, which
        // compiled `_GrowableList` under `--resolve-private-names-in-library
        // dart:core` and refused the same body under an app library.
        //
        // Refused here as well as in the compiler, deliberately: it holds on
        // a cell built before that fix, and it names the target instead of
        // failing somewhere inside a compile.
        expect(
          () => lowered(
            instanceCoverage(
              targetKey: 'dart:core#RouteBThing.value',
              preamble: 'class RouteBThing {\n  ',
              decl: 'String value() => label;',
              access: 'label',
            ),
          ),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.reason,
              'reason',
              contains('platform library'),
            ),
          ),
        );
      });

      test('refuses an access kind it does not know', () {
        // The analyzer and the producer are versioned together, so this should
        // be unreachable — which is why it must not be a silent fall-through
        // to an edit that happens to suit some other form.
        expect(
          () => lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: 'String value() => label;',
              access: 'label',
              kind: 'tearoff',
            ),
          ),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.reason,
              'reason',
              contains('does not know how to rewrite'),
            ),
          ),
        );
      });

      test('refuses a body the analyzer marked unsupported', () {
        expect(
          () => lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: 'String value() => label;',
              access: 'label',
              unsupported: ['calls `foo()` on the receiver'],
            ),
          ),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.reason,
              'reason',
              contains('calls `foo()` on the receiver'),
            ),
          ),
        );
      });

      test('refuses rather than guess at unusual this spacing', () {
        // `this . label` would otherwise become `this .self.label`.
        expect(
          () => lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: 'String value() => this . label;',
              access: 'this . label',
            ),
          ),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.reason,
              'reason',
              contains('cannot rewrite safely'),
            ),
          ),
        );
      });

      group('private members, against the release manifest', () {
        RouteBCoverage privateRead({String member = '_controller'}) =>
            instanceCoverage(
              preamble: 'class _RouteBState {\n  ',
              decl: 'String value() => $member;',
              access: member,
              member: member,
              receiverType: '_RouteBState',
              private: 'package:app/main.dart#_RouteBState#$member',
            );

        test('carries a granted private member, and asks the CFE for it', () {
          // Both halves. The lowering is the same edit a public read gets, and
          // the FLAG is what makes `self._controller` mean the app's member
          // rather than an unresolvable name in a synthetic library. Without it
          // the source would compile as written and bind to nothing.
          expect(
            lowered(
              privateRead(),
              granting: grants(
                instance: ['package:app/main.dart#_RouteBState#_controller'],
                classes: ['package:app/main.dart#_RouteBState'],
              ),
            ),
            contains('String value(dynamic self) => self._controller;'),
          );
          expect(
            lastArguments,
            containsAllInOrder([
              '--resolve-private-names-in-library',
              'package:app/main.dart',
            ]),
          );
        });

        test('does not ask for private resolution when nothing is private', () {
          // A REGRESSION GUARD, and the reason the flag is conditional: every
          // target already proven on device must compile under exactly the
          // arguments it did before, including on a cell that predates the
          // flag.
          lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: 'String value() => label;',
              access: 'label',
            ),
          );
          expect(
            lastArguments,
            isNot(contains('--resolve-private-names-in-library')),
          );
        });

        test('accepts a granted private member with no class grant', () {
          // ~~P3's failure.~~ **REWRITTEN 2026-08-25.** The member grant is what
          // attach needs; a class-level grant is not, and requiring one was a
          // misattribution of why P3's grants were inert (P3 never granted the
          // TARGET member, a public method of a private class). Measured in
          // `selfhost/engine/route_b/probes/p1_dead_allocatability.sh`: Cfix3
          // attaches and reads a private field with no class item anywhere,
          // Cfix -- the same grants minus the target member -- fails at ATTACH.
          //
          // Load-bearing now rather than merely correct: the generator no longer
          // emits bare private class items at all, so a release that grants no
          // constructors has an EMPTY constructible set, and the old rule would
          // refuse every private reference on every release.
          expect(
            lowered(
              privateRead(),
              granting: grants(
                instance: ['package:app/main.dart#_RouteBState#_controller'],
              ),
            ),
            contains('String value(dynamic self) => self._controller;'),
          );
        });

        test('refuses a private member the release never granted', () {
          expect(
            () => lowered(
              privateRead(),
              granting: grants(classes: ['package:app/main.dart#_RouteBState']),
            ),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                contains('which this release did not retain'),
              ),
            ),
          );
        });

        test('refuses a private member when there is no manifest at all', () {
          // No manifest is not permission. A release built before the manifest
          // existed granted nothing provable, and the alternative — assuming —
          // compiles and then throws NoSuchMethodError on a device.
          expect(
            () => lowered(privateRead()),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                contains('published no capability manifest'),
              ),
            ),
          );
        });

        test('braces a receiver access inside a simple interpolation', () {
          // FOUND ON DEVICE, 2026-08-25, and it is the silent-wrong class.
          //
          // The lowering inserts the receiver prefix immediately before the
          // identifier. In ordinary expression position that is right; inside a
          // simple `$identifier` interpolation it is not, because `'$self._x'`
          // means "interpolate self, then the literal text ._x". The patch
          // compiled, attached, executed and rendered
          //
          //   NEW-Instance of '_FooState'._field-...
          //
          // to a real screen. Nothing failed anywhere. See
          // selfhost/fixtures/privatestate_app/evidence/VERDICT.md.
          //
          // The braced form `${_x}` was always fine, which is why exactly one of
          // three accesses worked in that specimen.
          expect(
            lowered(
              instanceCoverage(
                preamble: 'class _RouteBState {\n  ',
                decl: "String value() => 'v=\$_controller';",
                access: '_controller',
                member: '_controller',
                receiverType: '_RouteBState',
                private: 'package:app/main.dart#_RouteBState#_controller',
              ),
              granting: grants(
                instance: ['package:app/main.dart#_RouteBState#_controller'],
                classes: ['package:app/main.dart#_RouteBState'],
              ),
            ),
            contains(r"'v=${self._controller}'"),
          );
        });

        test('refuses a body that CONSTRUCTS a private class', () {
          // THE PRODUCER HALF OF THE CONSTRUCTION BOUNDARY, kept as defence in
          // depth even though the generator is now the actual boundary.
          //
          // The release interface no longer grants construction implicitly --
          // `gen_dynamic_interface.dart` stopped emitting bare private `class:`
          // items, which is what used to grant every private class's public
          // constructors (measured: `p1_dead_allocatability.sh` C1). If a future
          // interface regression re-granted one, this still refuses: `_Dead()`
          // puts the private identifier `_Dead` in the body, and the gate
          // accepts a private identifier only when it is a granted ACCESS.
          //
          // Worth being explicit about why this matters more than tidiness: an
          // ungranted construction does not fail gracefully on device, it
          // ABORTS the process (`object.cc:5500 unreachable code`). There is no
          // runtime outcome to fall back on, so it has to be refused here.
          expect(
            () => lowered(
              instanceCoverage(
                preamble: 'class _RouteBState {\n  ',
                // The declared access must appear in the declaration, or the
                // helper computes a bogus offset and the arm measures nothing.
                decl: 'String value() => _controller + _Dead().toString();',
                access: '_controller',
                member: '_controller',
                receiverType: '_RouteBState',
                private: 'package:app/main.dart#_RouteBState#_controller',
              ),
              granting: grants(
                instance: ['package:app/main.dart#_RouteBState#_controller'],
                classes: ['package:app/main.dart#_RouteBState'],
              ),
            ),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                contains('_Dead'),
              ),
            ),
          );
        });

        test('refuses a private identifier the gate never saw', () {
          // THE BACKSTOP. The flag is per-compile, not per-access: once it is
          // on, `_other()` resolves too, and nothing above checked it. Refusing
          // the target is the only safe reading, because the alternative binds
          // to nothing on a device.
          expect(
            () => lowered(
              instanceCoverage(
                preamble: 'class _RouteBState {\n  ',
                decl: 'String value() => _controller + _other();',
                access: '_controller',
                member: '_controller',
                receiverType: '_RouteBState',
                private: 'package:app/main.dart#_RouteBState#_controller',
              ),
              granting: grants(
                instance: ['package:app/main.dart#_RouteBState#_controller'],
                classes: ['package:app/main.dart#_RouteBState'],
              ),
            ),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                contains('names `_other`'),
              ),
            ),
          );
        });

        test('a private name in a comment is not a reference', () {
          // The backstop must not refuse what it cannot break. A doc comment
          // naming `[_controller]` is documentation, and refusing it would make
          // the safe path punish the well-documented patch.
          expect(
            lowered(
              instanceCoverage(
                preamble: 'class _RouteBState {\n  ',
                decl:
                    '/// Reads [_absent] and [_gone].\n'
                    '  String value() => _controller;',
                access: '_controller',
                member: '_controller',
                receiverType: '_RouteBState',
                private: 'package:app/main.dart#_RouteBState#_controller',
              ),
              granting: grants(
                instance: ['package:app/main.dart#_RouteBState#_controller'],
                classes: ['package:app/main.dart#_RouteBState'],
              ),
            ),
            contains('String value(dynamic self) => self._controller;'),
          );
        });

        test('a private name inside an interpolation IS a reference', () {
          // The other side of the same rule, and the reason strings are not
          // masked wholesale: `'${_other}'` is a real reference wearing a
          // string's clothes.
          expect(
            () => lowered(
              instanceCoverage(
                preamble: 'class _RouteBState {\n  ',
                decl: r"String value() => '${_other} $_controller';",
                access: '_controller',
                member: '_controller',
                receiverType: '_RouteBState',
                private: 'package:app/main.dart#_RouteBState#_controller',
              ),
              granting: grants(
                instance: ['package:app/main.dart#_RouteBState#_controller'],
                classes: ['package:app/main.dart#_RouteBState'],
              ),
            ),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                contains('names `_other`'),
              ),
            ),
          );
        });
      });
    });

    group('P4.1 survival gate', () {
      RouteBSurvivalOracle oracle(
        RouteBSurvival survival, {
        String instrument = 'ZERO_QUALIFYING_CALLSITES',
        String? detail,
      }) {
        return (targets) => {
          for (final t in targets)
            t: RouteBSurvivalVerdict(
              survival: survival,
              instrumentResult: instrument,
              detail: detail,
            ),
        };
      }

      Uint8List produceWith(RouteBSurvivalOracle? survival) => runWithOverrides(
        () => const RouteBProducer().produce(
          compiler: compiler(),
          coverage: coverage(),
          importKernel: File(p.join(cell.path, 'release_import.dill')),
          releaseBuildId: 'deadbeef',
          workingDirectory: work,
          projectRoot: project,
          survival: survival,
          run: compileOk,
        ),
      );

      test('publishes when a call site survived', () {
        expect(
          () => produceWith(oracle(
            RouteBSurvival.survivingCallsite,
            instrument: 'ONE_OR_MORE_QUALIFYING_CALLSITES',
          )),
          returnsNormally,
        );
      });

      test('refuses authoritative absence, and says the release is why', () {
        // The target exists and every call to it was folded away. A patch would
        // attach, report success, and change nothing -- so this must be caught
        // here, where the reason can still be explained.
        expect(
          () => produceWith(oracle(RouteBSurvival.noSurvivingCallsite)),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.toString(),
              'message',
              allOf(
                contains('no surviving call site'),
                contains('attach and change nothing'),
                contains('remediation is a new release'),
              ),
            ),
          ),
        );
      });

      test('refuses UNKNOWN, and does NOT call it absence', () {
        // The distinction is the whole point: "the call site is gone" and "I
        // could not tell" refuse for different reasons and are fixed by
        // different actions. Collapsing them would send an operator to cut a
        // pointless release over a broken instrument.
        expect(
          () => produceWith(
            oracle(
              RouteBSurvival.unknown,
              instrument: 'ARTIFACT_BINDING_MISMATCH',
              detail: 'the profile describes a different artifact',
            ),
          ),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.toString(),
              'message',
              allOf(
                contains('could not be established'),
                contains('ARTIFACT_BINDING_MISMATCH'),
                contains('NOT a finding that the call site is absent'),
                isNot(contains('attach and change nothing')),
              ),
            ),
          ),
        );
      });

      test('an unanswered target is refused, not assumed green', () {
        // An oracle that returns nothing at all is the shape a silently broken
        // gate takes. It must refuse.
        expect(
          () => produceWith((targets) => const {}),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.toString(),
              'message',
              contains('returned no verdict'),
            ),
          ),
        );
      });

      test('MUTATION: with no oracle at all, a folded target publishes', () {
        // The mutation the gate exists to fail: remove it, and the very target
        // the P4.1 specimen set proved inert sails through to publication. If
        // this ever stops passing, the test above is no longer proving the gate
        // is load-bearing -- it would be proving something else.
        expect(() => produceWith(null), returnsNormally);
      });
    });

    test('refuses a target the analysis gave no span for', () {
      expect(
        () => runWithOverrides(
          () => const RouteBProducer().produce(
            compiler: compiler(),
            coverage: coverage(sources: const {}),
            importKernel: File(p.join(cell.path, 'release_import.dill')),
            releaseBuildId: 'deadbeef',
            workingDirectory: work,
            projectRoot: project,
            run: compileOk,
          ),
        ),
        throwsA(
          isA<RouteBUnsupportedTarget>().having(
            (e) => e.reason,
            'reason',
            contains('no source span'),
          ),
        ),
      );
    });

    test('reports a compiler refusal as its own kind of failure', () {
      // Coverage already said this target CAN be carried, so a failure here is
      // the toolchain's. Conflating it with a coverage rejection sends someone
      // to change their Dart when the problem is the compiler.
      expect(
        () => runWithOverrides(
          () => const RouteBProducer().produce(
            compiler: compiler(),
            coverage: coverage(),
            importKernel: File(p.join(cell.path, 'release_import.dill')),
            releaseBuildId: 'deadbeef',
            workingDirectory: work,
            projectRoot: project,
            run: (_, _) => ProcessResult(0, 1, '', 'boom'),
          ),
        ),
        throwsA(
          isA<RouteBUnsupportedTarget>().having(
            (e) => e.reason,
            'reason',
            allOf(contains('bytecode compiler refused'), contains('boom')),
          ),
        ),
      );
    });

    test('slices by code units, not bytes', () {
      // The kernel's offsets index the DECODED source. Byte-slicing drifts by
      // the UTF-8 overhead of everything before the declaration; on the real
      // fixture three non-ASCII characters in the comments above the function
      // put the slice 6 bytes early and produced a replacement library that
      // began mid-word and ended before its closing `;`.
      const preamble = '// em dashes — — — before the declaration\n';
      source.writeAsStringSync('$preamble$declaration');
      final start = preamble.length; // code units, as the kernel reports

      runWithOverrides(
        () => const RouteBProducer().produce(
          compiler: compiler(),
          coverage: coverage(
            sources: {
              'package:app/main.dart#routeBValue': {
                'fileUri': source.uri.toString(),
                'start': start,
                'end': start + declaration.length,
              },
            },
          ),
          importKernel: File(p.join(cell.path, 'release_import.dill')),
          releaseBuildId: 'deadbeef',
          workingDirectory: work,
          projectRoot: project,
          run: compileOk,
        ),
      );

      expect(
        File(p.join(work.path, 'replacement_0.dart')).readAsStringSync(),
        "import 'package:app/main.dart';\n\n"
        '${RouteBProducer.entryPointPragma}\n$declaration\n',
      );
    });

    test('refuses a span that runs past the end of its file', () {
      expect(
        () => runWithOverrides(
          () => const RouteBProducer().produce(
            compiler: compiler(),
            coverage: coverage(
              sources: {
                'package:app/main.dart#routeBValue': {
                  'fileUri': source.uri.toString(),
                  'start': 0,
                  'end': 100000,
                },
              },
            ),
            importKernel: File(p.join(cell.path, 'release_import.dill')),
            releaseBuildId: 'deadbeef',
            workingDirectory: work,
            projectRoot: project,
            run: compileOk,
          ),
        ),
        throwsA(
          isA<RouteBUnsupportedTarget>().having(
            (e) => e.reason,
            'reason',
            contains('runs past the end'),
          ),
        ),
      );
    });
  });
}
