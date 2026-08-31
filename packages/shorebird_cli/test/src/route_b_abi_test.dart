import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/route_b_abi.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_producer.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:test/test.dart';

import 'mocks.dart';

void main() {
  // P4.3 pins the replacement ABI boundary. It pins the CODE, not the prose:
  // the analyzer's wording ships in the compiler cell and must stay free to be
  // copy-edited, while what a caller may rely on must not move.
  group('classifyRouteBAbiRefusals', () {
    test('names the shape for each currently refused form', () {
      expect(
        classifyRouteBAbiRefusals('the method takes named parameters').single,
        isA<RouteBAbiRefusal>()
            .having(
              (r) => r.code,
              'code',
              RouteBAbiCode.unsupportedParameterShape,
            )
            .having((r) => r.reason, 'reason', 'named_parameters'),
      );
      expect(
        classifyRouteBAbiRefusals(
          'the method takes optional positional parameters',
        ).single,
        isA<RouteBAbiRefusal>()
            .having(
              (r) => r.code,
              'code',
              RouteBAbiCode.unsupportedParameterShape,
            )
            .having((r) => r.reason, 'reason', 'optional_positional_parameters'),
      );
      expect(
        classifyRouteBAbiRefusals('the method is generic').single,
        isA<RouteBAbiRefusal>()
            .having((r) => r.code, 'code', RouteBAbiCode.unsupportedTypeShape)
            .having((r) => r.reason, 'reason', 'generic_method'),
      );
    });

    test('reports EVERY shape a reason names, not just the first', () {
      // One member can break two rules at once, and reporting one would hide
      // work from whoever has to fix it. The analyzer joins with '; '.
      final found = classifyRouteBAbiRefusals(
        'the method takes named parameters; the method is generic',
      );
      expect(found.map((f) => f.reason), [
        'named_parameters',
        'generic_method',
      ]);
    });

    test('required positionals are SUPPORTED and produce no refusal', () {
      // The positive side of the boundary. Without this row the group would
      // only prove that refusals are named, not that anything is allowed.
      expect(classifyRouteBAbiRefusals('the method takes 3 parameters'), isEmpty);
      expect(routeBAbiLabel('the receiver is used in a closure'), isNull);
    });

    test('an unrecognised shape reason is an ABI reason, and unlabelled', () {
      // The mapping gap: a future cell rewords a rule. It must not read as
      // supported.
      const future = 'the method takes a record pattern parameter';
      expect(routeBAbiLabel(future), isNull);
      expect(isRouteBAbiReason(future), isTrue);
    });

    test('a non-ABI refusal is not claimed as an ABI one', () {
      // Over-claiming here would relabel capability and receiver refusals as
      // ABI ones and make the codes meaningless.
      for (final other in const [
        'the enclosing private class is not retained by the release',
        'the release contains no surviving call site for it',
        'one source token cannot be two edits',
      ]) {
        expect(isRouteBAbiReason(other), isFalse, reason: other);
        expect(routeBAbiLabel(other), isNull, reason: other);
      }
    });
  });

  group('the ABI boundary, as the producer enforces it', () {
    late Directory cell;
    late Directory work;
    late Directory project;
    late File source;
    late ShorebirdLogger logger;

    const declaration = 'String m() => "v";';

    RouteBCompiler compiler() => RouteBCompiler(
      runtime: File(p.join(cell.path, 'dartaotruntime')),
      compilerSnapshot: File(p.join(cell.path, 'dart2bytecode.aot')),
      platformDill: File(p.join(cell.path, 'vm_platform.dill')),
      analyzer: File(p.join(cell.path, 'route_b_analyze.aot')),
      frontend: File(p.join(cell.path, 'route_b_gen_kernel.aot')),
      interfaceGenerator: File(
        p.join(cell.path, 'route_b_gen_dynamic_interface.aot'),
      ),
      releaseProbe: File(p.join(cell.path, 'route_b_release_probe.aot')),
      flutterPlatformDill: File(
        p.join(cell.path, 'flutter_platform_strong.dill'),
      ),
      provenance: '',
    );

    /// Coverage whose one target is an INSTANCE member, so it is lowered and the
    /// lowering's `unsupported` list is the ABI gate.
    // Read from the FILE, not from a constant: a test that rewrites the source
    // and leaves the span pinned to the old length silently slices a truncated
    // declaration, and then asserts against the fragment.
    RouteBCoverage coverageWith(List<String> unsupported) {
      final text = source.readAsStringSync();
      return RouteBCoverage.fromJson(
          jsonEncode({
            'analysisVersion': supportedRouteBAnalysisVersion,
            'verdict': 'accept',
            'changed': ['package:app/main.dart#C.m'],
            'added': <String>[],
            'removed': <String>[],
            'patchable': <String>[],
            'conditional': ['package:app/main.dart#C.m'],
            'sources': {
              'package:app/main.dart#C.m': {
                'fileUri': source.uri.toString(),
                'start': 0,
                'end': text.length,
              },
            },
            'lowering': {
              'package:app/main.dart#C.m': {
                'receiverType': 'package:app/main.dart#C',
                // The analyzer points at the member's own identifier; omitting
                // it makes the lowering fail with a bare null-check error that
                // says nothing about the ABI.
                'nameOffset': text.indexOf('m('),
                'accesses': <Object>[],
                'unsupported': unsupported,
              },
            },
            'rejections': <Object>[],
            'refusalSummary': null,
          }),
      );
    }

    setUp(() {
      cell = Directory.systemTemp.createTempSync('cell');
      work = Directory.systemTemp.createTempSync('work');
      project = Directory.systemTemp.createTempSync('project');
      logger = MockShorebirdLogger();
      source = File(p.join(project.path, 'main.dart'))
        ..writeAsStringSync(declaration);
    });

    void produce(List<String> unsupported) => runScoped(
      () => const RouteBProducer().produce(
        compiler: compiler(),
        coverage: coverageWith(unsupported),
        releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
        releaseBuildId: 'deadbeef',
        workingDirectory: work,
        projectRoot: project,
        run: (executable, arguments) {
          final out = arguments[arguments.indexOf('-o') + 1];
          File(out).writeAsStringSync('BYTECODE');
          return ProcessResult(0, 0, '', '');
        },
      ),
      values: {loggerRef.overrideWith(() => logger)},
    );

    // THE STAGE. Every row below refuses inside produce(), which runs before any
    // bytecode is compiled and long before anything is uploaded. That is the
    // property being pinned, not merely that a refusal happens somewhere.
    test('required positionals only: PUBLISHES', () {
      expect(() => produce(const []), returnsNormally);
    });

    test('named parameters: refused, labelled, before publication', () {
      expect(
        () => produce(const ['the method takes named parameters']),
        throwsA(
          isA<RouteBUnsupportedTarget>().having(
            (e) => e.reason,
            'reason',
            allOf(
              contains('UNSUPPORTED_PARAMETER_SHAPE(named_parameters)'),
              // The analyzer's own words survive alongside the code.
              contains('the method takes named parameters'),
            ),
          ),
        ),
      );
    });

    test('optional positionals: refused, labelled, before publication', () {
      expect(
        () => produce(const [
          'the method takes optional positional parameters',
        ]),
        throwsA(
          isA<RouteBUnsupportedTarget>().having(
            (e) => e.reason,
            'reason',
            contains(
              'UNSUPPORTED_PARAMETER_SHAPE(optional_positional_parameters)',
            ),
          ),
        ),
      );
    });

    test('generic method: refused with the TYPE-shape code', () {
      // A distinct code, because "the parameter list is wrong" and "the member
      // is generic" are different boundaries and may move independently.
      expect(
        () => produce(const ['the method is generic']),
        throwsA(
          isA<RouteBUnsupportedTarget>().having(
            (e) => e.reason,
            'reason',
            contains('UNSUPPORTED_TYPE_SHAPE(generic_method)'),
          ),
        ),
      );
    });

    test('an unrecognised shape reason refuses as UNCLASSIFIED', () {
      // A future cell rewords a rule. The refusal survives; only the name is
      // missing, and it says so instead of falling through as supported.
      expect(
        () => produce(const ['the method takes a record pattern parameter']),
        throwsA(
          isA<RouteBUnsupportedTarget>().having(
            (e) => e.reason,
            'reason',
            allOf(
              contains('UNSUPPORTED_UNCLASSIFIED(unrecognised)'),
              contains('record pattern'),
            ),
          ),
        ),
      );
    });

    test('a non-ABI refusal is not given an ABI label', () {
      expect(
        () => produce(const ['one source token cannot be two edits']),
        throwsA(
          isA<RouteBUnsupportedTarget>().having(
            (e) => e.reason,
            'reason',
            allOf(
              contains('one source token cannot be two edits'),
              isNot(contains('UNSUPPORTED_')),
            ),
          ),
        ),
      );
    });

    test('MUTATION: the analyzer\'s list is the ONLY thing enforcing this', () {
      // A source that really does take named parameters, with the analyzer
      // reporting nothing, PUBLISHES. So the boundary is enforced in exactly one
      // place -- the cell's `unsupported` list -- and the producer does not
      // independently re-derive the shape.
      //
      // That is worth pinning rather than assuming: it says where to look when
      // the boundary moves, and it makes the rows above meaningful, since they
      // would otherwise be consistent with a second hidden check doing the work.
      source.writeAsStringSync('String m({String? x}) => "v";');
      expect(() => produce(const []), returnsNormally);
      final generated = File(
        p.join(work.path, 'replacement_0.dart'),
      ).readAsStringSync();
      expect(generated, contains('{String? x}'));
    });
  });
}
