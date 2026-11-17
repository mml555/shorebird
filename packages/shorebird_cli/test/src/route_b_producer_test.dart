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
import 'package:shorebird_cli/src/route_b_producer.dart';
import 'package:shorebird_cli/src/route_b_retention.dart';
import 'package:shorebird_cli/src/route_b_survival.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'mocks.dart';

void main() {
  useTempWorkingDirectory();
  group(RouteBProducer, () {
    late Directory cell;
    late Directory work;
    late Directory project;
    late File source;
    late ShorebirdLogger logger;

    const declaration = "String routeBValue() => 'NEW';";

    RouteBCompiler compiler({bool dualKernel = true}) => RouteBCompiler(
      supportsDirectSuperDualKernel: dualKernel,
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
      Map<String, Object?>? lowering,
      Map<String, List<String>>? callers,
      // Makes this an analysis-18 document that lists these references per
      // target, which is what turns the retention check on.
      Map<String, List<Map<String, Object?>>>? externalReferences,
      int? analysisVersion,
    }) => RouteBCoverage.fromJson(
      jsonEncode({
        'analysisVersion':
            analysisVersion ??
            (externalReferences != null
                ? routeBRetentionAnalysisVersion
                : callers == null
                ? supportedRouteBAnalysisVersion
                : routeBCarryAnalysisVersion),
        if (externalReferences != null) ...{
          'carried': <String>[],
          'callers': <String, List<String>>{},
          'helpers': <String>[],
          'unusedHelpers': <String>[],
          'externalReferences': externalReferences,
        } else if (callers != null) ...{
          'carried': <String>[],
          'callers': callers,
        },
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
        'lowering': ?lowering,
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

    test('a compile error names what the compiler printed on stdout', () {
      // dart2bytecode reports front-end errors on stdout, not stderr.
      expect(
        () => runWithOverrides(
          () => const RouteBProducer().produce(
            compiler: compiler(),
            coverage: coverage(),
            releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
            releaseBuildId: 'deadbeef',
            workingDirectory: work,
            projectRoot: project,
            run: (_, _) => ProcessResult(
              0,
              254,
              "replacement_0.dart:3:30: Error: Can't access 'this' here.\n",
              '',
            ),
          ),
        ),
        throwsA(
          isA<RouteBUnsupportedTarget>().having(
            (e) => e.reason,
            'reason',
            allOf(
              contains('(exit 254)'),
              contains("Error: Can't access 'this' here."),
            ),
          ),
        ),
      );
    });

    group('an entry point the compiler cannot take', () {
      // e07 (a generic function), e25 and E17 (named parameters) reached
      // dart2bytecode and came back as a raw front-end stack trace.
      const key = 'package:app/main.dart#routeBValue';

      test('a generic function is refused in words', () {
        expect(
          routeBEntryShapeProblem(
            key,
            'T routeBValue<T>(List<T> xs, T fallback) => xs.first;',
          ),
          allOf(contains('generic function'), contains('Cut a new release')),
        );
      });

      test('named, optional and required parameters', () {
        expect(
          routeBEntryShapeProblem(
            key,
            "String routeBValue(int n, {String sep = ''}) => 'x';",
          ),
          allOf(contains('named parameters'), contains('Cut a new release')),
        );
        expect(
          routeBEntryShapeProblem(
            key,
            "String routeBValue([int n = 0]) => '';",
          ),
          contains('optional positional parameters'),
        );
        expect(
          routeBEntryShapeProblem(
            key,
            "String routeBValue(int n, List<String> xs) => 'x';",
          ),
          isNull,
        );
        expect(
          routeBEntryShapeProblem(key, "String routeBValue() => '';"),
          isNull,
        );
      });

      test('reads past defaults, strings and nested brackets', () {
        expect(
          routeBEntryShapeProblem(
            key,
            'String routeBValue(Map<String, List<int>> m, '
            "Function(int, [int]) f, String s) => ', {[';",
          ),
          isNull,
        );
        expect(
          routeBEntryShapeProblem(
            key,
            "String routeBValue(String a, [String b = 'x, {']) => a;",
          ),
          contains('optional positional'),
        );
      });

      test('an annotation or comment ahead of the signature is not it', () {
        // The first `routeBValue(` in the raw text is inside the annotation's
        // string; it closes at the first `)` and used to read as "no params".
        expect(
          routeBEntryShapeProblem(
            key,
            "@Deprecated('use routeBValue(x)') "
            "String routeBValue(int n, {String sep = ''}) => 'x';",
          ),
          contains('named parameters'),
        );
        expect(
          routeBEntryShapeProblem(
            key,
            "@pragma('vm:never-inline')\n"
            '// routeBValue(int n) is the old shape\n'
            "String routeBValue({int n = 0}) => '';",
          ),
          contains('named parameters'),
        );
        expect(
          routeBEntryShapeProblem(
            key,
            '/* routeBValue<T>() */ String routeBValue(int n) => "x";',
          ),
          isNull,
        );
      });

      test('a comment inside the signature cannot derail the scan', () {
        expect(
          routeBEntryShapeProblem(
            key,
            "String routeBValue(int n, // don't use {x}\n"
            "    {String sep = ''}) => 'x';",
          ),
          contains('named parameters'),
        );
        expect(
          routeBEntryShapeProblem(
            key,
            'String routeBValue(int n, /* [ { ( */ int m) => "x";',
          ),
          isNull,
        );
      });

      test('raw strings, triple quotes and interpolation are skipped', () {
        expect(
          routeBEntryShapeProblem(
            key,
            r"String routeBValue(String a, {String b = r'\'}) => a;",
          ),
          contains('named parameters'),
        );
        expect(
          routeBEntryShapeProblem(
            key,
            r"String routeBValue(String a) => '''x (${a + ')'}) {''';",
          ),
          isNull,
        );
      });

      test('says nothing for accessors or a declaration it cannot find', () {
        expect(
          routeBEntryShapeProblem(
            'package:app/main.dart#get:routeBValue',
            'String get routeBValue => x;',
          ),
          isNull,
        );
        expect(routeBEntryShapeProblem(key, 'int other() => 1;'), isNull);
        expect(routeBEntryShapeProblem('package:app/main.dart#', 'x'), isNull);
      });

      test('a static method is read by its own name', () {
        expect(
          routeBEntryShapeProblem(
            'package:app/main.dart#Box.make',
            'static Box make<T>(T v) => Box();',
          ),
          contains('`make<...>`'),
        );
      });

      test('produce refuses the target before the compiler runs', () {
        source.writeAsStringSync("String routeBValue({int n = 0}) => 'NEW';");
        var compiled = false;
        expect(
          () => runWithOverrides(
            () => const RouteBProducer().produce(
              compiler: compiler(),
              coverage: coverage(
                sources: {
                  key: {
                    'fileUri': source.uri.toString(),
                    'start': 0,
                    'end': source.lengthSync(),
                  },
                },
              ),
              releaseImportKernel: File(
                p.join(cell.path, 'release_import.dill'),
              ),
              releaseBuildId: 'deadbeef',
              workingDirectory: work,
              projectRoot: project,
              run: (e, a) {
                compiled = true;
                return compileOk(e, a);
              },
            ),
          ),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.reason,
              'reason',
              contains('named parameters'),
            ),
          ),
        );
        expect(compiled, isFalse);
      });
    });

    group('a top-level target naming a private top-level function', () {
      // G5. The replacement is its own synthetic library, so `_fmt` is not in
      // scope there without --resolve-private-names-in-library, and the compile
      // died with "Method not found: '_fmt'".
      const target = 'package:app/main.dart#routeBValue';
      const privateFmt = 'package:app/main.dart#_fmt';

      Map<String, Object?> reference({
        bool private = true,
        String member = '_fmt',
        bool viaConstant = false,
      }) => {
        'kind': 'top-level',
        'library': 'package:app/main.dart',
        'class': null,
        'member': member,
        'private': private,
        if (viaConstant) 'viaConstant': true,
      };

      List<String> compileArguments({
        required List<Map<String, Object?>> references,
        List<String> granted = const [privateFmt],
        bool withManifest = true,
      }) {
        var arguments = <String>[];
        final capabilities = RouteBCapabilities.fromJson(
          jsonEncode({
            'policy': 'p2',
            'privateTopLevelCallable': granted,
          }),
        );
        runWithOverrides(
          () => const RouteBProducer().produce(
            compiler: compiler(),
            coverage: coverage(externalReferences: {target: references}),
            releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
            releaseBuildId: 'deadbeef',
            workingDirectory: work,
            projectRoot: project,
            capabilities: withManifest ? capabilities : null,
            retention: RouteBRetention.parse(
              '''
callable:
  - library: 'package:app/main.dart'
  - library: 'package:app/main.dart'
    member: '_fmt'
''',
              capabilities: capabilities,
            ),
            run: (executable, args) {
              arguments = args;
              return compileOk(executable, args);
            },
          ),
        );
        return arguments;
      }

      test('asks the CFE to resolve the private name the manifest grants', () {
        expect(
          compileArguments(references: [reference()]),
          containsAllInOrder([
            '--resolve-private-names-in-library',
            'package:app/main.dart',
          ]),
        );
      });

      test('does not ask when the target names no private top-level', () {
        expect(
          compileArguments(
            references: [reference(private: false, member: 'fmt')],
            granted: const [],
          ),
          isNot(contains('--resolve-private-names-in-library')),
        );
      });

      test('does not ask for a private name only a constant names', () {
        expect(
          compileArguments(references: [reference(viaConstant: true)]),
          isNot(contains('--resolve-private-names-in-library')),
        );
      });

      test('does not ask for a private name the manifest lists elsewhere', () {
        // Retention refuses an ungranted private name before this is asked, so
        // the only way to reach the predicate without a grant for THIS name is
        // an unrelated grant.
        expect(
          () => compileArguments(
            references: [reference()],
            granted: const ['package:app/main.dart#_other'],
          ),
          throwsA(isA<RouteBUnsupportedTarget>()),
        );
      });
    });

    group('the compiled replacement checks an `inlined` claim', () {
      const target = 'package:app/main.dart#routeBValue';

      Map<String, Object?> plus({bool inlined = true}) => {
        'kind': 'instance',
        'library': 'dart:core',
        'class': 'int',
        'member': '+',
        'private': false,
        if (inlined) 'inlined': 'AddInt',
      };

      /// Produces the target with [references], the scan answering [scan]
      /// (null: the analyzer exits non-zero). Returns how many scans ran.
      int produceWith(
        List<Map<String, Object?>> references, {
        String? scan,
        int analysisVersion = 21,
      }) {
        var scans = 0;
        runWithOverrides(
          () => const RouteBProducer().produce(
            compiler: compiler(),
            coverage: coverage(
              externalReferences: {target: references},
              analysisVersion: analysisVersion,
            ),
            releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
            releaseBuildId: 'deadbeef',
            workingDirectory: work,
            projectRoot: project,
            // Nothing measured: an SDK operator is refused unless flagged.
            retention: RouteBRetention.parse(
              "callable:\n  - library: 'package:app/main.dart'\n",
              measuredAccepted: const {},
              measuredFailing: const {},
              measuredVmClasses: const {},
            ),
            run: (executable, args) {
              if (args.contains('--scan-bytecode')) {
                scans++;
                return scan == null
                    ? ProcessResult(0, 1, '', 'no such mode')
                    : ProcessResult(0, 0, 'noise\n$scan\n', '');
              }
              return compileOk(executable, args);
            },
          ),
        );
        return scans;
      }

      test('keeps the flag when the bytecode has no call by that name', () {
        expect(
          produceWith([plus()], scan: '{"functions":1,"calls":["-"]}'),
          1,
        );
      });

      test('drops the flag, and so refuses, for a call by that name', () {
        expect(
          () => produceWith([plus()], scan: '{"functions":1,"calls":["+"]}'),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.reason,
              'reason',
              allOf(
                contains('int.+'),
                contains('still looks it up by name'),
              ),
            ),
          ),
        );
      });

      test('drops the flag when the bytecode cannot be read', () {
        for (final scan in [
          null,
          '{"functions":0,"calls":[]}',
          'not json',
          '{"calls":[]}',
        ]) {
          expect(
            () => produceWith([plus()], scan: scan),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                contains('could not be read'),
              ),
            ),
            reason: '$scan',
          );
        }
      });

      test('reads nothing when no reference is flagged', () {
        // The ordinary refusal stands, and there is nothing to check.
        expect(
          () => produceWith([plus(inlined: false)]),
          throwsA(isA<RouteBUnsupportedTarget>()),
        );
        expect(produceWith(const []), 0);
      });

      test('a document below 21 has no flag to check', () {
        expect(
          () => produceWith([plus()], analysisVersion: 20),
          throwsA(isA<RouteBUnsupportedTarget>()),
        );
      });
    });

    group('a top-level helper naming a private identifier', () {
      const libA = 'package:app/main.dart';
      const libB = 'package:app/other.dart';
      const entry = 'String routeBValue() => _g(1) + _x();';
      const g = 'String _g(dynamic o) => o._x;';
      const x = "String _x() => 'X';";
      final text = [entry, g, x].join('\n');

      Map<String, Object?> span(String piece) => {
        'fileUri': source.uri.toString(),
        'start': text.indexOf(piece),
        'end': text.indexOf(piece) + piece.length,
      };

      RouteBCoverage coverage({required List<String> gCalls}) {
        source.writeAsStringSync(text);
        return RouteBCoverage.fromJson(
          jsonEncode({
            'analysisVersion': routeBHelpersAnalysisVersion,
            'verdict': 'accept',
            'changed': ['$libA#routeBValue'],
            'carried': <String>[],
            'callers': {
              '$libA#_g': ['$libA#routeBValue'],
              '$libB#_x': ['$libA#routeBValue', ...gCalls],
            },
            'added': ['$libA#_g', '$libB#_x'],
            'helpers': ['$libA#_g', '$libB#_x'],
            'unusedHelpers': <String>[],
            'removed': <String>[],
            'patchable': ['$libA#routeBValue'],
            'conditional': <String>[],
            'sources': {
              '$libA#routeBValue': span(entry),
              '$libA#_g': span(g),
              '$libB#_x': span(x),
            },
            'rejections': <Object>[],
            'refusalSummary': null,
          }),
        );
      }

      String produce(RouteBCoverage c) {
        runWithOverrides(
          () => const RouteBProducer().produce(
            compiler: compiler(),
            coverage: c,
            releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
            releaseBuildId: 'deadbeef',
            workingDirectory: work,
            projectRoot: project,
            run: compileOk,
          ),
        );
        return File(p.join(work.path, 'replacement_0.dart')).readAsStringSync();
      }

      test("refuses a private name that is another library's helper, not "
          'one this helper calls', () {
        expect(
          () => produce(coverage(gCalls: const [])),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.reason,
              'reason',
              contains('`_x`, a private identifier that is not a new function'),
            ),
          ),
        );
      });

      test('takes a private name of a helper it does call', () {
        expect(
          produce(coverage(gCalls: ['$libA#_g'])),
          contains('String _g(dynamic o) => o._x;'),
        );
      });
    });

    group('helpers (analysis version 16)', () {
      const lib = 'package:app/main.dart';
      const entry = 'String routeBValue() => helperA();';
      const helperA = 'String helperA() => helperB();';
      const helperB = "String helperB() => 'NEW';";
      const unused = "String unusedOne() => 'u';";
      const other = 'String routeBOther() => helperB();';
      final text = [entry, helperA, helperB, unused, other].join('\n');

      Map<String, Object?> span(String piece) => {
        'fileUri': source.uri.toString(),
        'start': text.indexOf(piece),
        'end': text.indexOf(piece) + piece.length,
      };

      RouteBCoverage withHelpers({
        List<String> targets = const ['$lib#routeBValue'],
        Map<String, Object?>? extraSources,
        String entryText = entry,
      }) {
        source.writeAsStringSync(text);
        return RouteBCoverage.fromJson(
          jsonEncode({
            'analysisVersion': routeBHelpersAnalysisVersion,
            'verdict': 'accept',
            'changed': targets,
            'carried': <String>[],
            'callers': {
              '$lib#helperA': ['$lib#routeBValue'],
              '$lib#helperB': ['$lib#helperA', '$lib#routeBOther'],
              '$lib#unusedOne': <String>[],
            },
            'added': ['$lib#helperA', '$lib#helperB', '$lib#unusedOne'],
            'helpers': ['$lib#helperA', '$lib#helperB'],
            'unusedHelpers': ['$lib#unusedOne'],
            'removed': <String>[],
            'patchable': targets,
            'conditional': <String>[],
            'sources': {
              '$lib#routeBValue': span(entryText),
              '$lib#routeBOther': span(other),
              '$lib#helperA': span(helperA),
              '$lib#helperB': span(helperB),
              '$lib#unusedOne': span(unused),
              ...?extraSources,
            },
            'rejections': <Object>[],
            'refusalSummary': null,
          }),
        );
      }

      String produceFor(RouteBCoverage coverage, [int index = 0]) {
        runWithOverrides(
          () => const RouteBProducer().produce(
            compiler: compiler(),
            coverage: coverage,
            releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
            releaseBuildId: 'deadbeef',
            workingDirectory: work,
            projectRoot: project,
            run: compileOk,
          ),
        );
        return File(
          p.join(work.path, 'replacement_$index.dart'),
        ).readAsStringSync();
      }

      test('appends what the target reaches, after the entry, in order', () {
        final generated = produceFor(withHelpers());
        expect(
          generated,
          endsWith(
            '${RouteBProducer.entryPointPragma}\n$entry\n\n$helperA\n\n'
            '$helperB\n',
          ),
        );
      });

      test('never puts the entry-point pragma on a helper', () {
        final generated = produceFor(withHelpers());
        expect(
          RouteBProducer.entryPointPragma.allMatches(generated),
          hasLength(1),
        );
      });

      test('leaves out a helper nothing in the patch reaches', () {
        expect(produceFor(withHelpers()), isNot(contains('unusedOne')));
      });

      test('gives each target its own copy of a shared helper', () {
        final coverage = withHelpers(
          targets: ['$lib#routeBOther', '$lib#routeBValue'],
        );
        // Sorted: routeBOther is replacement_0, routeBValue replacement_1.
        final first = produceFor(coverage);
        final second = produceFor(coverage, 1);
        expect(first, endsWith('$other\n\n$helperB\n'));
        expect(first, isNot(contains('helperA')));
        expect(second, contains(helperB));
        expect(second, contains(helperA));
      });

      test('a target needing no helper is unchanged by their presence', () {
        final coverage = withHelpers(
          targets: ['$lib#routeBOther'],
        );
        expect(
          produceFor(coverage),
          isNot(contains('String helperA')),
        );
      });

      test('refuses a helper with no source span', () {
        final coverage = RouteBCoverage.fromJson(
          jsonEncode({
            'analysisVersion': routeBHelpersAnalysisVersion,
            'verdict': 'accept',
            'changed': ['$lib#routeBValue'],
            'carried': <String>[],
            'callers': {
              '$lib#helperA': ['$lib#routeBValue'],
            },
            'added': ['$lib#helperA'],
            'helpers': ['$lib#helperA'],
            'unusedHelpers': <String>[],
            'removed': <String>[],
            'patchable': ['$lib#routeBValue'],
            'conditional': <String>[],
            'sources': {'$lib#routeBValue': span(entry)},
            'rejections': <Object>[],
            'refusalSummary': null,
          }),
        );
        source.writeAsStringSync(text);
        expect(
          () => produceFor(coverage),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.reason,
              'reason',
              contains('no source span'),
            ),
          ),
        );
      });

      test('a helper reading the compile-time environment is refused on a '
          'release that predates the defines record', () {
        const reader = "String helperB() => const String.fromEnvironment('X');";
        final body = [entry, helperA, reader].join('\n');
        source.writeAsStringSync(body);
        Map<String, Object?> at(String piece) => {
          'fileUri': source.uri.toString(),
          'start': body.indexOf(piece),
          'end': body.indexOf(piece) + piece.length,
        };
        final coverage = RouteBCoverage.fromJson(
          jsonEncode({
            'analysisVersion': routeBHelpersAnalysisVersion,
            'verdict': 'accept',
            'changed': ['$lib#routeBValue'],
            'carried': <String>[],
            'callers': {
              '$lib#helperA': ['$lib#routeBValue'],
              '$lib#helperB': ['$lib#helperA'],
            },
            'added': ['$lib#helperA', '$lib#helperB'],
            'helpers': ['$lib#helperA', '$lib#helperB'],
            'unusedHelpers': <String>[],
            'removed': <String>[],
            'patchable': ['$lib#routeBValue'],
            'conditional': <String>[],
            'sources': {
              '$lib#routeBValue': at(entry),
              '$lib#helperA': at(helperA),
              '$lib#helperB': at(reader),
            },
            'rejections': <Object>[],
            'refusalSummary': null,
          }),
        );
        expect(
          () => runWithOverrides(
            () => const RouteBProducer().produce(
              compiler: compiler(),
              coverage: coverage,
              releaseImportKernel: File(
                p.join(cell.path, 'release_import.dill'),
              ),
              releaseBuildId: 'deadbeef',
              workingDirectory: work,
              projectRoot: project,
              buildConfig: RouteBBuildConfig.fromJson(<String, dynamic>{
                'rawArgs': <String>[],
                'effectiveDefines': <String, String>{},
              }),
              run: compileOk,
            ),
          ),
          throwsA(isA<RouteBUnsupportedTarget>()),
        );
      });

      group('for an instance target', () {
        const instanceKey = '$lib#RouteBThing.value';

        RouteBCoverage instance(
          String helperName,
          String helperText, {
          String receiver = 'RouteBThing',
          String decl = 'String value() => label;',
          int version = routeBHelpersAnalysisVersion,
        }) {
          final body = 'class $receiver {\n  $decl\n}\n$helperText\n';
          source.writeAsStringSync(body);
          Map<String, Object?> at(String piece) => {
            'fileUri': source.uri.toString(),
            'start': body.indexOf(piece),
            'end': body.indexOf(piece) + piece.length,
          };
          return RouteBCoverage.fromJson(
            jsonEncode({
              'analysisVersion': version,
              'verdict': 'accept',
              'changed': [instanceKey],
              'carried': <String>[],
              'callers': {
                '$lib#$helperName': [instanceKey],
              },
              'added': ['$lib#$helperName'],
              'helpers': ['$lib#$helperName'],
              'unusedHelpers': <String>[],
              'removed': <String>[],
              'patchable': <String>[],
              'conditional': [instanceKey],
              'sources': {
                instanceKey: at(decl),
                '$lib#$helperName': at(helperText),
              },
              'lowering': {
                instanceKey: {
                  'receiverType': receiver,
                  'nameOffset': body.indexOf('value'),
                  'accesses': [
                    {
                      'offset': body.indexOf('label'),
                      'member': 'label',
                      'kind': 'get',
                    },
                  ],
                  'unsupported': <String>[],
                  'privateConstructions': <Object>[],
                },
              },
              'rejections': <Object>[],
              'refusalSummary': null,
            }),
          );
        }

        test('takes a public helper', () {
          expect(
            produceFor(instance('rbH', "String rbH() => 'H';")),
            contains("String rbH() => 'H';"),
          );
        });

        test('takes a private helper when no private name resolves against '
            'the release', () {
          expect(
            produceFor(instance('_rbH', "String _rbH() => 'H';")),
            contains("String _rbH() => 'H';"),
          );
        });

        test('takes a private helper the method body names', () {
          final out = produceFor(
            instance(
              '_rbH',
              'String _rbH(String l) => l;',
              decl: 'String value() => _rbH(label);',
            ),
          );
          expect(out, contains('String _rbH(String l) => l;'));
          expect(out, contains('_rbH(self.label)'));
        });

        test('takes a private helper the method body names when the target '
            'resolves private names against the release (version 17)', () {
          final out = produceFor(
            instance(
              '_rbH',
              'String _rbH(String l) => l;',
              decl: 'String value() => _rbH(label);',
              receiver: '_RouteBThing',
              version: routeBInstanceHelpersAnalysisVersion,
            ),
          );
          expect(out, contains('String _rbH(String l) => l;'));
          expect(out, contains('_rbH(self.label)'));
        });

        test('refuses a helper naming a private identifier that is not a '
            'helper, even when private names resolve in the replacement', () {
          expect(
            () => produceFor(
              instance('rbH', 'String rbH(dynamic d) => d._secret;'),
            ),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                contains(
                  '`_secret`, a private identifier that is not a new '
                  'function this patch carries',
                ),
              ),
            ),
          );
        });

        test('refuses a helper annotated as an entry point', () {
          expect(
            () => produceFor(
              instance(
                'rbH',
                "@pragma('dyn-module:entry-point')\nString rbH() => 'H';",
              ),
            ),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                contains('dynamic module entry point'),
              ),
            ),
          );
        });

        test(
          'takes a private helper under a private receiver (version 17)',
          () {
            expect(
              produceFor(
                instance(
                  '_rbH',
                  "String _rbH() => 'H';",
                  receiver: '_RouteBThing',
                  version: routeBInstanceHelpersAnalysisVersion,
                ),
              ),
              contains("String _rbH() => 'H';"),
            );
          },
        );

        test('a version 16 document keeps refusing a private helper under a '
            'private receiver', () {
          for (final (helperName, text) in [
            ('_rbH', "String _rbH() => 'H';"),
            ('rbH', 'String rbH() => _rbOther();'),
          ]) {
            expect(
              () => produceFor(
                instance(
                  helperName,
                  text,
                  receiver: '_RouteBThing',
                ),
              ),
              throwsA(
                isA<RouteBUnsupportedTarget>().having(
                  (e) => e.reason,
                  'reason',
                  contains('Make the helper public'),
                ),
              ),
            );
          }
        });

        test('refuses a public helper that names a private identifier', () {
          expect(
            () => produceFor(
              instance(
                'rbH',
                "String rbH() { var _x = 'H'; return _x; }",
                receiver: '_RouteBThing',
              ),
            ),
            throwsA(isA<RouteBUnsupportedTarget>()),
          );
        });
      });

      group('an instance helper (analysis version 17)', () {
        const targetKey = '$lib#RouteBThing.value';

        /// `class RouteBThing { <decl> <helper> }`, analyzed as the version 17
        /// analyzer would: the call is a `helperCall` access, and the helper
        /// has a lowering of its own.
        RouteBCoverage v17({
          String decl = 'String value() => _h(label);',
          String helper = 'String _h(String l) => l + label;',
          String callName = '_h',
          int version = routeBInstanceHelpersAnalysisVersion,
          String receiver = 'RouteBThing',
          List<Object> helperUnsupported = const [],
          List<Object> helperAccesses = const [],
          List<Object> helperSupers = const [],
          Map<String, Object?>? extra,
        }) {
          final helperKey = '$lib#RouteBThing.$callName';
          final body = 'class RouteBThing {\n  $decl\n  $helper\n}\n';
          source.writeAsStringSync(body);
          Map<String, Object?> at(String piece) => {
            'fileUri': source.uri.toString(),
            'start': body.indexOf(piece),
            'end': body.indexOf(piece) + piece.length,
          };
          final declAt = body.indexOf(decl);
          final helperAt = body.indexOf(helper);
          return RouteBCoverage.fromJson(
            jsonEncode({
              'analysisVersion': version,
              'verdict': 'accept',
              'changed': [targetKey],
              'carried': <String>[],
              'callers': {
                helperKey: [targetKey],
              },
              'added': [helperKey],
              'helpers': [helperKey],
              'unusedHelpers': <String>[],
              'removed': <String>[],
              'patchable': <String>[],
              'conditional': [targetKey],
              'sources': {targetKey: at(decl), helperKey: at(helper)},
              'lowering': {
                targetKey: {
                  'receiverType': receiver,
                  'nameOffset': body.indexOf('value'),
                  'accesses': [
                    {
                      'offset': declAt + decl.indexOf(callName),
                      'member': callName,
                      'kind': 'helperCall',
                    },
                    if (decl.contains('label'))
                      {
                        'offset': declAt + decl.indexOf('label'),
                        'member': 'label',
                        'kind': 'get',
                      },
                  ],
                  'unsupported': <String>[],
                  'privateConstructions': <Object>[],
                },
                helperKey: {
                  'receiverType': receiver,
                  'nameOffset': helperAt + helper.indexOf(callName),
                  'accesses': [
                    if (helper.contains('label'))
                      {
                        'offset': helperAt + helper.indexOf('label'),
                        'member': 'label',
                        'kind': 'get',
                      },
                    ...helperAccesses,
                  ],
                  'unsupported': helperUnsupported,
                  'superInvocations': helperSupers,
                  'privateConstructions': <Object>[],
                },
              },
              ...?extra,
              'rejections': <Object>[],
              'refusalSummary': null,
            }),
          );
        }

        test('passes the receiver to the call and lowers the helper', () {
          final out = produceFor(v17());
          expect(
            out,
            contains(
              'String value(RouteBThing self) => _h(self, self.label);',
            ),
          );
          expect(
            out,
            contains(
              'String _h(RouteBThing self, String l) => l + self.label;',
            ),
          );
          // One entry point, and it is the target's.
          expect(RegExp('entry-point').allMatches(out), hasLength(1));
        });

        test('a call with no arguments is passed only the receiver', () {
          final out = produceFor(
            v17(
              decl: 'String value() => _h();',
              helper: 'String _h() => label;',
            ),
          );
          expect(out, contains('String value(RouteBThing self) => _h(self);'));
          expect(out, contains('String _h(RouteBThing self) => self.label;'));
        });

        test('`this._h()` loses its `this.` and `this.label` becomes the '
            'receiver', () {
          final out = produceFor(
            v17(
              decl: 'String value() => this._h(1);',
              helper: 'String _h(int n) => this.label;',
            ),
          );
          expect(
            out,
            contains('String value(RouteBThing self) => _h(self, 1);'),
          );
          expect(
            out,
            contains('String _h(RouteBThing self, int n) => self.label;'),
          );
        });

        test('a receiver use that opens the argument list does not collide '
            'with the receiver argument', () {
          final out = produceFor(
            v17(),
          );
          expect(out, contains('_h(self, self.label)'));
        });

        test('names its helper like the call does, however it is spelled', () {
          final out = produceFor(
            v17(
              decl: 'String value() => _h (label);',
              helper: 'String _h(String l) => l;',
            ),
          );
          expect(out, contains('_h (self, self.label)'));
        });

        test(
          'a private instance helper is carried under a private receiver',
          () {
            final out = produceFor(v17(receiver: '_RouteBThing'));
            expect(out, contains('_h(self, self.label)'));
            expect(
              out,
              contains(
                'String _h(_RouteBThing self, String l) => l + self.label;',
              ),
            );
          },
        );

        test('a private instance helper naming an ungranted private member '
            'is refused', () {
          expect(
            () => produceFor(
              v17(
                helper: 'String _h(String l) => _release();',
              ),
            ),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                contains('`_release`'),
              ),
            ),
          );
        });

        test('a version 16 analysis cannot carry an instance helper', () {
          expect(
            () => produceFor(v17(version: 16)),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                contains('predates instance helpers'),
              ),
            ),
          );
        });

        test('a helper whose body cannot be lowered refuses the patch, and '
            'says which helper', () {
          expect(
            () => produceFor(
              v17(
                helperUnsupported: ['uses `this` other than to read a member'],
              ),
            ),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                allOf(
                  contains('`RouteBThing._h`'),
                  contains('cannot be lowered'),
                  contains('uses `this`'),
                ),
              ),
            ),
          );
        });

        test('a helper with a private access needs the release manifest', () {
          expect(
            () => produceFor(
              v17(
                decl: 'String value() => rbH(label);',
                helper: 'String rbH(String l) => l + label;',
                callName: 'rbH',
                helperAccesses: [
                  {
                    'offset': 0,
                    'member': '_secret',
                    'kind': 'get',
                    'private': {
                      'library': lib,
                      'class': 'RouteBThing',
                      'name': '_secret',
                    },
                  },
                ],
              ),
            ),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                allOf(
                  contains('`RouteBThing.rbH`'),
                  contains('published no capability manifest'),
                ),
              ),
            ),
          );
        });

        test('a helper calling `super` is refused', () {
          expect(
            () => produceFor(
              v17(
                helperSupers: [
                  {'offset': 1, 'member': 'toString', 'kind': 'method'},
                ],
              ),
            ),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                contains('calls `super`'),
              ),
            ),
          );
        });

        test('a call spelled with a type argument list is refused', () {
          expect(
            () => produceFor(
              v17(
                decl: 'String value() => _h<int>(label);',
                helper: 'String _h(String l) => l;',
              ),
            ),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                contains('not written as a plain call'),
              ),
            ),
          );
        });

        test('a call on another receiver is refused, not rewritten', () {
          expect(
            () => produceFor(
              v17(decl: 'String value() => other._h(label);'),
            ),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                contains('through a receiver this lowering cannot rewrite'),
              ),
            ),
          );
        });
      });
    });

    group('topLevelForm', () {
      test("drops a static member's modifier", () {
        expect(
          RouteBProducer.topLevelForm("static String tag() => 'S2';"),
          "String tag() => 'S2';",
        );
        expect(
          RouteBProducer.topLevelForm('static int get count => 1;'),
          'int get count => 1;',
        );
      });

      test('keeps annotations ahead of it', () {
        expect(
          RouteBProducer.topLevelForm(
            "@pragma('vm:never-inline')\n  static String tag() => 'S2';",
          ),
          "@pragma('vm:never-inline')\n  String tag() => 'S2';",
        );
      });

      test('reads past nested, generic and string annotation arguments', () {
        expect(
          RouteBProducer.topLevelForm('@Foo(Bar())\nstatic int a() => 1;'),
          '@Foo(Bar())\nint a() => 1;',
        );
        expect(
          RouteBProducer.topLevelForm('@Foo<int>() static int a() => 1;'),
          '@Foo<int>() int a() => 1;',
        );
        expect(
          RouteBProducer.topLevelForm(
            "@Foo(')') @a.b /* c */ static int a() => 1;",
          ),
          "@Foo(')') @a.b /* c */ int a() => 1;",
        );
      });

      test('leaves a top-level function and a static-named one alone', () {
        expect(
          RouteBProducer.topLevelForm("String tag() => 'static ';"),
          "String tag() => 'static ';",
        );
        expect(
          RouteBProducer.topLevelForm('int staticCount() => 1;'),
          'int staticCount() => 1;',
        );
      });
    });

    test('writes a static method without its modifier', () {
      const member = "static String tag() => 'NEW';";
      source.writeAsStringSync('class Util {\n  $member\n}\n');
      runWithOverrides(
        () => const RouteBProducer().produce(
          compiler: compiler(),
          coverage: coverage(
            representable: ['package:app/main.dart#Util.tag'],
            sources: {
              'package:app/main.dart#Util.tag': {
                'fileUri': source.uri.toString(),
                'start': 15,
                'end': 15 + member.length,
              },
            },
          ),
          releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
          releaseBuildId: 'deadbeef',
          workingDirectory: work,
          projectRoot: project,
          run: compileOk,
        ),
      );

      final generated = File(
        p.join(work.path, 'replacement_0.dart'),
      ).readAsStringSync();
      expect(
        generated,
        endsWith(
          "${RouteBProducer.entryPointPragma}\nString tag() => 'NEW';\n",
        ),
      );
    });

    test('writes one replacement library per target, with the pragma', () {
      // One payload is one function: Dart_RouteBActivatePatch attaches the
      // single Function LoadBytecode returns, so a payload has to hold exactly
      // one declaration and it has to be loadable as a dynamic module entry.
      runWithOverrides(
        () => const RouteBProducer().produce(
          compiler: compiler(),
          coverage: coverage(),
          releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
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
            releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
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
          releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
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
      // `effectiveDefines` alone and a replacement reading FLUTTER_VERSION
      // baked the empty string while the release held 3.44.8.
      late List<String> args;
      runWithOverrides(
        () => const RouteBProducer().produce(
          compiler: compiler(),
          coverage: coverage(),
          releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
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
            'String routeBValue() => '
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
            releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
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
          releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
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
          releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
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
        String name = 'value',
        String member = 'label',
        String kind = 'get',
        // A second receiver access, for an argument that itself touches the
        // receiver: `helper(label)` is two accesses, not one.
        String? also,
        String alsoMember = 'label',
        String alsoKind = 'get',
        String receiverType = 'RouteBThing',
        List<String> unsupported = const [],
        // The inferred types the analysis reports for the signature (analysis
        // 21): `{'params': [...], 'returnType': ...}`.
        Map<String, Object?>? signatureTypes,
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
                'nameOffset': start + decl.indexOf(name),
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
                'signatureTypes': ?signatureTypes,
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

      String lowered(
        RouteBCoverage coverage, {
        RouteBCapabilities? granting,
        RouteBBuildConfig? buildConfig,
      }) {
        runWithOverrides(
          () => const RouteBProducer().produce(
            compiler: compiler(),
            coverage: coverage,
            releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
            releaseBuildId: 'deadbeef',
            workingDirectory: work,
            projectRoot: project,
            capabilities: granting,
            buildConfig: buildConfig,
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
          'privateClassPublicMembers': ?classPublicMembers,
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

      group('an instance getter target', () {
        const getterKey = 'package:app/main.dart#RouteBThing.get:value';

        test('becomes a one-parameter function, past a call in its body', () {
          // Scanning for a parameter list would find `toUpperCase(` instead.
          expect(
            lowered(
              instanceCoverage(
                targetKey: getterKey,
                preamble: 'class RouteBThing {\n  ',
                decl: 'String get value => label.toUpperCase();',
                access: 'label',
              ),
            ),
            contains(
              'String value(RouteBThing self) => self.label.toUpperCase();',
            ),
          );
        });

        test('keeps a block body and its annotation', () {
          expect(
            lowered(
              instanceCoverage(
                targetKey: getterKey,
                preamble: 'class RouteBThing {\n  ',
                decl:
                    "@pragma('vm:never-inline')\n  String get value {\n"
                    '    return label;\n  }',
                access: 'label',
              ),
            ),
            contains(
              "@pragma('vm:never-inline')\n  String value(RouteBThing self) {\n"
              '    return self.label;\n  }',
            ),
          );
        });

        test('takes a private getter, the common Flutter shape', () {
          // `bool get _isEmpty` on a private State: the selector is
          // `get:_isEmpty`, and its own name must not read as a private
          // reference the release did not grant.
          expect(
            lowered(
              instanceCoverage(
                targetKey: 'package:app/main.dart#RouteBThing.get:_value',
                preamble: 'class RouteBThing {\n  ',
                decl: 'String get _value => label;',
                name: '_value',
                access: 'label',
              ),
            ),
            contains('String _value(RouteBThing self) => self.label;'),
          );
        });

        test('refuses when the source has no `get` ahead of the name', () {
          expect(
            () => lowered(
              instanceCoverage(
                targetKey: getterKey,
                preamble: 'class RouteBThing {\n  ',
                decl: 'String value() => label;',
                access: 'label',
              ),
            ),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                contains('`get` keyword'),
              ),
            ),
          );
        });
      });

      test('a private receiver class keeps its own type', () {
        // Not `dynamic`. A dynamic receiver makes every access on `self` a
        // dynamic call, which the AOT runtime refuses for any member the
        // release did not mark dynamically callable: on a device, a patched
        // `initState` calling `_start()` failed with "has no instance method
        // '_start'". The name resolves because the private-names flag is
        // passed for a private receiver (asserted below). In Flutter this is
        // the common case, because a State class is private by convention.
        expect(
          lowered(
            instanceCoverage(
              preamble: 'class _RouteBState {\n  ',
              decl: 'String value() => label;',
              access: 'label',
              receiverType: '_RouteBState',
            ),
          ),
          contains('String value(_RouteBState self) => self.label;'),
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

      test('a private receiver class keeps its type for a write too', () {
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
          contains("String value(_RouteBState self) => self.slot = 'NEW';"),
        );
      });

      group('the private receiver class is admitted only as the receiver '
          'type', () {
        // The receiver parameter spells the class, so the backstop must not
        // learn the NAME: a body that constructs it, tears off its constructor
        // or reads a static on it names a member nothing granted, and with no
        // version-12 construction evidence nothing else checks it.
        for (final (label, decl) in [
          ('a construction', 'Object value() => _RouteBState();'),
          ('a named construction', 'Object value() => _RouteBState.make();'),
          ('a constructor tear-off', 'Object value() => _RouteBState.new;'),
          ('a static read', 'Object value() => _RouteBState.shared;'),
        ]) {
          test('refuses $label', () {
            expect(
              () => lowered(
                instanceCoverage(
                  preamble: 'class _RouteBState {\n  ',
                  decl: decl,
                  access: '',
                  receiverType: '_RouteBState',
                ),
              ),
              throwsA(
                isA<RouteBUnsupportedTarget>().having(
                  (e) => e.reason,
                  'reason',
                  contains('names `_RouteBState`'),
                ),
              ),
            );
          });
        }

        test('refuses a body that spells the reserved placeholder', () {
          expect(
            () => lowered(
              instanceCoverage(
                preamble: 'class _RouteBState {\n  ',
                decl: "String value() => '@RECEIVER_TYPE@';",
                access: '',
                receiverType: '_RouteBState',
              ),
            ),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                contains('reserves for the receiver parameter'),
              ),
            ),
          );
        });
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

      group('writes the inferred types the source omitted', () {
        String declare(
          String decl, {
          required Object? params,
          Object? returnType = 'Object?',
          String name = 'probe',
          String member = '',
          String access = '',
          String kind = 'get',
        }) => lowered(
          instanceCoverage(
            preamble: 'class RouteBThing {\n  ',
            decl: decl,
            name: name,
            access: access,
            member: member,
            kind: kind,
            signatureTypes: {'params': params, 'returnType': returnType},
          ),
        );

        String reason(
          String decl, {
          required Object? params,
          Object? ret = 'Object?',
        }) {
          try {
            declare(decl, params: params, returnType: ret);
          } on RouteBUnsupportedTarget catch (e) {
            return e.reason;
          }
          fail('expected a refusal');
        }

        test('an untyped parameter takes the inherited type', () {
          expect(
            declare('@override\n  Object? probe(a) => a + 1;', params: ['int']),
            contains('Object? probe(RouteBThing self, int a) => a + 1;'),
          );
        });

        test('each untyped parameter of several, and typed ones stay', () {
          expect(
            declare(
              'Object? probe(a, double d, c) => 0;',
              params: ['int', 'double', 'List<String>?'],
            ),
            contains(
              'Object? probe(RouteBThing self, int a, double d, '
              'List<String>? c) => 0;',
            ),
          );
        });

        test('`final a` and `var a` and `covariant a` gain the type', () {
          expect(
            declare(
              'Object? probe(final a, var b, covariant c) => 0;',
              params: ['int', 'num', 'Object'],
            ),
            contains(
              'Object? probe(RouteBThing self, final int a, num b, '
              'covariant Object c) => 0;',
            ),
          );
        });

        test('the first parameter right after the parenthesis', () {
          expect(
            declare('Object? probe(a)=>a;', params: ['int']),
            contains('Object? probe(RouteBThing self, int a)=>a;'),
          );
          expect(
            declare('Object? probe(var a)=>a;', params: ['int']),
            contains('Object? probe(RouteBThing self, int a)=>a;'),
          );
        });

        test('a written type is copied as it is, however it is built', () {
          expect(
            declare(
              'Object? probe(Map<String, int> m, void Function(int, int) f, '
              '(int, String) r, a) => 0;',
              params: [
                'Map<String, int>',
                'void Function(int, int)',
                'X',
                'int',
              ],
            ),
            contains(
              'Object? probe(RouteBThing self, Map<String, int> m, '
              'void Function(int, int) f, (int, String) r, int a) => 0;',
            ),
          );
        });

        test('a parameter the analysis says is dynamic is left alone', () {
          expect(
            declare('Object? probe(a, b) => 0;', params: ['dynamic', 'int']),
            contains('Object? probe(RouteBThing self, a, int b) => 0;'),
          );
        });

        test('comments and annotations in the list do not confuse it', () {
          expect(
            declare(
              'Object? probe(/* first, */ a, // second\n  @deprecated b) => 0;',
              params: ['int', 'double'],
            ),
            contains(
              'probe(RouteBThing self, /* first, */ int a, // second\n'
              '  @deprecated double b) => 0;',
            ),
          );
        });

        test('a type the replacement cannot name refuses the target', () {
          expect(
            reason('Object? probe(a) => 0;', params: [null]),
            allOf(contains('`a`'), contains('has no written type')),
          );
        });

        test('a list the analysis does not match refuses', () {
          expect(
            reason('Object? probe(a, b) => 0;', params: ['int']),
            contains('does not match the analysis'),
          );
        });

        test('an omitted return type is written in', () {
          expect(
            declare('probe(int a) => a;', params: ['int'], returnType: 'num'),
            contains('num probe(RouteBThing self, int a) => a;'),
          );
          expect(
            declare(
              '@override\n  static probe(int a) => a;',
              params: ['int'],
              returnType: 'num',
            ),
            contains('num probe(RouteBThing self, int a) => a;'),
          );
        });

        test('an omitted getter return type is written in', () {
          const getterKey = 'package:app/main.dart#RouteBThing.get:value';
          final out = lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: '@override\n  get value => label;',
              access: 'label',
              targetKey: getterKey,
              signatureTypes: {'params': <String>[], 'returnType': 'String'},
            ),
          );
          expect(
            out,
            contains('String value(RouteBThing self) => self.label;'),
          );
        });

        test('a written or dynamic return type is left alone', () {
          expect(
            declare('String probe(int a) => "";', params: ['int']),
            contains('String probe(RouteBThing self, int a) => "";'),
          );
          expect(
            declare(
              'probe(int a) => a;',
              params: ['int'],
              returnType: 'dynamic',
            ),
            contains('probe(RouteBThing self, int a) => a;'),
          );
        });

        test('an omitted return type that cannot be named refuses', () {
          expect(
            reason('probe(int a) => a;', params: ['int'], ret: null),
            contains('return type is not written'),
          );
        });

        test('a document without the types is lowered as before', () {
          expect(
            lowered(
              instanceCoverage(
                preamble: 'class RouteBThing {\n  ',
                decl: 'Object? probe(a) => a;',
                name: 'probe',
                access: '',
              ),
            ),
            contains('Object? probe(RouteBThing self, a) => a;'),
          );
        });
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
        // Nothing here is parsed. If the edit is only `helper` ->
        // `self.helper`, named arguments and nesting cannot be disturbed — this
        // pins that.
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
            'String value(RouteBThing self) => '
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

      test("G3.7: keeps the target's own parameters and puts self first", () {
        // The entry-point contract permits any number of required positionals
        // (patch 0006), so the receiver is inserted IN FRONT of the existing
        // list rather than into an empty one. The list is copied verbatim: no
        // type is parsed and no name is rewritten.
        expect(
          lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: r"String tagged(String x) => 'NEW-$x' + label;",
              access: 'label',
            ),
          ),
          contains(
            'String tagged(RouteBThing self, String x) => '
            r"'NEW-$x' + self.label;",
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
            'String value(RouteBThing self) => '
            "self.label = self.label + f(1, 'x');",
          ),
        );
      });

      test('rewrites a read and a write at one position once', () {
        // `label += 'X'`, `count++` and `maybe ??= 'Z'` each report a read AND
        // a write at the same identifier — measured, not assumed. One prefix is
        // the whole rewrite; two would produce `self.self.label`.
        for (final (decl, out) in [
          (
            "String value() => label += 'X';",
            "String value(RouteBThing self) => self.label += 'X';",
          ),
          (
            'int value() => count++;',
            'int value(RouteBThing self) => self.count++;',
          ),
          (
            "String value() => label ??= 'Z';",
            "String value(RouteBThing self) => self.label ??= 'Z';",
          ),
          // An explicit `this.`: the read and the write are measured at the
          // member name, so `this.` is replaced once.
          (
            "String value() => this.label += 'X';",
            "String value(RouteBThing self) => self.label += 'X';",
          ),
          (
            'int value() => ++this.count;',
            'int value(RouteBThing self) => ++self.count;',
          ),
          // Inside a closure, the setState shape.
          (
            'void value() => run(() { count += 1; });',
            'void value(RouteBThing self) => run(() { self.count += 1; });',
          ),
        ]) {
          final name = decl.contains('count') ? 'count' : 'label';
          final access = decl.contains('this.') ? 'this.$name' : name;
          expect(
            lowered(
              instanceCoverage(
                preamble: 'class RouteBThing {\n  ',
                decl: decl,
                access: access,
                member: name,
                kind: 'set',
                also: access,
                alsoMember: name,
              ),
            ),
            contains(out),
          );
        }
      });

      test('refuses two different members at one position', () {
        // Not a shape the analyzer reports; the backstop for the two
        // disagreeing about the source.
        expect(
          () => lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: "String value() => label += 'X';",
              access: 'label',
              kind: 'set',
              also: 'label',
              alsoMember: 'other',
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

      test('refuses two reads of one member at one position', () {
        expect(
          () => lowered(
            instanceCoverage(
              preamble: 'class RouteBThing {\n  ',
              decl: 'String value() => label;',
              access: 'label',
              also: 'label',
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
          contains('String value(_RouteBState self) => self.label;'),
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
          contains('String value(_RouteBState self) => self.label;'),
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

      // PRIVATE CONSTRUCTION, with SAME-METHOD release evidence (v13).
      //
      // Two conditions, neither implying the other: the release's version of
      // THIS method already constructed the exact constructor, and the release
      // retained it. The manifest alone is release-WIDE and would admit a
      // construction newly introduced into a method that never performed it.
      group('private constructions, against same-method release evidence', () {
        const ctorKey = 'package:app/main.dart#_Helper.new';
        const otherKey = 'package:app/main.dart#_Other.new';

        RouteBCoverage constructs({
          int version = 13,
          List<String>? releaseKeys = const [ctorKey],
          String decl = 'String value() => _Helper().toString();',
        }) {
          const preamble = 'class RouteBThing {\n  ';
          source.writeAsStringSync('$preamble$decl');
          const start = preamble.length;
          Map<String, Object?> entry(String key) => {
            'offset': start + decl.indexOf('_'),
            'library': 'package:app/main.dart',
            'class': key.split('#').last.split('.').first,
            'constructor': 'new',
            'key': key,
          };
          return RouteBCoverage.fromJson(
            jsonEncode({
              'analysisVersion': version,
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
                  'accesses': <Object>[],
                  'unsupported': <String>[],
                  'origin': {
                    'library': 'package:app/main.dart',
                    'class': 'RouteBThing',
                    'member': 'value',
                    'memberKind': 'Method',
                  },
                  'superInvocations': <Object>[],
                  if (version >= 12) 'privateConstructions': [entry(ctorKey)],
                  if (version >= 13 && releaseKeys != null)
                    'releasePrivateConstructions': [
                      for (final k in releaseKeys) entry(k),
                    ],
                },
              },
              'rejections': <Object>[],
              'refusalSummary': null,
            }),
          );
        }

        test('carries a construction the release method already performed', () {
          expect(
            lowered(constructs(), granting: grants(classes: [ctorKey])),
            contains('_Helper()'),
          );
        });

        test('asks the CFE to resolve a private receiver class', () {
          // The receiver parameter is written `_RouteBState self`, and this
          // body touches no private member, so the class name is the only
          // private reference. Without the flag the front end reports "Type not
          // found".
          lowered(
            instanceCoverage(
              preamble: 'class _RouteBState {\n  ',
              decl: 'String value() => label;',
              access: 'label',
              receiverType: '_RouteBState',
            ),
          );
          expect(
            lastArguments,
            containsAllInOrder([
              '--resolve-private-names-in-library',
              'package:app/main.dart',
            ]),
          );
        });

        test('asks the CFE to resolve a construction-only private name', () {
          // GATE 6F's BUG, RED FIRST. The test above asserts the lowered SOURCE
          // and nothing else, so it passed while the compile could not possibly
          // succeed: `_Helper` is private to the target library and the
          // replacement is a separate synthetic library, so without this flag
          // the CFE reports
          //
          //   Error: Method not found: '_Helper'.
          //
          // and the producer surfaces a bare "exit 254". Retention and the
          // manifest grant make the constructor exist and be callable; only
          // this flag lets the replacement SPELL it. The predicate used to key
          // on private member ACCESSES alone, and this body has none --
          // `accesses` is empty and the construction is the sole private
          // reference.
          lowered(constructs(), granting: grants(classes: [ctorKey]));
          expect(
            lastArguments,
            containsAllInOrder([
              '--resolve-private-names-in-library',
              'package:app/main.dart',
            ]),
          );
        });

        test('REFUSES one the release method never performed', () {
          // THE CROSS-METHOD LEAKAGE CONTROL. The manifest globally grants the
          // constructor — some other released method built it — but the
          // release version of THIS method constructed something else, so the
          // patch is introducing it here.
          expect(
            () => lowered(
              constructs(releaseKeys: const [otherKey]),
              granting: grants(classes: [ctorKey, otherKey]),
            ),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                allOf(
                  contains('never constructed'),
                  contains('may not introduce'),
                ),
              ),
            ),
          );
        });

        test('carries defines AND private-name resolution together', () {
          // ROUTE-B-PRODUCTIONIZATION-1 item B, the interaction the workflow
          // matrix could not see. G4.1 (defines) and the private-name flag are
          // certified on separate bodies: every defines test uses a body with
          // no private reference, so the flag is OFF in all of them, and every
          // private-name test passes no defines. A release that uses BOTH -- a
          // flavored or define-carrying app patching a method that constructs a
          // private class -- was covered by neither.
          //
          // Both must survive in one argument list: losing the defines silently
          // bakes a DEFAULT into the replacement while the release holds the
          // real value, and losing the flag fails the compile outright.
          lowered(
            constructs(),
            granting: grants(classes: [ctorKey]),
            buildConfig: RouteBBuildConfig.fromBuildArgs([
              '--dart-define=b=2',
              '--dart-define=a=1',
            ]),
          );
          expect(
            lastArguments,
            containsAllInOrder([
              '--resolve-private-names-in-library',
              'package:app/main.dart',
            ]),
          );
          expect(lastArguments.where((a) => a.startsWith('-D')).toList(), [
            '-Da=1',
            '-Db=2',
          ]);
        });

        test('REFUSES when the release method constructed NONE', () {
          // Empty is a measurement, and it is a negative one.
          expect(
            () => lowered(
              constructs(releaseKeys: const []),
              granting: grants(classes: [ctorKey]),
            ),
            throwsA(isA<RouteBUnsupportedTarget>()),
          );
        });

        test('REFUSES when release evidence was not measured at all', () {
          // Absent is not empty and not permission.
          expect(
            () => lowered(
              constructs(releaseKeys: null),
              granting: grants(classes: [ctorKey]),
            ),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                contains('did not measure'),
              ),
            ),
          );
        });

        test('a version-12 document cannot use the construction path', () {
          // It measures the candidate but carries no same-method release
          // evidence, so it may not admit even a granted constructor.
          expect(
            () => lowered(
              constructs(version: 12),
              granting: grants(classes: [ctorKey]),
            ),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                contains('did not measure'),
              ),
            ),
          );
        });

        test('evidence without a manifest grant still refuses', () {
          // Both conditions are required; same-method evidence alone is not a
          // grant, because the release may not have retained the constructor.
          expect(
            () => lowered(constructs(), granting: grants()),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                contains('did not retain'),
              ),
            ),
          );
        });

        test('a version-11 document still uses the source scan', () {
          expect(
            () => lowered(
              constructs(version: 11),
              granting: grants(classes: [ctorKey]),
            ),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                contains('private identifier'),
              ),
            ),
          );
        });
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
            contains('String value(_RouteBState self) => self._controller;'),
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
          // ~~P3's failure.~~ **REWRITTEN 2026-08-25.** The member grant is
          // what attach needs; a class-level grant is not, and requiring one
          // was a misattribution of why P3's grants were inert (P3 never
          // granted the TARGET member, a public method of a private class).
          // Measured in
          // `selfhost/engine/route_b/probes/p1_dead_allocatability.sh`: Cfix3
          // attaches and reads a private field with no class item anywhere,
          // Cfix -- the same grants minus the target member -- fails at ATTACH.
          //
          // Load-bearing now rather than merely correct: the generator no
          // longer emits bare private class items at all, so a release that
          // grants no constructors has an EMPTY constructible set, and the old
          // rule would refuse every private reference on every release.
          expect(
            lowered(
              privateRead(),
              granting: grants(
                instance: ['package:app/main.dart#_RouteBState#_controller'],
              ),
            ),
            contains('String value(_RouteBState self) => self._controller;'),
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
          // The braced form `${_x}` was always fine, which is why exactly one
          // of three accesses worked in that specimen.
          expect(
            lowered(
              instanceCoverage(
                preamble: 'class _RouteBState {\n  ',
                decl: r"String value() => 'v=$_controller';",
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
          // constructors (measured: `p1_dead_allocatability.sh` C1). If a
          // future interface regression re-granted one, this still refuses:
          // `_Dead()` puts the private identifier `_Dead` in the body, and the
          // gate accepts a private identifier only when it is a granted ACCESS.
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
            contains('String value(_RouteBState self) => self._controller;'),
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

      Uint8List produceWith(
        RouteBSurvivalOracle? survival, {
        RouteBCoverage? analysis,
      }) => runWithOverrides(
        () => const RouteBProducer().produce(
          compiler: compiler(),
          coverage: analysis ?? coverage(),
          releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
          releaseBuildId: 'deadbeef',
          workingDirectory: work,
          projectRoot: project,
          survival: survival,
          run: compileOk,
        ),
      );

      test('publishes when a call site survived', () {
        expect(
          () => produceWith(
            oracle(
              RouteBSurvival.survivingCallsite,
              instrument: 'ONE_OR_MORE_QUALIFYING_CALLSITES',
            ),
          ),
          returnsNormally,
        );
      });

      group('copies of the target elsewhere', () {
        const target = 'package:app/main.dart#routeBValue';
        const inliner = 'package:app/main.dart#caller';

        RouteBSurvivalOracle withCopies(
          RouteBSurvival survival,
          Set<String> inlinedInto,
        ) =>
            (targets) => {
              for (final t in targets)
                t: RouteBSurvivalVerdict(
                  survival: survival,
                  instrumentResult: '',
                  inlinedInto: inlinedInto,
                ),
            };

        test('refuses a target whose inlined copy the patch leaves', () {
          // Call sites survived, and one caller ALSO inlined it. Publishing
          // would change the calls and leave that caller on the old body.
          expect(
            () => produceWith(
              withCopies(RouteBSurvival.survivingCallsite, {inliner}),
            ),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.toString(),
                'message',
                allOf(
                  contains('runs a copy of it inside $inliner'),
                  contains('version 15 or later'),
                ),
              ),
            ),
          );
        });

        test('publishes when every holder of a copy is replaced too', () {
          // The holder is the target itself here only to keep the fixture to
          // one source span; what is under test is that a companion inside
          // the patch satisfies the rule.
          expect(
            () => produceWith(
              withCopies(RouteBSurvival.noSurvivingCallsite, {target}),
            ),
            returnsNormally,
          );
        });

        test('publishes a folded target whose kernel callers are replaced', () {
          expect(
            () => produceWith(
              withCopies(RouteBSurvival.noSurvivingCallsite, {}),
              analysis: coverage(
                callers: {
                  target: [target],
                },
              ),
            ),
            returnsNormally,
          );
        });

        test('still refuses a folded target nothing calls', () {
          expect(
            () => produceWith(
              withCopies(RouteBSurvival.noSurvivingCallsite, {}),
              analysis: coverage(callers: {target: []}),
            ),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.toString(),
                'message',
                contains('no surviving call site'),
              ),
            ),
          );
        });
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

    group("the target library's own imports", () {
      // Dart imports are NOT transitive, so a replacement that imports only the
      // target library cannot compile a body referencing anything the target
      // IMPORTS. Found on device by the P6 flavor arm, whose body read
      // Flutter's `appFlavor`; the symptom was a bare "the bytecode compiler
      // refused its replacement body (exit 254)".
      test('are carried into the replacement library', () {
        source.writeAsStringSync(
          "import 'dart:convert';\n"
          "import 'package:flutter/services.dart' show appFlavor;\n"
          'String routeBValue() => jsonEncode([appFlavor]);\n',
        );
        final text = source.readAsStringSync();
        runWithOverrides(
          () => const RouteBProducer().produce(
            compiler: compiler(),
            coverage: RouteBCoverage.fromJson(
              jsonEncode({
                'analysisVersion': supportedRouteBAnalysisVersion,
                'verdict': 'accept',
                'changed': ['package:app/main.dart#routeBValue'],
                'added': <String>[],
                'removed': <String>[],
                'patchable': ['package:app/main.dart#routeBValue'],
                'conditional': <String>[],
                'sources': {
                  'package:app/main.dart#routeBValue': {
                    'fileUri': source.uri.toString(),
                    'start': text.indexOf('String routeBValue'),
                    'end': text.length,
                  },
                },
                'rejections': <Object>[],
                'refusalSummary': null,
              }),
            ),
            releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
            releaseBuildId: 'deadbeef',
            workingDirectory: work,
            projectRoot: project,
            run: compileOk,
          ),
        );
        final generated = File(
          p.join(work.path, 'replacement_0.dart'),
        ).readAsStringSync();
        // Carried VERBATIM, combinators included: `show appFlavor` is part of
        // the resolution the body was written against.
        expect(generated, contains("import 'dart:convert';"));
        expect(
          generated,
          contains("import 'package:flutter/services.dart' show appFlavor;"),
        );
        // And the target library itself is still imported, for its own members.
        expect(generated, contains("import 'package:app/main.dart';"));
      });

      test('a RELATIVE import is refused, not silently dropped', () {
        // Copied as-is it resolves against the replacement's directory; as a
        // file URI it makes the CFE see one library twice. Dropping it would
        // reproduce the original failure with a message about bytecode.
        source.writeAsStringSync(
          "import 'helpers.dart';\n"
          'String routeBValue() => helper();\n',
        );
        final text = source.readAsStringSync();
        expect(
          () => runWithOverrides(
            () => const RouteBProducer().produce(
              compiler: compiler(),
              coverage: RouteBCoverage.fromJson(
                jsonEncode({
                  'analysisVersion': supportedRouteBAnalysisVersion,
                  'verdict': 'accept',
                  'changed': ['package:app/main.dart#routeBValue'],
                  'added': <String>[],
                  'removed': <String>[],
                  'patchable': ['package:app/main.dart#routeBValue'],
                  'conditional': <String>[],
                  'sources': {
                    'package:app/main.dart#routeBValue': {
                      'fileUri': source.uri.toString(),
                      'start': text.indexOf('String routeBValue'),
                      'end': text.length,
                    },
                  },
                  'rejections': <Object>[],
                  'refusalSummary': null,
                }),
              ),
              releaseImportKernel: File(
                p.join(cell.path, 'release_import.dill'),
              ),
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
              allOf(
                contains('RELATIVE import'),
                contains('helpers.dart'),
                contains('Convert it to a `package:` import'),
              ),
            ),
          ),
        );
      });
    });

    group('D-SUPER-2B.1c: super.member()', () {
      // The whole declaration is written into the fixture file, so the offsets
      // below are real positions in real source rather than invented numbers --
      // which is the same discipline the analyzer's own offsets get.
      const superDeclaration = 'String routeBValue() => super.dispose();';
      const argDeclaration = "String routeBValue() => super.tag('a', 7);";

      // The default target and the default release evidence MATCH, so the
      // narrow-v1 gate admits. Tests that want a refusal make them differ.
      const target = {
        'fileUri': 'file:///app/main.dart',
        'fileOffset': 100,
        'name': 'dispose',
        'kind': 'Method',
      };

      Map<String, Object?> loweringFor(
        String text, {
        String member = 'dispose',
        String kind = 'method',
        String memberKind = 'Method',
        int? offset,
        Object? siteTarget = target,
        List<Object?>? releaseSuperTargets = const [target],
        bool omitReleaseSuperTargets = false,
      }) => {
        'package:app/main.dart#routeBValue': {
          'receiverType': 'Thing',
          'nameOffset': 0,
          'accesses': <Object>[],
          'unsupported': <String>[],
          'origin': {
            'library': 'package:app/main.dart',
            'class': 'Thing',
            'member': 'routeBValue',
            'memberKind': memberKind,
          },
          'superInvocations': [
            {
              'offset': offset ?? text.indexOf(member, text.indexOf('super')),
              'member': member,
              'kind': kind,
              'target': siteTarget,
            },
          ],
          if (!omitReleaseSuperTargets)
            'releaseSuperTargets': releaseSuperTargets,
        },
      };

      String produce(
        String text,
        Map<String, Object?> lowering, {
        bool dualKernel = true,
        bool withVerificationKernel = true,
      }) {
        source.writeAsStringSync(text);
        runWithOverrides(
          () => const RouteBProducer().produce(
            compiler: compiler(dualKernel: dualKernel),
            patchedVerificationKernel: withVerificationKernel
                ? File(p.join(cell.path, 'patched_verification.dill'))
                : null,
            coverage: coverage(
              lowering: lowering,
              sources: {
                'package:app/main.dart#routeBValue': {
                  'fileUri': source.uri.toString(),
                  'start': 0,
                  'end': text.length,
                },
              },
            ),
            releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
            releaseBuildId: 'deadbeef',
            workingDirectory: work,
            projectRoot: project,
            run: compileOk,
          ),
        );
        return File(p.join(work.path, 'replacement_0.dart')).readAsStringSync();
      }

      test('rewrites a zero-argument call into the pragma intrinsic', () {
        final emitted = produce(
          superDeclaration,
          loweringFor(superDeclaration),
        );
        // THE OBSERVABLE IS THE EMITTED SOURCE. "the producer reported success"
        // is not evidence that it lowered anything.
        expect(emitted, contains("@pragma('shorebird:direct-super')"));
        expect(emitted, isNot(contains('super.dispose')));
        // `dynamic`, so a private class's `dynamic self` reaches the compiler
        // as the bare parameter rather than wrapped in an implicit cast.
        expect(emitted, contains('  dynamic receiver,'));
        // Full site identity, INCLUDING memberKind: a class may hold a method,
        // a getter and a setter of one name, and the compiler resolves on both.
        expect(
          emitted,
          contains(
            r"($routeBSuper(self, 'package:app/main.dart', 'Thing', "
            "'routeBValue', 'Method', ",
          ),
        );
        // The ANALYZER's resolved target travels with the site, so the compiler
        // can prove it arrived at the same declaration independently. Asserted
        // as the exact tail, so a field cannot be dropped silently.
        expect(
          emitted,
          contains(
            "'dispose', 'file:///app/main.dart', 100, 'dispose', 'Method') "
            'as dynamic)',
          ),
        );
        // The intrinsic declaration must sit BEFORE the entry-point pragma, and
        // only the replacement may carry that pragma.
        expect(
          emitted.indexOf(r'$routeBSuper('),
          lessThan(emitted.indexOf("@pragma('dyn-module:entry-point')")),
        );
      });

      test('emits no intrinsic declaration when no super site is reported', () {
        final emitted = produce(declaration, <String, Object?>{});
        expect(emitted, isNot(contains('shorebird:direct-super')));
      });

      test('refuses a call written with arguments', () {
        expect(
          () => produce(
            argDeclaration,
            loweringFor(argDeclaration, member: 'tag'),
          ),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.reason,
              'reason',
              contains('written with arguments'),
            ),
          ),
        );
      });

      test('fail-closed when the source shape cannot be verified', () {
        // An offset that does not name the member: the analyzer and the source
        // disagree about where the site is, so nothing may be lowered on it.
        expect(
          () => produce(
            superDeclaration,
            loweringFor(superDeclaration, offset: 3),
          ),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.reason,
              'reason',
              contains('could not be verified'),
            ),
          ),
        );
      });

      test('refuses a super getter or setter site', () {
        for (final kind in const ['getter', 'setter']) {
          expect(
            () => produce(
              superDeclaration,
              loweringFor(superDeclaration, kind: kind),
            ),
            throwsA(
              isA<RouteBUnsupportedTarget>().having(
                (e) => e.reason,
                'reason',
                contains('super `$kind`'),
              ),
            ),
            reason: kind,
          );
        }
      });

      test('refuses a target the release never direct-called', () {
        // The narrow-v1 gate. The release evidence names a DIFFERENT target, so
        // there is no proof this one has executable code in the release — and a
        // DirectCall to an uncompiled target aborts the app rather than failing
        // to bind.
        expect(
          () => produce(
            superDeclaration,
            loweringFor(
              superDeclaration,
              releaseSuperTargets: const [
                {
                  'fileUri': 'file:///app/main.dart',
                  'fileOffset': 999,
                  'name': 'dispose',
                  'kind': 'Method',
                },
              ],
            ),
          ),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.reason,
              'reason',
              allOf(
                contains('never direct-called'),
                contains('no evidence it has executable code'),
              ),
            ),
          ),
        );
      });

      test('refuses when the release direct-called nothing at all', () {
        expect(
          () => produce(
            superDeclaration,
            loweringFor(superDeclaration, releaseSuperTargets: const []),
          ),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.reason,
              'reason',
              contains('never direct-called'),
            ),
          ),
        );
      });

      // MEASUREMENT-STATE CONTRACT. Absent and empty both refuse, and must
      // refuse with DIFFERENT words: "we did not look" sends a reader at the
      // release pipeline, "the release called nothing" sends them at the patch.
      test('refuses by name when the release evidence is ABSENT', () {
        expect(
          () => produce(
            superDeclaration,
            loweringFor(superDeclaration, omitReleaseSuperTargets: true),
          ),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.reason,
              'reason',
              allOf(
                contains('did not measure'),
                contains('missing measurement, not a negative result'),
              ),
            ),
          ),
        );
      });

      test('an EMPTY measurement is a measured negative, not absence', () {
        expect(
          () => produce(
            superDeclaration,
            loweringFor(superDeclaration, releaseSuperTargets: const []),
          ),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.reason,
              'reason',
              allOf(
                contains('never direct-called'),
                isNot(contains('did not measure')),
              ),
            ),
          ),
        );
      });

      test('refuses a site whose target did not resolve', () {
        expect(
          () => produce(
            superDeclaration,
            loweringFor(superDeclaration, siteTarget: null),
          ),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.reason,
              'reason',
              contains('no resolved target'),
            ),
          ),
        );
      });

      test('admits when only the SITE moved and the target did not', () {
        // The property the whole design turns on: a patch that edits around an
        // existing super call moves the call site while the target is
        // unchanged. Measured at 988 -> 1005 in super0/s2b1f control 1.
        const moved = "String routeBValue() => 'x' + super.dispose();";
        final emitted = produce(moved, loweringFor(moved));
        expect(emitted, contains("@pragma('shorebird:direct-super')"));
        expect(emitted, isNot(contains('super.dispose')));
      });

      test('refuses when the cell cannot compile a direct super call', () {
        // FAIL-CLOSED ACROSS THE TRANSITION. Analysis v11 describes super sites
        // whatever cell the release resolves; a cell whose dart2bytecode
        // predates 0017 must refuse rather than take an intrinsic it cannot
        // lower. The capability is asked of the compiler binary, not read from
        // a metadata line.
        expect(
          () => produce(
            superDeclaration,
            loweringFor(superDeclaration),
            dualKernel: false,
          ),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.reason,
              'reason',
              allOf(
                contains('routeBDirectSuperDualKernelV1'),
                contains('cannot be carried'),
              ),
            ),
          ),
        );
      });

      test('the compiler invocation carries BOTH kernels, distinctly', () {
        // THE ARCHITECTURAL BOUNDARY, asserted. Several STOPs were spent
        // discovering that --import-dill must stay the shipped program while
        // the patched body is verified separately, so the command that encodes
        // that split is pinned rather than left implicit.
        late List<String> args;
        source.writeAsStringSync(superDeclaration);
        runWithOverrides(
          () => const RouteBProducer().produce(
            compiler: compiler(),
            coverage: coverage(
              lowering: loweringFor(superDeclaration),
              sources: {
                'package:app/main.dart#routeBValue': {
                  'fileUri': source.uri.toString(),
                  'start': 0,
                  'end': superDeclaration.length,
                },
              },
            ),
            releaseImportKernel: File(
              p.join(cell.path, 'release_import.dill'),
            ),
            patchedVerificationKernel: File(
              p.join(cell.path, 'patched_verification.dill'),
            ),
            releaseBuildId: 'deadbeef',
            workingDirectory: work,
            projectRoot: project,
            run: (executable, arguments) {
              args = arguments;
              return compileOk(executable, arguments);
            },
          ),
        );
        // Binding stays the RELEASE kernel.
        expect(
          args[args.indexOf('--import-dill') + 1],
          endsWith('release_import.dill'),
        );
        // Verification is a SEPARATE option, not an overload of the first.
        expect(
          args[args.indexOf('--patched-verification-dill') + 1],
          endsWith('patched_verification.dill'),
        );
      });

      test('an ordinary patch passes no verification kernel', () {
        // The feature must not perturb the existing path.
        late List<String> args;
        runWithOverrides(
          () => const RouteBProducer().produce(
            compiler: compiler(),
            coverage: coverage(),
            releaseImportKernel: File(
              p.join(cell.path, 'release_import.dill'),
            ),
            patchedVerificationKernel: File(
              p.join(cell.path, 'patched_verification.dill'),
            ),
            releaseBuildId: 'deadbeef',
            workingDirectory: work,
            projectRoot: project,
            run: (executable, arguments) {
              args = arguments;
              return compileOk(executable, arguments);
            },
          ),
        );
        // Supplied but UNUSED: no super site, so nothing to verify.
        expect(args, isNot(contains('--patched-verification-dill')));
      });

      test('refuses a super site with no verification kernel', () {
        // Null is correct for an ordinary patch and an error here: the compiler
        // would otherwise have nothing to check the patched site against, and
        // the only other kernel available is the release's — the exact
        // substitution 2B.1c-SITE showed producing silent wrong semantics.
        expect(
          () => produce(
            superDeclaration,
            loweringFor(superDeclaration),
            withVerificationKernel: false,
          ),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.reason,
              'reason',
              contains('no patched verification kernel was supplied'),
            ),
          ),
        );
      });

      test('refuses a super site with no origin identity', () {
        final lowering = loweringFor(superDeclaration);
        (lowering.values.first! as Map<String, Object?>).remove('origin');
        expect(
          () => produce(superDeclaration, lowering),
          throwsA(
            isA<RouteBUnsupportedTarget>().having(
              (e) => e.reason,
              'reason',
              contains('without the origin identity'),
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
            releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
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
            releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
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
      const start = preamble.length; // code units, as the kernel reports

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
          releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
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
            releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
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

    group('D-HYGIENE: capture-avoiding receiver name', () {
      String fresh(String declaration) =>
          RouteBProducer.freshReceiverNameForTesting(declaration);

      test('keeps `self` when the declaration cannot capture it', () {
        // The preservation property. Every target that lowers correctly today
        // must keep lowering to byte-identical source, so only a declaration
        // that could collide pays anything.
        expect(fresh('String value() => label;'), 'self');
        expect(fresh(''), 'self');
      });

      test('moves off `self` whenever the declaration spells it at all', () {
        for (final declaration in <String>[
          'String value() { final self = x; return label; }',
          'String value() => items.map((self) => label).join();',
          'String tagged(String self) => label;',
          '// a comment mentioning self\nString value() => label;',
          "String value() => 'self';",
          'String selfTest() => label;',
        ]) {
          expect(
            fresh(declaration),
            isNot('self'),
            reason: 'must not reuse a name the declaration already spells',
          );
        }
      });

      test('the generated name is absent from the declaration', () {
        // The whole property, stated directly: whatever comes back must not
        // occur in the text being copied into its scope.
        for (final declaration in <String>[
          'String value() { final self = x; return label; }',
          'final self = 1; final shorebirdReceiver0 = 2;',
          'self shorebirdReceiver0 shorebirdReceiver1 shorebirdReceiver2',
        ]) {
          expect(declaration.contains(fresh(declaration)), isFalse);
        }
      });

      test('walks past candidates the declaration already uses', () {
        expect(fresh('self shorebirdReceiver0'), 'shorebirdReceiver1');
        expect(
          fresh(
            'self shorebirdReceiver0 shorebirdReceiver1 shorebirdReceiver2',
          ),
          'shorebirdReceiver3',
        );
      });

      test('never generates a PRIVATE name', () {
        // A `_`-prefixed name would be caught by the producer's own backstop
        // against private identifiers the release did not grant, and carving an
        // exemption into a safety check is how safety checks stop working.
        for (final declaration in <String>[
          'self',
          'self shorebirdReceiver0',
          'self shorebirdReceiver0 shorebirdReceiver1',
        ]) {
          expect(fresh(declaration).startsWith('_'), isFalse);
        }
      });
    });
  });
}
