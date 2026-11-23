import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  useTempWorkingDirectory();
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

    group('routeBAppIncludePrefixes', () {
      test('names the app library prefix the release used', () {
        expect(routeBAppIncludePrefixes('shapes'), ['package:shapes/']);
      });

      test('is empty when the package cannot be named', () {
        expect(routeBAppIncludePrefixes(null), isEmpty);
        expect(routeBAppIncludePrefixes(''), isEmpty);
      });
    });

    group('RouteBCoverageAnalyzer argument list', () {
      // Pinned because the patcher and the release must agree on --include,
      // and the analyzer is an opaque binary: a changed order or a dropped
      // prefix would still run.
      late Directory cell;

      setUp(() => cell = Directory.systemTemp.createTempSync('cell'));

      RouteBCompiler fakeCompiler(File argsOut) {
        final runtime = File(p.join(cell.path, 'runtime.sh'))
          ..writeAsStringSync('''
#!/bin/sh
shift
printf '%s\\n' "\$@" > ${argsOut.path}
cat <<'JSON'
{"analysisVersion":11,"verdict":"inert","changed":[],"added":[],"removed":[],"patchable":[],"conditional":[],"rejections":[],"refusalSummary":null}
JSON
''');
        Process.runSync('chmod', ['+x', runtime.path]);
        File f(String n) => File(p.join(cell.path, n));
        return RouteBCompiler(
          supportsDirectSuperDualKernel: true,
          runtime: runtime,
          compilerSnapshot: f('c'),
          platformDill: f('p'),
          analyzer: f('analyzer.aot'),
          frontend: f('fe'),
          interfaceGenerator: f('gen'),
          releaseProbe: f('probe'),
          flutterPlatformDill: f('fp'),
          provenance: '',
        );
      }

      test('passes each include prefix, then each carry', () {
        final out = File(p.join(cell.path, 'args.txt'));
        const RouteBCoverageAnalyzer().analyze(
          compiler: fakeCompiler(out),
          baseDill: File('base.dill'),
          patchedDill: File('patched.dill'),
          includePrefixes: routeBAppIncludePrefixes('shapes'),
          carry: {'b#two', 'a#one'},
        );
        expect(out.readAsLinesSync(), [
          '--base-dill',
          File('base.dill').path,
          '--patched-dill',
          File('patched.dill').path,
          '--include',
          'package:shapes/',
          '--carry',
          'a#one',
          '--carry',
          'b#two',
        ]);
      });

      test('passes no --include when there is no prefix', () {
        final out = File(p.join(cell.path, 'args.txt'));
        const RouteBCoverageAnalyzer().analyze(
          compiler: fakeCompiler(out),
          baseDill: File('base.dill'),
          patchedDill: File('patched.dill'),
        );
        expect(out.readAsStringSync(), isNot(contains('--include')));
      });
    });

    group('instance helpers (analysis version 17)', () {
      String v17({int version = 17}) => jsonEncode({
        'analysisVersion': version,
        'verdict': 'reject',
        'changed': ['a#Box.show'],
        'carried': <String>[],
        'callers': {
          'a#Box._h': ['a#Box.show'],
        },
        'added': ['a#Box._h', 'a#Box._s'],
        'helpers': ['a#Box._h'],
        'unusedHelpers': <String>[],
        'removed': <String>[],
        'patchable': ['a#Box.show'],
        'conditional': <String>[],
        'sources': {
          'a#Box.show': {'fileUri': 'file:///a.dart', 'start': 0, 'end': 9},
          'a#Box._h': {'fileUri': 'file:///a.dart', 'start': 10, 'end': 19},
        },
        'lowering': {
          for (final key in ['a#Box.show', 'a#Box._h'])
            key: {
              'receiverType': 'Box',
              'nameOffset': 3,
              'accesses': [
                {'offset': 4, 'member': '_h', 'kind': 'helperCall'},
                {'offset': 8, 'member': 'tag', 'kind': 'get'},
              ],
              'unsupported': <String>[],
              'privateConstructions': <Object>[],
            },
        },
        'rejections': [
          {
            'target': 'a#Box._s',
            'category': 'added',
            'reason': 'new member, and a static member of `Box`',
          },
        ],
        'refusalSummary': null,
      });

      test('reads an instance helper, its lowering and the helperCall '
          'access', () {
        final coverage = RouteBCoverage.fromJson(v17());
        expect(coverage.helpers, ['a#Box._h']);
        expect(coverage.lowering.keys, containsAll(['a#Box.show', 'a#Box._h']));
        final access = coverage.lowering['a#Box._h']!.accesses.first;
        expect(access.kind, 'helperCall');
        expect(access.privateTarget, isNull);
        expect(coverage.sources['a#Box._h'], isNotNull);
      });

      test('the refusal counts only the new members that are refused', () {
        expect(
          RouteBCoverage.fromJson(v17()).refusalMessage,
          contains('1 of 2 changed members'),
        );
      });

      test('a release callers list leaves out the helper', () {
        final coverage = RouteBCoverage.fromJson(
          v17().replaceFirst(
            '"a#Box._h":["a#Box.show"]',
            '"a#Box.show":["a#Box._h"]',
          ),
        );
        expect(coverage.releaseCallersOf('a#Box.show'), isEmpty);
      });

      test('a version 16 document is still read, as before', () {
        expect(RouteBCoverage.fromJson(v17(version: 16)).helpers, isNotEmpty);
        expect(knownRouteBAnalysisVersions, containsAll([16, 17]));
      });

      test('a version 17 document lists no external references, which is '
          '"not measured", never "none"', () {
        expect(RouteBCoverage.fromJson(v17()).externalReferences, isNull);
      });

      test('a version 18 document lists them, and one without the field is '
          'refused', () {
        final withReferences = RouteBCoverage.fromJson(
          v17(version: 18).replaceFirst(
            '"rejections"',
            '"externalReferences":{"a#Box.show":[{"kind":"static",'
                '"library":"dart:core","class":"int","member":"parse",'
                '"private":false}]},"rejections"',
          ),
        );
        final reference =
            withReferences.externalReferences!['a#Box.show']!.single;
        expect(reference.kind, 'static');
        expect(reference.displayName, 'int.parse');
        expect(knownRouteBAnalysisVersions, contains(18));
        expect(
          () => RouteBCoverage.fromJson(v17(version: 18)),
          throwsFormatException,
        );
      });

      test('a version 19 document reads the dynamic and tear-off kinds, and '
          'the gate version is 19', () {
        final document = RouteBCoverage.fromJson(
          v17(version: 19).replaceFirst(
            '"rejections"',
            '"externalReferences":{"a#Box.show":[{"kind":"dynamic",'
                '"library":"","class":"","member":"[]","private":false},'
                '{"kind":"instance","library":"dart:core","class":"List",'
                '"member":"tearoff:add","private":false}]},"rejections"',
          ),
        );
        final references = document.externalReferences!['a#Box.show']!;
        expect(references.first.kind, 'dynamic');
        expect(references.last.member, 'tearoff:add');
        expect(knownRouteBAnalysisVersions, contains(19));
        expect(routeBSelectorCallsAnalysisVersion, 19);
        expect(
          () => RouteBCoverage.fromJson(v17(version: 19)),
          throwsFormatException,
        );
      });
    });

    group('extension receivers (analysis version 22)', () {
      String withExtension(int version) => jsonEncode({
        'analysisVersion': version,
        'verdict': 'accept',
        'changed': ['a#Stars|get#stars'],
        'added': <String>[],
        'removed': <String>[],
        'patchable': <String>[],
        'conditional': ['a#Stars|get#stars'],
        'carried': <String>[],
        'callers': <String, Object>{},
        'helpers': <String>[],
        'unusedHelpers': <String>[],
        'externalReferences': <String, Object>{},
        'lowering': {
          'a#Stars|get#stars': {
            'receiverType': 'int',
            'extension': 'Stars',
            'nameOffset': 3,
            'accesses': [
              {'offset': 4, 'member': 'this', 'kind': 'receiver'},
            ],
            'unsupported': <String>[],
            'privateConstructions': <Object>[],
          },
        },
        'rejections': <Object>[],
        'refusalSummary': null,
      });

      test('a version 22 document names the extension', () {
        final lowering = RouteBCoverage.fromJson(
          withExtension(22),
        ).lowering['a#Stars|get#stars']!;
        expect(lowering.extensionName, 'Stars');
        expect(lowering.accesses.single.kind, 'receiver');
        expect(knownRouteBAnalysisVersions, contains(22));
        expect(routeBExtensionReceiverAnalysisVersion, 22);
      });

      test('an extension named by an older analysis is malformed', () {
        expect(
          () => RouteBCoverage.fromJson(withExtension(21)),
          throwsFormatException,
        );
      });
    });

    group('helpers (analysis version 16)', () {
      String v16({
        List<String> added = const ['a#h1', 'a#h2', 'a#nope'],
        Object? helpers = const ['a#h1'],
        Object? unusedHelpers = const ['a#h2'],
      }) => jsonEncode({
        'analysisVersion': 16,
        'verdict': 'reject',
        'changed': ['a#alpha'],
        'carried': <String>[],
        'callers': <String, Object>{},
        'added': added,
        'helpers': ?helpers,
        'unusedHelpers': ?unusedHelpers,
        'removed': <String>[],
        'patchable': ['a#alpha'],
        'conditional': <String>[],
        'rejections': [
          {
            'target': 'a#nope',
            'category': 'added',
            'reason': 'new member, and a setter',
          },
        ],
        'refusalSummary': null,
      });

      test('reads the helpers and the unused ones', () {
        final coverage = RouteBCoverage.fromJson(v16());
        expect(coverage.helpers, ['a#h1']);
        expect(coverage.unusedHelpers, ['a#h2']);
        expect(coverage.added, ['a#h1', 'a#h2', 'a#nope']);
      });

      test('a version 16 document without helpers is malformed', () {
        expect(
          () => RouteBCoverage.fromJson(v16(helpers: null)),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"helpers"'),
            ),
          ),
        );
      });

      test('the refusal counts only the new members that are refused', () {
        final message = RouteBCoverage.fromJson(v16()).refusalMessage;
        expect(message, contains('1 of 2 changed members'));
      });

      test('an older analysis reports no helpers, so every addition stays '
          'refused', () {
        final coverage = RouteBCoverage.fromJson(
          document(
            version: 15,
            verdict: 'reject',
            added: ['a#h1'],
            rejections: [
              {
                'target': 'a#h1',
                'category': 'added',
                'reason': 'cannot introduce members',
              },
            ],
          ).replaceFirst('"verdict"', '"carried":[],"callers":{},"verdict"'),
        );
        expect(coverage.helpers, isEmpty);
        expect(coverage.unusedHelpers, isEmpty);
        expect(coverage.refusalMessage, contains('1 of 1'));
      });
    });

    group('carrying (analysis version 15)', () {
      String v15({Object? callers = const <String, Object>{}}) => jsonEncode({
        'analysisVersion': 15,
        'verdict': 'reject',
        'changed': [target],
        'carried': ['package:app/main.dart#caller'],
        'callers': ?callers,
        'added': <String>[],
        'removed': <String>[],
        'patchable': <String>[],
        'conditional': <String>[],
        'rejections': [
          {
            'target': 'package:app/main.dart#caller',
            'category': 'unreachable',
            'reason': 'calls super',
          },
        ],
        'refusalSummary': null,
      });

      test('reads carried members and callers', () {
        final coverage = RouteBCoverage.fromJson(
          v15(
            callers: {
              target: ['package:app/main.dart#caller'],
            },
          ),
        );
        expect(coverage.canCarry, isTrue);
        expect(coverage.carried, ['package:app/main.dart#caller']);
        expect(coverage.callers, {
          target: ['package:app/main.dart#caller'],
        });
      });

      test('a version 15 document without callers is malformed', () {
        expect(
          () => RouteBCoverage.fromJson(v15(callers: null)),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('"callers"'),
            ),
          ),
        );
      });

      test('an older document cannot carry', () {
        final coverage = RouteBCoverage.fromJson(document(version: 14));
        expect(coverage.canCarry, isFalse);
        expect(coverage.carried, isEmpty);
        expect(coverage.callers, isNull);
      });

      test('the refusal says why an unchanged member is in it', () {
        final message = RouteBCoverage.fromJson(v15()).refusalMessage;
        expect(message, contains('1 of 2 members cannot be carried'));
        expect(message, contains('(unchanged, but the release holds a copy'));
      });
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
        expect(() => RouteBCoverage.fromJson(doc(11, body)), returnsNormally);
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

      test('version 13 is accepted', () {
        expect(
          () => RouteBCoverage.fromJson(
            doc(13, {...body, 'privateConstructions': <Object>[]}),
          ),
          returnsNormally,
        );
      });

      test('release evidence: ABSENT stays null on version 13', () {
        // The analyzer omits it when the base could not be examined. Nothing
        // was measured, so nothing may be admitted on it.
        final parsed = parse(13, const {'privateConstructions': <Object>[]});
        expect(parsed.releasePrivateConstructions, isNull);
      });

      test('release evidence: EMPTY is a measurement, not an absence', () {
        final parsed = parse(13, const {
          'privateConstructions': <Object>[],
          'releasePrivateConstructions': <Object>[],
        });
        expect(parsed.releasePrivateConstructions, isNotNull);
        expect(parsed.releasePrivateConstructions, isEmpty);
      });

      test('release evidence: POPULATED carries the manifest key', () {
        final parsed = parse(13, const {
          'privateConstructions': [construction],
          'releasePrivateConstructions': [construction],
        });
        expect(
          parsed.releasePrivateConstructions!.single.key,
          'package:app/main.dart#_Helper.new',
        );
      });

      test('a version-11 or -12 document has no release evidence', () {
        expect(parse(11, const {}).releasePrivateConstructions, isNull);
        expect(
          parse(12, const {
            'privateConstructions': <Object>[],
          }).releasePrivateConstructions,
          isNull,
        );
      });

      test('an unknown version is refused, and names what is understood', () {
        expect(
          () => RouteBCoverage.fromJson(doc(25, body)),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('version 25'),
                contains(
                  '11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24',
                ),
              ),
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
          parseLowering(const {
            'releaseSuperTargets': <Object>[],
          }).releaseSuperTargets,
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
          isNot(
            parseLowering(const {
              'releaseSuperTargets': <Object>[],
            }).releaseSuperTargets,
          ),
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
      test("carries each changed member's source span", () {
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

      test('refuses a class the patch adds, even one over a dart: base', () {
        // `class Ring extends ListBase<int>` inherits `add` from the SDK, which
        // the release may not have kept. The analyzer cannot let a patch add
        // a class at all (`_instanceHelperReason` and the `declaration`
        // category in analyze_coverage.dart; ROUTE_B.md, "A new class in a
        // patch"), so the CLI refuses on the document alone.
        const reason =
            'this class is not in the release -- it is new, or the release '
            'tree-shook it because nothing used it -- and a patch cannot add '
            'one';
        final coverage = RouteBCoverage.fromJson(
          document(
            version: 14,
            verdict: 'reject',
            rejections: [
              {
                'target': 'a#Ring.length',
                'category': 'declaration',
                'reason': reason,
              },
              {
                'target': 'a#ringUse',
                'category': 'added',
                'reason': 'an instance operator/getter/setter of `Ring`',
              },
            ],
          ),
        );

        expect(coverage.verdict, RouteBVerdict.reject);
        expect(
          coverage.refusalMessage,
          allOf(contains('a#Ring.length'), contains(reason)),
        );
      });

      test('counts a changed field among what could not be carried', () {
        // A field or constructor is in neither `changed` nor `added`. Counting
        // only those would report "1 of 0" for a patch refused because of it.
        const reason =
            "this field's initializer or declaration changed; a patch "
            'replaces method bodies only, so the release keeps its own '
            'initial value';
        final coverage = RouteBCoverage.fromJson(
          document(
            version: 14,
            verdict: 'reject',
            rejections: [
              {
                'target': 'a#Home.label',
                'category': 'declaration',
                'reason': reason,
              },
            ],
          ),
        );

        expect(coverage.verdict, RouteBVerdict.reject);
        expect(
          coverage.rejections.single.category,
          RouteBRepresentability.declaration,
        );
        expect(
          coverage.refusalMessage,
          allOf(
            contains('1 of 1 changed members'),
            contains('a#Home.label'),
            contains(reason),
          ),
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
