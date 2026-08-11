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
