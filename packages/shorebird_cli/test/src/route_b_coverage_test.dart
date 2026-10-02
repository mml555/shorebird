import 'dart:convert';

import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:test/test.dart';

void main() {
  group(RouteBCoverage, () {
    const target = 'package:app/main.dart#Shape.describe';
    const abstractReason = 'abstract; call sites dispatch to implementations';

    String document({
      Object? version = supportedRouteBAnalysisVersion,
      String verdict = 'accept',
      List<String> changed = const [],
      List<String> added = const [],
      List<String> removed = const [],
      List<String> patchable = const [],
      List<String> conditional = const [],
      List<Map<String, Object?>> rejections = const [],
      String? refusalSummary,
    }) => jsonEncode({
      'analysisVersion': version,
      'verdict': verdict,
      'changed': changed,
      'added': added,
      'removed': removed,
      'patchable': patchable,
      'conditional': conditional,
      'rejections': rejections,
      'refusalSummary': refusalSummary,
    });

    group('version', () {
      test('refuses an analysis it does not understand', () {
        // Best-effort parsing across versions is how you get a confident wrong
        // answer: the cell comes from the release's engine, so a version skew
        // means the CLI and that toolchain disagree about the format.
        expect(
          () => RouteBCoverage.fromJson(document(version: 99)),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('version 99'),
                contains('understands $supportedRouteBAnalysisVersion'),
              ),
            ),
          ),
        );
      });

      test('refuses output that is not JSON', () {
        expect(
          () => RouteBCoverage.fromJson('not json at all'),
          throwsA(isA<FormatException>()),
        );
      });

      test('refuses an unknown verdict', () {
        expect(
          () => RouteBCoverage.fromJson(document(verdict: 'probably')),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('unknown verdict'),
            ),
          ),
        );
      });

      test('refuses an unknown rejection category', () {
        expect(
          () => RouteBCoverage.fromJson(
            document(
              verdict: 'reject',
              rejections: [
                {'target': target, 'category': 'vibes', 'reason': 'x'},
              ],
            ),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('unknown rejection category'),
            ),
          ),
        );
      });

      test('refuses a rejection that names no target', () {
        // A refusal with nothing to point at is a contract violation, not a
        // patch failure. "Something was wrong" is the exact failure mode the
        // reason-carrying design exists to prevent.
        expect(
          () => RouteBCoverage.fromJson(document(verdict: 'reject')),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('names no target'),
            ),
          ),
        );
      });
    });

    group('sources', () {
      test('carries each changed member\'s source span', () {
        // A span, not text: the analyzer has the kernel's offsets and the
        // producer has the file. One declaration per target is exactly what
        // the runtime's one-payload-one-function contract needs.
        final coverage = RouteBCoverage.fromJson(
          jsonEncode({
            'analysisVersion': supportedRouteBAnalysisVersion,
            'verdict': 'accept',
            'changed': ['a#alpha'],
            'added': <String>[],
            'removed': <String>[],
            'patchable': ['a#alpha'],
            'conditional': <String>[],
            'sources': {
              'a#alpha': {
                'fileUri': 'file:///app/lib/main.dart',
                'start': 10,
                'end': 42,
              },
            },
            'rejections': <Object>[],
            'refusalSummary': null,
          }),
        );

        expect(
          coverage.sources['a#alpha']!.fileUri,
          'file:///app/lib/main.dart',
        );
        expect(coverage.sources['a#alpha']!.start, 10);
        expect(coverage.sources['a#alpha']!.end, 42);
      });

      test('is empty when the analysis carries none', () {
        expect(RouteBCoverage.fromJson(document()).sources, isEmpty);
      });
    });

    group('representability', () {
      test('keeps conditional separate from representable', () {
        // Folding conditional into representable would report instance-member
        // patches as proven; folding it into rejected would refuse every one
        // of them. It is a third state and stays one.
        final coverage = RouteBCoverage.fromJson(
          document(
            changed: ['a#one', 'a#Two.three'],
            patchable: ['a#one'],
            conditional: ['a#Two.three'],
          ),
        );

        expect(coverage.representable, ['a#one']);
        expect(coverage.conditional, ['a#Two.three']);
        expect(coverage.verdict, RouteBVerdict.accept);
      });
    });

    group('refusalMessage', () {
      test('names every rejected target and its exact reason', () {
        // A count is worse than useless: "1 changed member is not reachable"
        // tells you a patch failed and gives you nowhere to go.
        final coverage = RouteBCoverage.fromJson(
          document(
            verdict: 'reject',
            changed: ['a#alpha', 'a#beta', 'a#gamma', target],
            patchable: ['a#alpha', 'a#beta', 'a#gamma'],
            rejections: [
              {
                'target': target,
                'category': 'unreachable',
                'reason': abstractReason,
              },
            ],
          ),
        );

        expect(
          coverage.refusalMessage,
          allOf(
            contains('1 of 4 changed members'),
            contains(target),
            contains(abstractReason),
            contains('The whole patch is refused'),
            contains('Nothing was uploaded'),
          ),
        );
      });

      test('counts added members among what could not be carried', () {
        // An addition never appears in `changed`, so counting only `changed`
        // would report "0 of 1" for a patch refused entirely because of it.
        final coverage = RouteBCoverage.fromJson(
          document(
            verdict: 'reject',
            changed: ['a#alpha'],
            patchable: ['a#alpha'],
            added: ['a#addedHelper'],
            rejections: [
              {
                'target': 'a#addedHelper',
                'category': 'added',
                'reason':
                    'a patch replaces bodies and cannot introduce '
                    'members, so bytecode referencing them would fail to bind',
              },
            ],
          ),
        );

        expect(coverage.refusalMessage, contains('1 of 2 changed members'));
        expect(
          coverage.rejections.single.category,
          RouteBRepresentability.added,
        );
      });
    });

    group('inert', () {
      test('is neither accept nor reject', () {
        // A patch carrying nothing installs and changes nothing, which looks
        // like it worked.
        final coverage = RouteBCoverage.fromJson(document(verdict: 'inert'));
        expect(coverage.verdict, RouteBVerdict.inert);
        expect(coverage.changed, isEmpty);
      });
    });

    group('lowering', () {
      /// One instance target with two accesses: a public one and a private one.
      String withAccesses() => jsonEncode({
        'analysisVersion': supportedRouteBAnalysisVersion,
        'verdict': 'accept',
        'changed': [target],
        'added': <String>[],
        'removed': <String>[],
        'patchable': <String>[],
        'conditional': [target],
        'rejections': <Object>[],
        'refusalSummary': null,
        'lowering': {
          target: {
            'receiverType': '_Shape',
            'nameOffset': 10,
            'accesses': [
              {'offset': 20, 'member': 'label', 'kind': 'get'},
              {
                'offset': 30,
                'member': '_controller',
                'kind': 'get',
                'private': {
                  // The DECLARING class, which need not be the class being
                  // patched: a private member may be inherited within the
                  // library, and the manifest keys it where it is declared.
                  'library': 'package:app/main.dart',
                  'class': '_ShapeBase',
                  'name': 'get:_controller',
                },
              },
            ],
            'unsupported': <String>[],
          },
        },
      });

      test('carries the manifest key of a private access', () {
        final lowering = RouteBCoverage.fromJson(
          withAccesses(),
        ).lowering[target]!;

        expect(lowering.accesses.first.privateTarget, isNull);
        final private = lowering.accesses.last.privateTarget!;
        expect(private.library, 'package:app/main.dart');
        expect(private.className, '_ShapeBase');
        // VM-shaped: an accessor keeps the `get:` the manifest keys it under.
        expect(private.name, 'get:_controller');
      });

      test('a private access is no longer an unsupported reason', () {
        // The relaxation itself. Version 6 put `reads the private member
        // \`_controller\`` in `unsupported`, which refused the whole target
        // before any manifest was consulted.
        expect(
          RouteBCoverage.fromJson(withAccesses()).lowering[target]!.unsupported,
          isEmpty,
        );
      });
    });
  });
}
