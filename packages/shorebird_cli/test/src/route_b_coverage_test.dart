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
              allOf(contains('version 99'), contains('understands 1')),
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
  });
}
