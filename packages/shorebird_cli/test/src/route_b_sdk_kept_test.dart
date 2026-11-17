// cspell:words tearoff ifaces
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_retention.dart';
import 'package:shorebird_cli/src/route_b_sdk_kept.dart';
import 'package:test/test.dart';

import 'helpers.dart';
import 'route_b_profile_fixture.dart';

const _interface = '''
callable:
  - library: 'package:app/main.dart'
  - library: 'dart:core'
    member: 'print'
''';
const _target = 'package:app/main.dart#build';

Map<String, Object?> _ref(
  String kind,
  String library, {
  String? cls,
  String? member,
}) => {
  'kind': kind,
  'library': library,
  'class': cls,
  'member': member,
  'private': false,
};

RouteBCoverage _analysis(
  List<Map<String, Object?>> references, {
  int version = 19,
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
    'sources': <String, Object?>{},
    'externalReferences': {_target: references},
    'rejections': <Object>[],
    'refusalSummary': null,
  }),
);

void main() {
  useTempWorkingDirectory();

  group(RouteBSnapshotKept, () {
    test('resolves through the super chain, and says stub and absent', () {
      final kept = RouteBSnapshotKept.fromProfileJson(routeBStringProfile);
      expect(kept.hasClass('_OneByteString'), isTrue);
      expect(kept.hasClass('_TwoByteString'), isFalse);
      // On the class itself, on its super class, and on Object.
      expect(kept.resolves('_OneByteString', 'toUpperCase'), isTrue);
      expect(kept.resolves('_OneByteString', 'split'), isTrue);
      expect(kept.resolves('_OneByteString', '=='), isTrue);
      // Present with only a lazy-compile stub: stops the app.
      expect(kept.resolves('_OneByteString', 'endsWith'), isFalse);
      // Not in the chain: NoSuchMethodError.
      expect(kept.resolves('_OneByteString', 'substring'), isNull);
      expect(kept.resolves('Object', 'split'), isNull);
    });

    test('keeps same-named classes of different libraries apart', () {
      // A user `_List` has `remove`; the SDK's does not. Neither the user's
      // class nor its functions may stand in for the SDK's.
      final kept = RouteBSnapshotKept.fromProfileJson(
        routeBProfile({
          'Object': const RouteBProfileClass('Object', routeBCoreLibrary),
          'sdk': const RouteBProfileClass(
            '_List@0150898',
            routeBCoreLibrary,
            parent: 'Object',
          ),
          'user': const RouteBProfileClass(
            '_List',
            'package:app/list.dart',
            parent: 'Object',
            fns: {'remove': '[Optimized] remove'},
          ),
          'userOnly': const RouteBProfileClass('_Map', 'package:app/map.dart'),
        }),
      );
      expect(kept.resolves('_List', 'remove'), isNull);
      expect(kept.hasClass('_List'), isTrue);
      // A class the SDK dropped is not there because an app declares one.
      expect(kept.hasClass('_Map'), isFalse);
      expect(kept.librariesOf('_List'), hasLength(2));
    });

    test('with two SDK classes of one name, every one must resolve', () {
      final kept = RouteBSnapshotKept.fromProfileJson(
        routeBProfile({
          'a': const RouteBProfileClass(
            '_X@1',
            routeBCoreLibrary,
            fns: {'m': '[Optimized] m'},
          ),
          'b': const RouteBProfileClass('_X@2', 'dart:collection'),
        }),
      );
      // `dart:collection` is an SDK library too.
      expect(kept.resolves('_X', 'm'), isNull);
    });

    test('reads only the functions list, not the dispatcher cache', () {
      final kept = RouteBSnapshotKept.fromProfileJson(
        routeBProfile({
          'Object': const RouteBProfileClass('Object', routeBCoreLibrary),
          'C': const RouteBProfileClass(
            'C',
            routeBCoreLibrary,
            parent: 'Object',
            fns: {'endsWith': '[Stub] LazyCompile'},
            decoys: {
              'endsWith': '[Optimized] endsWith',
              'padLeft': '[Optimized] padLeft',
            },
          ),
        }),
      );
      // A dispatcher with code does not mask the stub, or make a member exist.
      expect(kept.resolves('C', 'endsWith'), isFalse);
      expect(kept.resolves('C', 'padLeft'), isNull);
    });

    test('the super class is the super_type_ edge, not the first Type', () {
      // Every class here lists its own declaration type and its interfaces
      // before (or without) a super type. Taking the first Type edge would
      // find `Iface` (or the class itself) as the super class.
      final kept = RouteBSnapshotKept.fromProfileJson(
        routeBProfile({
          'Object': const RouteBProfileClass(
            'Object',
            routeBCoreLibrary,
            fns: {'toString': '[Optimized] toString'},
          ),
          'Iface': const RouteBProfileClass(
            'Iface',
            routeBCoreLibrary,
            parent: 'Object',
          ),
          'Real': const RouteBProfileClass(
            'Real',
            routeBCoreLibrary,
            parent: 'Object',
            fns: {'only': '[Optimized] only'},
          ),
          'Sub': const RouteBProfileClass(
            'Sub',
            routeBCoreLibrary,
            parent: 'Real',
            ifaces: ['Iface'],
          ),
          // No super_type_ at all, only an interface that has `only`.
          'NoSuper': const RouteBProfileClass(
            'NoSuper',
            routeBCoreLibrary,
            ifaces: ['Real'],
          ),
        }),
      );
      expect(kept.resolves('Sub', 'only'), isTrue);
      expect(kept.resolves('Sub', 'toString'), isTrue);
      // An interface is not a super class: nothing is inherited from it.
      expect(kept.resolves('NoSuper', 'only'), isNull);
      expect(kept.resolves('NoSuper', 'toString'), isNull);
    });

    test('a looping or over-long super chain does not resolve', () {
      final loop = RouteBSnapshotKept.fromProfileJson(
        routeBProfile({
          'A': const RouteBProfileClass('A', routeBCoreLibrary, parent: 'B'),
          'B': const RouteBProfileClass(
            'B',
            routeBCoreLibrary,
            parent: 'A',
            fns: {'m': '[O] m'},
          ),
          'C': const RouteBProfileClass('C', routeBCoreLibrary, parent: 'C'),
        }),
      );
      expect(loop.resolves('A', 'm'), isTrue);
      expect(loop.resolves('A', 'absent'), isNull);
      expect(loop.resolves('C', 'm'), isNull);
      // A chain longer than the cap is not followed to its end.
      final long = RouteBSnapshotKept.fromProfileJson(
        routeBProfile({
          for (var i = 0; i < 80; i++)
            'c$i': RouteBProfileClass(
              'c$i',
              routeBCoreLibrary,
              parent: i == 79 ? null : 'c${i + 1}',
              fns: i == 79 ? const {'deep': '[O] deep'} : const {},
            ),
        }),
      );
      expect(long.resolves('c0', 'deep'), isNull);
      expect(long.resolves('c70', 'deep'), isTrue);
    });

    group('is an error for', () {
      Map<String, Object?> good() =>
          jsonDecode(routeBStringProfile) as Map<String, Object?>;
      void rejects(Map<String, Object?> Function(Map<String, Object?>) edit) {
        final text = jsonEncode(edit(good()));
        expect(
          () => RouteBSnapshotKept.fromProfileJson(text),
          throwsFormatException,
        );
      }

      test('a file that is not a snapshot profile', () {
        expect(
          () => RouteBSnapshotKept.fromProfileJson('not json'),
          throwsFormatException,
        );
        expect(
          () => RouteBSnapshotKept.fromProfileJson('{"nodes": []}'),
          throwsFormatException,
        );
      });

      test('a non-integer in the node table', () {
        rejects((d) {
          final nodes = <Object?>[...(d['nodes']! as List)];
          nodes[0] = 'x';
          return d..['nodes'] = nodes;
        });
      });

      test('a node table that is not a whole number of rows', () {
        rejects((d) => d..['nodes'] = [...(d['nodes']! as List), 1]);
      });

      test('a truncated edge table', () {
        rejects((d) {
          final edges = [...(d['edges']! as List)];
          return d..['edges'] = edges.sublist(0, edges.length - 3);
        });
      });

      test('an edge to a node that does not exist', () {
        rejects((d) {
          final edges = [...(d['edges']! as List)];
          edges[2] = 5 * 100000;
          return d..['edges'] = edges;
        });
      });

      test('a name that is not in the strings', () {
        rejects((d) => d..['strings'] = <String>[]);
      });

      test('node_fields that are not strings', () {
        rejects((d) {
          final snapshot = d['snapshot']! as Map<String, Object?>;
          final meta = snapshot['meta']! as Map<String, Object?>;
          meta['node_fields'] = [1, 2, 3, 4, 5];
          return d;
        });
      });
    });

    group('read', () {
      File write(String text) =>
          File(p.join(Directory.current.path, 'profile.json'))
            ..writeAsStringSync(text);

      test('refuses a missing profile, naming the file', () {
        final result = RouteBSnapshotKept.read(null, expectedSha256: 'x');
        expect(result.kept, isNull);
        expect(result.problem, contains('route_b_snapshot_profile.json'));
      });

      test('refuses a profile whose digest is not the recorded one', () {
        final file = write(routeBStringProfile);
        final result = RouteBSnapshotKept.read(file, expectedSha256: 'beef');
        expect(result.kept, isNull);
        expect(result.problem, contains('does not match'));
      });

      test('refuses a profile with no recorded digest', () {
        final result = RouteBSnapshotKept.read(
          write(routeBStringProfile),
          expectedSha256: null,
        );
        expect(result.kept, isNull);
        expect(result.problem, contains('no digest'));
      });

      test('reads a profile that hashes to the recorded digest', () {
        final file = write(routeBStringProfile);
        final digest = sha256.convert(file.readAsBytesSync()).toString();
        final result = RouteBSnapshotKept.read(file, expectedSha256: digest);
        expect(result.problem, isNull);
        expect(result.kept!.hasClass('Object'), isTrue);
        // The recorded digest's case does not matter.
        final upper = RouteBSnapshotKept.read(
          file,
          expectedSha256: digest.toUpperCase(),
        );
        expect(upper.problem, isNull);
      });

      test('says "unreadable", not a stack trace, for a malformed profile '
          'with the right digest', () {
        final text = jsonEncode({
          'snapshot': {
            'meta': {
              'node_fields': ['type', 'name', 'id', 'self_size', 'edge_count'],
              'node_types': [
                ['Class'],
              ],
              'edge_fields': ['type', 'name_or_index', 'to_node'],
              'edge_types': [
                ['property'],
              ],
            },
          },
          'nodes': ['x', 1],
          'edges': <Object>[],
          'strings': <String>[],
        });
        final file = write(text);
        final result = RouteBSnapshotKept.read(
          file,
          expectedSha256: sha256.convert(file.readAsBytesSync()).toString(),
        );
        expect(result.kept, isNull);
        expect(result.problem, contains('unreadable'));
        expect(result.problem, contains('route_b_snapshot_profile.json'));
      });
    });
  });

  group('the per-release SDK-member check', () {
    final kept = RouteBSnapshotKept.fromProfileJson(routeBStringProfile);
    // Measured keys and the VM classes each was measured on.
    const accepted = {
      'dart:core#String#split',
      'dart:core#String#substring',
      'dart:core#String#endsWith',
      'dart:core#String#tearoff:split',
      'dart:core#String#toUpperCase',
      'dart:core#String#trim',
      'dynamic#==',
      'dynamic#tearoff:substring',
      'dart:core#String#get:isEmpty',
      'dart:core#Map#containsKey',
    };
    final byClass = {
      for (final k in accepted) k: ['_OneByteString'],
      // A key measured on a class this release does not have.
      'dart:core#String#trim': ['_OneByteString', '_TwoByteString'],
      'dart:core#Map#containsKey': ['_Map'],
    };

    RouteBRetention retention({
      RouteBSnapshotKept? snapshot,
      String? problem,
      bool skip = false,
    }) => RouteBRetention.parse(
      _interface,
      measuredAccepted: accepted,
      measuredFailing: const {},
      measuredVmClasses: byClass,
      kept: snapshot,
      keptProblem: problem,
      skipKeptCheck: skip,
    );

    String? refusal(RouteBRetention r, Map<String, Object?> reference) =>
        r.refusalForTarget(_analysis([reference]), _target);

    Map<String, Object?> sdk(String member, [String cls = 'String']) =>
        _ref('instance', 'dart:core', cls: cls, member: member);

    test('accepts a measured member this release kept, through the chain', () {
      final r = retention(snapshot: kept);
      expect(refusal(r, sdk('split')), isNull);
      expect(refusal(r, sdk('toUpperCase')), isNull);
      expect(refusal(r, sdk('tearoff:split')), isNull);
    });

    test('asks the snapshot for an int operator like any other member', () {
      // `T extends int` is not specialized by the bytecode compiler, so `&` is
      // a call looked up by name on `_Smi`, which has no such member here.
      final r = RouteBRetention.parse(
        _interface,
        measuredAccepted: const {'dart:core#int#&', 'dart:core#num#+'},
        measuredFailing: const {},
        measuredVmClasses: const {
          'dart:core#int#&': ['_Smi'],
          'dart:core#num#+': ['_Smi'],
        },
        kept: kept,
      );
      expect(refusal(r, sdk('&', 'int')), contains('no class `_Smi`'));
      expect(refusal(r, sdk('+', 'num')), contains('no class `_Smi`'));
    });

    group('an operator the bytecode compiler turns into an opcode', () {
      final r = RouteBRetention.parse(
        _interface,
        measuredAccepted: const {'dart:core#int#&', 'dart:core#num#+'},
        measuredFailing: const {},
        measuredVmClasses: const {
          'dart:core#int#&': ['_Smi'],
          'dart:core#num#+': ['_Smi'],
        },
        kept: kept,
      );
      Map<String, Object?> inlined(String member, String cls) => {
        ...sdk(member, cls),
        'inlined': 'BitAndInt',
      };
      String? refusal20(Map<String, Object?> ref, {int version = 20}) =>
          r.refusalForTarget(_analysis([ref], version: version), _target);

      test('is not looked up when analysis 20 says every site is one', () {
        expect(refusal20(inlined('&', 'int')), isNull);
        // Neither the list nor the snapshot is asked: this key is on no list.
        expect(refusal20(inlined('padLeft', 'String')), isNull);
      });

      test('is looked up when the analysis does not say so', () {
        expect(refusal20(sdk('&', 'int')), contains('no class `_Smi`'));
        expect(refusal20(sdk('padLeft')), isNotNull);
      });

      test('is looked up when the field comes from an analysis below 20', () {
        expect(
          refusal20(inlined('&', 'int'), version: 19),
          contains('no class `_Smi`'),
        );
      });

      test('is looked up through a constant', () {
        expect(
          refusal20({...inlined('&', 'int'), 'viaConstant': true}),
          isNotNull,
        );
      });
    });

    test('refuses a declared type the snapshot has no class for', () {
      // Zero roots would make the subtype walk visit nothing and pass.
      final r = RouteBRetention.parse(
        _interface,
        measuredAccepted: const {'dart:core#Nope#split'},
        measuredFailing: const {},
        measuredVmClasses: const {
          'dart:core#Nope#split': ['_OneByteString'],
        },
        kept: kept,
      );
      expect(
        refusal(r, sdk('split', 'Nope')),
        contains('this release has no class `Nope`'),
      );
    });

    test('refuses a declared type that is only in another library', () {
      final r = RouteBRetention.parse(
        _interface,
        measuredAccepted: const {'dart:collection#String#split'},
        measuredFailing: const {},
        measuredVmClasses: const {
          'dart:collection#String#split': ['_OneByteString'],
        },
        kept: kept,
      );
      expect(
        refusal(
          r,
          _ref('instance', 'dart:collection', cls: 'String', member: 'split'),
        ),
        contains('has no class `String` in `dart:collection`'),
      );
    });

    test('refuses one the release dropped: String.substring is absent', () {
      final reason = refusal(retention(snapshot: kept), sdk('substring'));
      expect(
        reason,
        allOf(
          contains('`String.substring`'),
          contains('has no `substring` on `_OneByteString`'),
        ),
      );
    });

    test('refuses one that has only a lazy-compile stub', () {
      final reason = refusal(retention(snapshot: kept), sdk('endsWith'));
      expect(reason, contains('without compiled code'));
    });

    test('refuses a measured member on a class the release lacks', () {
      expect(
        refusal(retention(snapshot: kept), sdk('trim')),
        contains('no class `_TwoByteString`'),
      );
      expect(
        refusal(retention(snapshot: kept), sdk('containsKey', 'Map')),
        contains('no class `_Map`'),
      );
    });

    test('refuses a member nobody measured, however the release is', () {
      expect(refusal(retention(snapshot: kept), sdk('padLeft')), isNotNull);
    });

    test('a dynamic call is asked of the same snapshot', () {
      final r = retention(snapshot: kept);
      expect(refusal(r, _ref('dynamic', '', member: '==')), isNull);
      expect(
        refusal(r, _ref('dynamic', '', member: 'get:substring')),
        allOf(contains('`substring`'), contains('no `substring`')),
      );
    });

    test('a dynamic call needs every class of the release to have it', () {
      // `x` is on the measured class and on nothing else: a dynamic value
      // could be any other class, so it is refused. `==` is on Object, which
      // every class reaches. A pseudo-class with no super (the VM's holder of
      // a library's top-level members) has no instances and does not count.
      final snapshot = RouteBSnapshotKept.fromProfileJson(
        routeBProfile({
          'Object': const RouteBProfileClass(
            'Object',
            routeBCoreLibrary,
            fns: {'==': '[Optimized] =='},
          ),
          '_OneByteString': const RouteBProfileClass(
            '_OneByteString',
            routeBCoreLibrary,
            parent: 'Object',
            fns: {'x': '[Optimized] x'},
          ),
          'Other': const RouteBProfileClass(
            'Other',
            'package:app/o.dart',
            parent: 'Object',
            fns: {'y': '[Optimized] y'},
          ),
          'TopLevel': const RouteBProfileClass(
            '::',
            'package:app/o.dart',
            fns: {'z': '[Optimized] z'},
          ),
        }),
      );
      final r = RouteBRetention.parse(
        _interface,
        measuredAccepted: const {'dynamic#==', 'dynamic#tearoff:x'},
        measuredFailing: const {},
        measuredVmClasses: const {
          'dynamic#==': ['_OneByteString'],
          'dynamic#tearoff:x': ['_OneByteString'],
        },
        kept: snapshot,
      );
      expect(refusal(r, _ref('dynamic', '', member: '==')), isNull);
      expect(
        refusal(r, _ref('dynamic', '', member: 'get:x')),
        allOf(
          contains('no `x` on `Other`'),
          contains('`dynamic`'),
          contains('app/o.dart'),
        ),
      );
    });

    test('refuses with no profile, naming the file and the flag', () {
      final reason = refusal(
        retention(
          problem: 'this release uploaded no route_b_snapshot_profile.json',
        ),
        sdk('split'),
      );
      expect(
        reason,
        allOf(
          contains('route_b_snapshot_profile.json'),
          contains('cannot be checked'),
        ),
      );
      // The summary the developer reads says what the flag does and does not
      // unlock.
      final summary = describeRouteBUnprovenSdkMembers(['x']);
      expect(summary, contains('--allow-unchecked-sdk-calls'));
      expect(summary, contains('no flag and no release setting'));
    });

    test('refuses with no profile and no reason given', () {
      expect(refusal(retention(), sdk('split')), contains('cannot be checked'));
    });

    test('a member the release interface names passes without a profile', () {
      final named = RouteBRetention.parse(
        '''
callable:
  - library: 'dart:core'
    class: 'String'
    member: 'padLeft'
''',
        measuredAccepted: accepted,
        measuredFailing: const {},
        measuredVmClasses: byClass,
      );
      expect(refusal(named, sdk('padLeft')), isNull);
    });

    test('--allow-unchecked-sdk-calls skips the snapshot, not the list', () {
      final r = retention(skip: true);
      expect(refusal(r, sdk('substring')), isNull);
      expect(refusal(r, sdk('padLeft')), isNotNull);
    });
  });

  group('a receiver class the measurement did not run', () {
    // List.get:reversed was measured on the list classes only. A Uint8List is
    // a List: its class is a subtype of `List` in this release, and does not
    // have `reversed`.
    const key = 'dart:core#List#get:reversed';
    RouteBSnapshotKept profileWith({required bool typedHasReversed}) =>
        RouteBSnapshotKept.fromProfileJson(
          routeBProfile({
            'Object': const RouteBProfileClass('Object', routeBCoreLibrary),
            // The interface: no code, no instances.
            'List': const RouteBProfileClass(
              'List',
              routeBCoreLibrary,
              parent: 'Object',
            ),
            'ListBase': const RouteBProfileClass(
              'ListBase',
              'dart:collection',
              parent: 'Object',
              ifaces: ['List'],
              fns: {'get:reversed': '[Optimized] reversed'},
            ),
            '_GrowableList': const RouteBProfileClass(
              '_GrowableList@0150898',
              routeBCoreLibrary,
              parent: 'ListBase',
            ),
            'Uint8List': const RouteBProfileClass(
              'Uint8List',
              'dart:typed_data',
              parent: 'Object',
              ifaces: ['List'],
            ),
            '_TypedListBase': const RouteBProfileClass(
              '_TypedListBase',
              'dart:typed_data',
              parent: 'Object',
              fns: {'[]': '[Optimized] []'},
            ),
            '_Uint8List': RouteBProfileClass(
              '_Uint8List',
              'dart:typed_data',
              parent: '_TypedListBase',
              ifaces: const ['Uint8List'],
              fns: {
                '_new': '[Optimized] _new',
                if (typedHasReversed) 'get:reversed': '[Optimized] reversed',
              },
            ),
          }),
        );

    RouteBRetention retention(RouteBSnapshotKept snapshot) =>
        RouteBRetention.parse(
          _interface,
          measuredAccepted: {key},
          measuredFailing: const {},
          measuredVmClasses: {
            key: ['_GrowableList'],
          },
          kept: snapshot,
        );

    String? refusal(RouteBRetention r) => r.refusalForTarget(
      _analysis([
        _ref('instance', 'dart:core', cls: 'List', member: 'get:reversed'),
      ]),
      _target,
    );

    test('is refused when its class lacks the member', () {
      final reason = refusal(retention(profileWith(typedHasReversed: false)));
      expect(
        reason,
        allOf(
          contains('no `get:reversed` on `_Uint8List`'),
          contains('`List`'),
        ),
      );
    });

    test('is accepted when every such class has it', () {
      expect(refusal(retention(profileWith(typedHasReversed: true))), isNull);
    });
  });
}
