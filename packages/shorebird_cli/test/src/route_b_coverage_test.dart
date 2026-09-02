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

    // VERSION-ASYMMETRIC MEASUREMENT STATE (analysis versions 11 and 12).
    //
    // v12 adds `privateConstructions`. The decoder must keep the two versions'
    // silences apart: a v11 document CANNOT carry the field, so its absence is
    // "unmeasured"; a v12 document always carries it, so an absence there is a
    // malformed document. Collapsing either into `[]` would assert that the
    // body constructs no private class, which in the v11 case nobody measured.
    group('privateConstructions across versions 11 and 12', () {
      String doc(int version, Map<String, Object?> lowering) => jsonEncode({
        'analysisVersion': version,
        'verdict': 'accept',
        'changed': <String>[],
        'added': <String>[],
        'removed': <String>[],
        'patchable': <String>[],
        'conditional': <String>[],
        'rejections': <Map<String, Object?>>[],
        'refusalSummary': null,
        'lowering': {'package:app/main.dart#Thing.go': lowering},
      });

      const body = {
        'receiverType': 'Thing',
        'nameOffset': 0,
        'accesses': <Object>[],
        'unsupported': <String>[],
        'origin': {
          'library': 'package:app/main.dart',
          'class': 'Thing',
          'member': 'go',
          'memberKind': 'Method',
        },
        'superInvocations': <Object>[],
      };

      const construction = {
        'offset': 42,
        'library': 'package:app/main.dart',
        'class': '_Helper',
        'constructor': 'new',
        'key': 'package:app/main.dart#_Helper.new',
      };

      RouteBLowering parse(int version, Map<String, Object?> extra) =>
          RouteBCoverage.fromJson(
            doc(version, {...body, ...extra}),
          ).lowering['package:app/main.dart#Thing.go']!;

      test('version 11 is still accepted', () {
        expect(
          () => RouteBCoverage.fromJson(doc(11, body)),
          returnsNormally,
        );
      });

      test('a version-11 document leaves it UNMEASURED, not empty', () {
        expect(parse(11, const {}).privateConstructions, isNull);
      });

      test('a version-12 document with none reports MEASURED and empty', () {
        final parsed = parse(12, const {'privateConstructions': <Object>[]});
        expect(parsed.privateConstructions, isNotNull);
        expect(parsed.privateConstructions, isEmpty);
      });

      test('a version-12 document parses the manifest key verbatim', () {
        final parsed = parse(12, const {
          'privateConstructions': [construction],
        });
        expect(parsed.privateConstructions, hasLength(1));
        final c = parsed.privateConstructions!.single;
        expect(c.className, '_Helper');
        expect(c.constructor, 'new');
        expect(c.offset, 42);
        // Spelled exactly as the capability manifest spells it, so a grant can
        // be looked up without re-deriving the format.
        expect(c.key, 'package:app/main.dart#_Helper.new');
      });

      test('a version-12 document MISSING the field is malformed', () {
        expect(
          () => RouteBCoverage.fromJson(doc(12, body)),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('privateConstructions'),
            ),
          ),
        );
      });

      test('an unknown version is refused, and names what is understood', () {
        expect(
          () => RouteBCoverage.fromJson(doc(13, body)),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(contains('version 13'), contains('11, 12')),
            ),
          ),
        );
      });
    });

    // MEASUREMENT-STATE CONTRACT (analysis version 11).
    //
    // The analyzer omits `releaseSuperTargets` when it could not build a
    // hierarchy over the release kernel. Parsing must preserve that: `?? const
    // []` at the boundary would convert "we did not look" into the positive
    // claim "the release called nothing".
    group('releaseSuperTargets measurement state', () {
      String loweringDoc(Map<String, Object?> lowering) => jsonEncode({
        'analysisVersion': supportedRouteBAnalysisVersion,
        'verdict': 'accept',
        'changed': <String>[],
        'added': <String>[],
        'removed': <String>[],
        'patchable': <String>[],
        'conditional': <String>[],
        'rejections': <Map<String, Object?>>[],
        'refusalSummary': null,
        'lowering': {'package:app/main.dart#Thing.go': lowering},
      });

      const base = {
        'receiverType': 'Thing',
        'nameOffset': 0,
        'accesses': <Object>[],
        'unsupported': <String>[],
        'origin': {
          'library': 'package:app/main.dart',
          'class': 'Thing',
          'member': 'go',
          'memberKind': 'Method',
        },
        'superInvocations': <Object>[],
      };

      const provenance = {
        'fileUri': 'file:///app/lib/main.dart',
        'fileOffset': 10,
        'name': 'close',
        'kind': 'Method',
      };

      RouteBLowering parseLowering(Map<String, Object?> extra) {
        final c = RouteBCoverage.fromJson(loweringDoc({...base, ...extra}));
        return c.lowering['package:app/main.dart#Thing.go']!;
      }

      test('A: field ABSENT parses as null — measurement unavailable', () {
        expect(parseLowering(const {}).releaseSuperTargets, isNull);
      });

      test('B: field [] parses as empty — measured, called nothing', () {
        expect(
          parseLowering(const {'releaseSuperTargets': <Object>[]})
              .releaseSuperTargets,
          isEmpty,
        );
      });

      test('C: field [target] parses the exact provenance', () {
        final got = parseLowering(const {
          'releaseSuperTargets': [provenance],
        }).releaseSuperTargets;
        expect(got, hasLength(1));
        expect(got!.single.name, 'close');
        expect(got.single.kind, 'Method');
        expect(got.single.fileOffset, 10);
      });

      test('absent and empty are not equal', () {
        expect(
          parseLowering(const {}).releaseSuperTargets,
          isNot(parseLowering(const {'releaseSuperTargets': <Object>[]})
              .releaseSuperTargets),
        );
      });
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
