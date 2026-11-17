import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/route_b_capabilities.dart';
import 'package:shorebird_cli/src/route_b_compiler.dart';
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_producer.dart';
import 'package:shorebird_cli/src/route_b_retention.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'mocks.dart';

/// The shape of a release interface, as `gen_dynamic_interface.dart` writes it:
/// the app library whole, a few SDK members by name, a private top-level
/// member, a dependency member the release's own code named, and the classes
/// the release's code named as types.
const _interface = '''
callable:
  - library: 'package:app/main.dart'
  - library: 'dart:core'
    class: 'DateTime'
    member: 'now'
  - library: 'dart:core'
    member: 'print'
  - library: 'package:app/main.dart'
    member: '_secret'
  - library: 'package:crypto/src/sha256.dart'
    member: 'get:sha256'
can-be-used-as-type:
  - library: 'dart:core'
    class: ['DateTime', 'String', 'int']
  - library: 'package:crypto/src/hash.dart'
    class: ['Hash']
''';

const _grants = '''
{
  "policy": "p2",
  "privateTopLevelCallable": ["package:app/main.dart#_secret"],
  "privateStaticsCallable": [],
  "privateInstanceCallable": [],
  "privateClassPublicMembers": [],
  "privateClassesConstructible": [],
  "refused": []
}
''';

const _target = 'package:app/main.dart#build';

Map<String, Object?> _ref(
  String kind,
  String library, {
  String? cls,
  String? member,
  bool private = false,
  bool viaConstant = false,
}) => {
  'kind': kind,
  'library': library,
  'class': cls,
  'member': member,
  'private': private,
  if (viaConstant) 'viaConstant': true,
};

/// A version-18 analysis whose `build` names [references], with [helpers]
/// (key -> references) the patch carries and `build` calls.
RouteBCoverage _analysis(
  List<Map<String, Object?>> references, {
  Map<String, List<Map<String, Object?>>> helpers = const {},
  int version = 18,
  Set<String> omit = const {},
}) => RouteBCoverage.fromJson(
  jsonEncode({
    'analysisVersion': version,
    'verdict': 'accept',
    'changed': [_target],
    'carried': <String>[],
    'callers': {
      for (final h in helpers.keys) h: [_target],
    },
    'added': helpers.keys.toList(),
    'helpers': helpers.keys.toList(),
    'unusedHelpers': <String>[],
    'removed': <String>[],
    'patchable': [_target],
    'conditional': <String>[],
    'sources': <String, Object?>{},
    if (version >= 18)
      'externalReferences': {
        for (final e in {_target: references, ...helpers}.entries)
          if (!omit.contains(e.key)) e.key: e.value,
      },
    'rejections': <Object>[],
    'refusalSummary': null,
  }),
);

void main() {
  useTempWorkingDirectory();

  late RouteBRetention retention;

  setUp(() {
    retention = RouteBRetention.parse(
      _interface,
      capabilities: RouteBCapabilities.fromJson(_grants),
    );
  });

  String? refusal(
    List<Map<String, Object?>> references, {
    RouteBRetention? with_,
    Map<String, List<Map<String, Object?>>> helpers = const {},
  }) => (with_ ?? retention).refusalForTarget(
    _analysis(references, helpers: helpers),
    _target,
  );

  group(RouteBRetention, () {
    group('accepts', () {
      test('a retained SDK call', () {
        expect(
          refusal([
            _ref('static', 'dart:core', cls: 'DateTime', member: 'now'),
            _ref('top-level', 'dart:core', member: 'print'),
            _ref('class', 'dart:core', cls: 'String'),
          ]),
          isNull,
        );
      });

      test('a retained app symbol', () {
        // The library item keeps every public member of the library whole.
        expect(
          refusal([
            _ref('top-level', 'package:app/main.dart', member: 'routeBHelper'),
            _ref('class', 'package:app/main.dart', cls: 'Home'),
            _ref(
              'constructor',
              'package:app/main.dart',
              cls: 'Home',
              member: '',
            ),
          ]),
          isNull,
        );
      });

      test('a private member the capability manifest granted', () {
        expect(
          refusal([
            _ref(
              'top-level',
              'package:app/main.dart',
              member: '_secret',
              private: true,
            ),
          ]),
          isNull,
        );
      });

      test('a reference resolved through the replacement\'s own helpers', () {
        // The analysis leaves a reference to a carried helper out of the
        // target's list and reports the helper's own body under the helper's
        // key. Retained code in both is accepted.
        expect(
          refusal(
            [_ref('top-level', 'dart:core', member: 'print')],
            helpers: {
              'package:app/main.dart#_label': [
                _ref('static', 'dart:core', cls: 'DateTime', member: 'now'),
              ],
            },
          ),
          isNull,
        );
      });

      test('a device-proven instance member of a dart: class', () {
        expect(
          refusal([
            _ref('instance', 'dart:core', cls: 'List', member: 'add'),
            _ref('instance', 'dart:core', cls: 'Iterable', member: 'join'),
            _ref('instance', 'dart:core', cls: 'num', member: '+'),
            _ref('instance', 'dart:core', cls: 'int', member: '<'),
            _ref('instance', 'dart:core', cls: 'Object', member: 'toString'),
            _ref('instance', 'dart:core', cls: 'String', member: 'split'),
          ]),
          isNull,
        );
      });

      test('a dart: instance member named by a constant, which the '
          'interface keeps', () {
        final kept = RouteBRetention.parse('''
callable:
  - library: 'dart:core'
    class: 'Duration'
    member: 'inMilliseconds'
''');
        expect(
          refusal([
            _ref(
              'instance',
              'dart:core',
              cls: 'Duration',
              member: 'inMilliseconds',
              viaConstant: true,
            ),
          ], with_: kept),
          isNull,
        );
      });

      test('an SDK instance member the interface lists by name', () {
        final listed = RouteBRetention.parse('''
callable:
  - library: 'dart:core'
    class: 'DateTime'
    member: 'get:millisecondsSinceEpoch'
''');
        expect(
          refusal([
            _ref(
              'instance',
              'dart:core',
              cls: 'DateTime',
              member: 'get:millisecondsSinceEpoch',
            ),
          ], with_: listed),
          isNull,
        );
      });

      test('an extension METHOD the interface lists', () {
        final listed = RouteBRetention.parse('''
callable:
  - library: 'package:collection/src/iterable_extensions.dart'
    member: 'IterableExtension|sorted'
''');
        expect(
          refusal([
            _ref(
              'top-level',
              'package:collection/src/iterable_extensions.dart',
              member: 'IterableExtension|sorted',
            ),
          ], with_: listed),
          isNull,
        );
      });

      test('the w16 shape: --include keeps a framework member out of the '
          'changed set', () {
        // `Theme.of(context).textTheme.headlineMedium` in build. Run WITHOUT
        // --include, the analyzer called `IconData.hashCode` (framework code
        // the release kept in its own library) a changed member, and its
        // `Object.hash` is a static the release never named: the whole patch
        // was refused for an edit that touched no framework code. With the
        // release's own `package:<app>/` prefix only `build` changed.
        const framework =
            'package:flutter/src/widgets/icon_data.dart#IconData.get:hashCode';
        RouteBCoverage analysis(List<String> changed) =>
            RouteBCoverage.fromJson(
              jsonEncode({
                'analysisVersion': 18,
                'verdict': 'accept',
                'changed': changed,
                'carried': <String>[],
                'callers': <String, Object?>{},
                'added': <String>[],
                'helpers': <String>[],
                'unusedHelpers': <String>[],
                'removed': <String>[],
                'patchable': changed,
                'conditional': <String>[],
                'sources': <String, Object?>{},
                'externalReferences': {
                  _target: [
                    _ref('top-level', 'dart:core', member: 'print'),
                  ],
                  framework: [
                    _ref('static', 'dart:core', cls: 'Object', member: 'hash'),
                  ],
                },
                'rejections': <Object>[],
                'refusalSummary': null,
              }),
            );
        final withoutInclude = analysis([framework, _target]);
        final withInclude = analysis([_target]);
        expect(
          retention.refusal(withoutInclude, withoutInclude.changed),
          contains('Object.hash'),
        );
        expect(retention.refusal(withInclude, withInclude.changed), isNull);
      });

      test('an analysis that predates version 18, which lists nothing', () {
        final old = _analysis(const [], version: 17);
        expect(old.externalReferences, isNull);
        expect(retention.refusalForTarget(old, _target), isNull);
      });
    });

    group('refuses, naming the symbol, and says a new release is needed', () {
      void expectKeptNothing(String? reason, String symbol) {
        expect(reason, isNotNull);
        expect(reason, contains(symbol));
        expect(reason, contains('never used in its own code'));
        expect(reason, contains('new release'));
      }

      test('a dependency API the release never called', () {
        expectKeptNothing(
          refusal([
            _ref(
              'top-level',
              'package:crypto/src/md5.dart',
              member: 'get:md5',
            ),
          ]),
          '`md5` (package:crypto/src/md5.dart)',
        );
      });

      test('a member of a library the release kept only in part', () {
        expectKeptNothing(
          refusal([
            _ref(
              'static',
              'dart:core',
              cls: 'int',
              member: 'parse',
            ),
          ]),
          '`int.parse`',
        );
      });

      test('a class the release never named as a type', () {
        expectKeptNothing(
          refusal([_ref('class', 'dart:core', cls: 'Duration')]),
          'class `Duration`',
        );
      });

      test('a private member that is not in the capability manifest', () {
        expectKeptNothing(
          refusal([
            _ref(
              'top-level',
              'package:app/main.dart',
              member: '_hidden',
              private: true,
            ),
          ]),
          'private member `_hidden`',
        );
      });

      test('a private member when the release published no manifest', () {
        expectKeptNothing(
          refusal(
            [
              _ref(
                'top-level',
                'package:app/main.dart',
                member: '_secret',
                private: true,
              ),
            ],
            with_: RouteBRetention.parse(_interface),
          ),
          'private member `_secret`',
        );
      });

      test('a private member the manifest recorded as skipped', () {
        final skipped = RouteBRetention.parse(
          _interface,
          capabilities: RouteBCapabilities.fromJson(
            _grants.replaceFirst(
              '"refused": []',
              '"refused": ["package:app/main.dart#_secret (not indexable)"]',
            ),
          ),
        );
        expect(
          refusal(
            [
              _ref(
                'top-level',
                'package:app/main.dart',
                member: '_secret',
                private: true,
              ),
            ],
            with_: skipped,
          ),
          contains('`_secret`'),
        );
      });

      test('a symbol named only by a helper the patch carries', () {
        expectKeptNothing(
          refusal(
            [_ref('top-level', 'dart:core', member: 'print')],
            helpers: {
              'package:app/main.dart#_label': [
                _ref('static', 'dart:core', cls: 'int', member: 'parse'),
              ],
            },
          ),
          '`int.parse`',
        );
      });

      test('a body the analyzer could not walk', () {
        final reason = refusal([
          {'kind': 'unanalyzed', 'reason': 'the body could not be walked: x'},
        ]);
        expect(reason, contains('could not tell'));
        expect(reason, contains('new release'));
      });

      test(
        'an instance member of a non-dart: class the release never named',
        () {
          expectKeptNothing(
            refusal([
              _ref(
                'instance',
                'package:flutter/src/material/theme_data.dart',
                cls: 'ThemeData',
                member: 'get:textTheme',
              ),
            ]),
            '`ThemeData.textTheme`',
          );
        },
      );

      test('names five symbols and counts the rest', () {
        final reason = refusal([
          for (var i = 0; i < 7; i++)
            _ref('top-level', 'package:x/x.dart', member: 'f$i'),
        ]);
        expect(reason, contains('`f0`'));
        expect(reason, contains('and 2 more'));
        expect(reason, isNot(contains('`f6`')));
      });
    });

    group('the rules the loader sets', () {
      test('an instance member the release never recorded is refused', () {
        // Its class is kept, the member is not: the loader would bind it
        // through a stand-in and the call would throw NoSuchMethodError.
        expect(
          refusal([
            _ref(
              'instance',
              'package:crypto/src/hash.dart',
              cls: 'Hash',
              member: 'get:blockSize',
            ),
          ]),
          allOf(contains('`Hash.blockSize`'), contains('new release')),
        );
      });

      test('an instance member the release recorded is accepted', () {
        final recorded = RouteBRetention.parse("""
callable:
  - library: 'package:crypto/src/hash.dart'
    class: 'Hash'
    member: 'get:blockSize'
""");
        expect(
          refusal([
            _ref(
              'instance',
              'package:crypto/src/hash.dart',
              cls: 'Hash',
              member: 'get:blockSize',
            ),
          ], with_: recorded),
          isNull,
        );
      });

      test('an SDK instance member the release was not shown to keep', () {
        // The audit's w31, E14, e11, e12: each threw NoSuchMethodError on a
        // release that never called the member, after passing every check.
        for (final (cls, member) in [
          ('String', 'toUpperCase'),
          ('String', 'substring'),
          ('Stream', 'where'),
          ('Future', 'catchError'),
          ('Duration', 'inMilliseconds'),
          ('List', 'contains'),
        ]) {
          final reason = refusal([
            _ref(
              'instance',
              cls == 'Stream' || cls == 'Future' ? 'dart:async' : 'dart:core',
              cls: cls,
              member: member,
            ),
          ]);
          expect(
            reason,
            allOf(
              contains('`$cls.$member`'),
              contains('NoSuchMethodError'),
              contains('Cut a new release'),
            ),
            reason: '$cls.$member',
          );
        }
      });

      test('every host-measured SDK instance member is accepted', () {
        expect(routeBHostMeasuredSdkInstanceMembers, isNotEmpty);
        for (final key in routeBHostMeasuredSdkInstanceMembers) {
          final [library, cls, member] = key.split('#');
          expect(
            refusal([_ref('instance', library, cls: cls, member: member)]),
            isNull,
            reason: key,
          );
        }
      });

      test('the measured lists do not overlap', () {
        for (final key in routeBHostMeasuredFailingSdkInstanceMembers.keys) {
          expect(routeBHostMeasuredSdkInstanceMembers, isNot(contains(key)));
          expect(routeBDeviceProvenSdkInstanceMembers, isNot(contains(key)));
        }
      });

      test('a member measured to throw is refused and the message says so', () {
        final reason = refusal([
          _ref('instance', 'dart:async', cls: 'Stream', member: 'listen'),
        ]);
        expect(
          reason,
          allOf(
            contains('`Stream.listen`'),
            contains('measured: throws NoSuchMethodError'),
          ),
        );
      });

      test('a member measured to stop the app is refused and named', () {
        final reason = refusal([
          _ref(
            'instance',
            'dart:core',
            cls: 'String',
            member: 'get:isNotEmpty',
          ),
        ]);
        expect(
          reason,
          allOf(
            contains('String.isNotEmpty'),
            contains('measured: the release stops the app'),
          ),
        );
      });

      test('says so once for several SDK instance members', () {
        final reason = refusal([
          for (final m in ['a', 'b', 'c', 'd', 'e', 'f', 'g'])
            _ref('instance', 'dart:core', cls: 'String', member: m),
        ]);
        expect(reason, contains('and 2 more'));
        expect(reason, isNot(contains('the loader stops the app')));
      });

      test('both kinds of refusal in one sentence each', () {
        final reason = refusal([
          _ref('instance', 'dart:core', cls: 'String', member: 'toUpperCase'),
          _ref('top-level', 'dart:core', member: 'identical'),
        ]);
        expect(reason, contains('the loader stops the app'));
        expect(reason, contains('NoSuchMethodError'));
      });

      test(
        'an extension getter, even in a library the interface keeps whole',
        () {
          // e22 and E13: the generator skips `#` members, so the whole-library
          // rule says nothing about them, and the loader aborts at load.
          final reason = refusal([
            _ref(
              'top-level',
              'package:app/main.dart',
              member: 'TallyInt|get#tallyBars',
            ),
          ]);
          expect(
            reason,
            allOf(
              contains('the extension member `TallyInt|get#tallyBars`'),
              contains('Cut a new release'),
            ),
          );
        },
      );

      test('an extension getter of the SDK (the record .wait)', () {
        expect(
          refusal([
            _ref(
              'top-level',
              'dart:async',
              member: 'FutureRecord2|get#wait',
            ),
          ]),
          contains('FutureRecord2|get#wait'),
        );
      });

      test('an extension getter only when the interface itself lists it', () {
        final listed = RouteBRetention.parse('''
callable:
  - library: 'package:app/main.dart'
    member: 'TallyInt|get#tallyBars'
''');
        expect(
          refusal([
            _ref(
              'top-level',
              'package:app/main.dart',
              member: 'TallyInt|get#tallyBars',
            ),
          ], with_: listed),
          isNull,
        );
      });

      test('a bare class item keeps its public members', () {
        final bare = RouteBRetention.parse("""
callable:
  - library: 'package:dep/dep.dart'
    class: 'Box'
""");
        expect(
          refusal([
            _ref('instance', 'package:dep/dep.dart', cls: 'Box', member: 'x'),
            _ref('static', 'package:dep/dep.dart', cls: 'Box', member: 'y'),
          ], with_: bare),
          isNull,
        );
        expect(
          refusal([
            _ref('static', 'package:dep/dep.dart', cls: 'Other', member: 'y'),
          ], with_: bare),
          isNotNull,
        );
      });

      test('a private class named as a type is kept by the interface', () {
        final typed = RouteBRetention.parse(
          """
can-be-used-as-type:
  - library: 'package:app/main.dart'
    class: ['_Marker']
""",
          capabilities: RouteBCapabilities.fromJson(_grants),
        );
        expect(
          refusal([
            _ref(
              'class',
              'package:app/main.dart',
              cls: '_Marker',
              private: true,
            ),
          ], with_: typed),
          isNull,
        );
      });

      test('a private construction is left to the release evidence', () {
        // The manifest withholds every private construction; analysis 12's
        // per-method evidence decides, so this check must not refuse it.
        expect(
          refusal([
            _ref(
              'constructor',
              'package:app/main.dart',
              cls: '_Home',
              member: '',
              private: true,
            ),
          ]),
          isNull,
        );
      });

      test('a framework library is not spelled in the refusal', () {
        final why = refusal([
          _ref(
            'constructor',
            'package:flutter/src/widgets/basic.dart',
            cls: 'Padding',
            member: '',
          ),
        ]);
        expect(why, contains('`Padding`'));
        expect(why, isNot(contains('package:flutter')));
      });
    });

    group('a target the analysis recorded nothing for', () {
      test('is refused, not read as using nothing', () {
        final coverage = _analysis(const [], omit: {_target});
        expect(
          retention.refusalForTarget(coverage, _target),
          allOf(contains('`build`'), contains('recorded nothing')),
        );
      });

      test('is refused when it is a helper the target needs', () {
        const helper = 'package:app/main.dart#_extra';
        final coverage = _analysis(
          const [],
          helpers: {helper: const []},
          omit: {helper},
        );
        expect(
          retention.refusalForTarget(coverage, _target),
          contains('`_extra`'),
        );
      });
    });

    group('reads an interface', () {
      test('that is not YAML, or not a mapping, as unreadable', () {
        expect(() => RouteBRetention.parse(':\n - ['), throwsFormatException);
        expect(() => RouteBRetention.parse('- a'), throwsFormatException);
      });

      test('and answers null for a missing file, never an empty set', () {
        expect(RouteBRetention.read(null), isNull);
        expect(RouteBRetention.read(File('/no/such/file.yaml')), isNull);
      });
      test('with a malformed section, as unreadable', () {
        for (final bad in [
          'callable: 1',
          'callable:\n  - 1',
          "callable:\n  - class: 'A'",
          'can-be-used-as-type:\n  - class: [A]',
        ]) {
          expect(
            () => RouteBRetention.parse(bad),
            throwsFormatException,
            reason: bad,
          );
        }
      });

      test('from a file, or null when the file is not an interface', () {
        final dir = Directory.systemTemp.createTempSync();
        addTearDown(() => dir.deleteSync(recursive: true));
        final good = File(p.join(dir.path, 'good.yaml'))
          ..writeAsStringSync(_interface);
        final bad = File(p.join(dir.path, 'bad.yaml'))
          ..writeAsStringSync('- a');
        expect(RouteBRetention.read(good), isNotNull);
        expect(RouteBRetention.read(bad), isNull);
      });
    });

    group('a private member answers to the manifest', () {
      final manifest = RouteBCapabilities.fromJson('''
{
  "policy": "p2",
  "privateTopLevelCallable": [],
  "privateStaticsCallable": ["package:app/main.dart#_K#_s"],
  "privateInstanceCallable": ["package:app/main.dart#_K#_i"],
  "privateClassPublicMembers": ["package:app/main.dart#_K#pub"],
  "privateClassesConstructible": [],
  "refused": []
}
''');
      late RouteBRetention withManifest;
      setUp(() {
        withManifest = RouteBRetention.parse(
          _interface,
          capabilities: manifest,
        );
      });

      String? ask(String kind, String cls, String? member) => refusal([
        _ref(
          kind,
          'package:app/main.dart',
          cls: cls,
          member: member,
          private: true,
        ),
      ], with_: withManifest);

      test('a granted private static, instance member or public member', () {
        expect(ask('static', '_K', '_s'), isNull);
        expect(ask('instance', '_K', '_i'), isNull);
        expect(ask('instance', '_K', 'pub'), isNull);
      });

      test('an ungranted one, and a private top-level the manifest lacks', () {
        expect(ask('static', '_K', '_other'), isNotNull);
        expect(ask('top-level', '', '_nope'), isNotNull);
      });

      test('a private class the manifest lists a member of', () {
        expect(ask('class', '_K', null), isNull);
        expect(ask('class', '_Unknown', null), isNotNull);
      });
    });
  });

  group('the producer', () {
    late Directory cell;
    late Directory work;
    late Directory project;
    late File source;
    late ShorebirdLogger logger;
    var compiled = 0;

    const declaration = "String build() => 'NEW';";

    RouteBCompiler compiler() => RouteBCompiler(
      supportsDirectSuperDualKernel: true,
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

    RouteBCoverage coverage(
      List<Map<String, Object?>> references, {
      int version = 18,
    }) => RouteBCoverage.fromJson(
      jsonEncode({
        'analysisVersion': version,
        'verdict': 'accept',
        'changed': [_target],
        'carried': <String>[],
        'callers': <String, Object?>{},
        'added': <String>[],
        'helpers': <String>[],
        'unusedHelpers': <String>[],
        'removed': <String>[],
        'patchable': [_target],
        'conditional': <String>[],
        'sources': {
          _target: {
            'fileUri': source.uri.toString(),
            'start': 0,
            'end': declaration.length,
          },
        },
        if (version >= 18) 'externalReferences': {_target: references},
        'rejections': <Object>[],
        'refusalSummary': null,
      }),
    );

    ProcessResult compileOk(String executable, List<String> arguments) {
      compiled++;
      final output = arguments[arguments.indexOf('-o') + 1];
      File(output).writeAsStringSync('BYTECODE');
      return ProcessResult(0, 0, '', '');
    }

    void produce(RouteBCoverage analysis, {RouteBRetention? kept}) => runScoped(
      () => const RouteBProducer().produce(
        compiler: compiler(),
        coverage: analysis,
        releaseImportKernel: File(p.join(cell.path, 'release_import.dill')),
        releaseBuildId: 'deadbeef',
        workingDirectory: work,
        projectRoot: project,
        run: compileOk,
        retention: kept,
      ),
      values: {loggerRef.overrideWith(() => logger)},
    );

    setUp(() {
      compiled = 0;
      cell = Directory.systemTemp.createTempSync('cell');
      work = Directory.systemTemp.createTempSync('work');
      project = Directory.systemTemp.createTempSync('project');
      logger = MockShorebirdLogger();
      source = File(p.join(project.path, 'main.dart'))
        ..writeAsStringSync(declaration);
    });

    test('refuses a target that names a symbol never used in its own code, '
        'before compiling', () {
      expect(
        () => produce(
          coverage([
            _ref('top-level', 'package:crypto/src/md5.dart', member: 'get:md5'),
          ]),
          kept: retention,
        ),
        throwsA(
          isA<RouteBUnsupportedTarget>()
              .having((e) => e.target, 'target', _target)
              .having((e) => e.reason, 'reason', contains('`md5`'))
              .having(
                (e) => e.reason,
                'reason',
                contains('never used in its own code'),
              ),
        ),
      );
      expect(compiled, 0);
    });

    test('refuses an analysis it can check when the release has no readable '
        'interface', () {
      expect(
        () => produce(
          coverage([_ref('top-level', 'dart:core', member: 'print')]),
        ),
        throwsA(
          isA<RouteBUnsupportedTarget>().having(
            (e) => e.reason,
            'reason',
            contains('no readable dynamic interface'),
          ),
        ),
      );
      expect(compiled, 0);
    });

    test('compiles a target whose every symbol the release kept', () {
      produce(
        coverage([_ref('top-level', 'dart:core', member: 'print')]),
        kept: retention,
      );
      expect(compiled, 1);
    });

    test('is unchanged for an analysis of version 17, interface or not', () {
      produce(coverage(const [], version: 17));
      expect(compiled, 1);
    });
  });
}
