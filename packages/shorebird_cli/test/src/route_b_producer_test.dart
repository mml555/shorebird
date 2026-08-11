import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_container.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
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
        String member = 'label',
        String kind = 'get',
        List<String> unsupported = const [],
      }) {
        source.writeAsStringSync('$preamble$decl');
        final start = preamble.length;
        return RouteBCoverage.fromJson(
          jsonEncode({
            'analysisVersion': supportedRouteBAnalysisVersion,
            'verdict': 'accept',
            'changed': [key],
            'added': <String>[],
            'removed': <String>[],
            'patchable': <String>[],
            'conditional': [key],
            'sources': {
              key: {
                'fileUri': source.uri.toString(),
                'start': start,
                'end': start + decl.length,
              },
            },
            'lowering': {
              key: {
                'receiverType': 'RouteBThing',
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

      String lowered(RouteBCoverage coverage) {
        runWithOverrides(
          () => const RouteBProducer().produce(
            compiler: compiler(),
            coverage: coverage,
            importKernel: File(p.join(cell.path, 'release_import.dill')),
            releaseBuildId: 'deadbeef',
            workingDirectory: work,
            projectRoot: project,
            run: compileOk,
          ),
        );
        return File(p.join(work.path, 'replacement_0.dart')).readAsStringSync();
      }

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

      test('refuses a call written with arguments', () {
        // The ANALYZER cannot answer this. `gen_kernel --aot` eliminates a
        // parameter whose argument is always the same constant, so the release
        // kernel reports such a call as zero-argument and the target's own
        // signature reports no parameters. Measured, not assumed. The source is
        // what still says otherwise.
        expect(
          () => lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: "String value() => helper('x');",
              access: 'helper',
              member: 'helper',
              kind: 'invoke',
            ),
          ),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.reason,
              'reason',
              contains('with arguments'),
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
