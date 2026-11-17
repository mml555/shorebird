// cspell:words tearoff
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/route_b_coverage.dart';
import 'package:shorebird_cli/src/route_b_retention.dart';
import 'package:shorebird_cli/src/route_b_sdk_kept.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// A minimal v8 snapshot profile, in the shape `gen_snapshot` writes: Class
/// nodes pointing at an Array of Function nodes and a Type whose first Class is
/// the super class, and Function nodes pointing at their Code.
String _profile(Map<String, ({String? parent, Map<String, String> fns})> cls) {
  const types = [
    'ArtificialRoot',
    'Array',
    'Code',
    'Function',
    'Class',
    'Type',
    'Other',
  ];
  final strings = <String>[];
  int str(String s) {
    final i = strings.indexOf(s);
    if (i >= 0) return i;
    strings.add(s);
    return strings.length - 1;
  }

  final nodes = <({int type, String name, List<int> to})>[];
  int add(String type, String name, [List<int> to = const []]) {
    nodes.add((type: types.indexOf(type), name: name, to: to));
    return nodes.length - 1;
  }

  // Classes first so a Type can point at its super class by index.
  final classIndex = <String, int>{};
  for (final name in cls.keys) {
    classIndex[name] = add('Class', name);
  }
  for (final entry in cls.entries) {
    final fnNodes = <int>[];
    for (final fn in entry.value.fns.entries) {
      final code = add('Code', fn.value);
      fnNodes.add(add('Function', fn.key, [classIndex[entry.key]!, code]));
    }
    final array = add('Array', 'Unnamed [Array]', fnNodes);
    final parent = entry.value.parent;
    final to = <int>[array];
    if (parent != null) {
      // The Type's own edges: the super class first, then a stub.
      final stub = add('Code', '[Stub] DefaultTypeTest');
      to.add(add('Type', 'Unnamed [Type]', [classIndex[parent]!, stub]));
    }
    final i = classIndex[entry.key]!;
    nodes[i] = (type: nodes[i].type, name: nodes[i].name, to: to);
  }
  final flatNodes = <int>[];
  final flatEdges = <int>[];
  for (var i = 0; i < nodes.length; i++) {
    flatNodes.addAll([
      nodes[i].type,
      str(nodes[i].name),
      i,
      0,
      nodes[i].to.length,
    ]);
    for (final t in nodes[i].to) {
      flatEdges.addAll([0, 0, t * 5]);
    }
  }
  return jsonEncode({
    'snapshot': {
      'meta': {
        'node_fields': ['type', 'name', 'id', 'self_size', 'edge_count'],
        'node_types': [types],
        'edge_fields': ['type', 'name_or_index', 'to_node'],
        'edge_types': [
          ['context', 'element', 'property', 'internal'],
        ],
      },
    },
    'nodes': flatNodes,
    'edges': flatEdges,
    'strings': strings,
  });
}

/// `String.substring` is absent, `String.split` and `trim` are on
/// `_StringBase`, `endsWith` is there with only a lazy-compile stub, and the
/// one-byte string reaches all of them (and `Object.==`) through its super
/// chain. A class name's private-library suffix is ignored.
final _fixture = _profile({
  'Object': (parent: null, fns: {'==': '[Optimized] =='}),
  '_StringBase@0150898': (
    parent: 'Object',
    fns: {
      'split': '[Optimized] split',
      'trim': '[Optimized] trim',
      'endsWith': '[Stub] LazyCompile',
    },
  ),
  '_OneByteString@0150898': (
    parent: '_StringBase@0150898',
    fns: {'toUpperCase': '[Optimized] toUpperCase'},
  ),
});

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

RouteBCoverage _analysis(List<Map<String, Object?>> references) =>
    RouteBCoverage.fromJson(
      jsonEncode({
        'analysisVersion': 19,
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
      final kept = RouteBSnapshotKept.fromProfileJson(_fixture);
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

    test('is an error for a file that is not a snapshot profile', () {
      expect(
        () => RouteBSnapshotKept.fromProfileJson('not json'),
        throwsFormatException,
      );
      expect(
        () => RouteBSnapshotKept.fromProfileJson('{"nodes": []}'),
        throwsFormatException,
      );
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
        final file = write(_fixture);
        final result = RouteBSnapshotKept.read(file, expectedSha256: 'beef');
        expect(result.kept, isNull);
        expect(result.problem, contains('does not match'));
      });

      test('refuses a profile with no recorded digest', () {
        final result = RouteBSnapshotKept.read(
          write(_fixture),
          expectedSha256: null,
        );
        expect(result.kept, isNull);
        expect(result.problem, contains('no digest'));
      });

      test('reads a profile that hashes to the recorded digest', () {
        final file = write(_fixture);
        final result = RouteBSnapshotKept.read(
          file,
          expectedSha256: sha256.convert(file.readAsBytesSync()).toString(),
        );
        expect(result.problem, isNull);
        expect(result.kept!.hasClass('Object'), isTrue);
      });
    });
  });

  group('the per-release SDK-member check', () {
    final kept = RouteBSnapshotKept.fromProfileJson(_fixture);
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
    final classes = {
      for (final k in accepted) k: ['_OneByteString'],
    };
    final byClass = {
      ...classes,
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
      // The summary the developer reads offers the way out.
      expect(
        describeRouteBUnprovenSdkMembers(['x']),
        contains('--allow-unchecked-sdk-calls'),
      );
    });

    test('refuses with no profile and no reason given', () {
      expect(
        refusal(retention(), sdk('split')),
        contains('cannot be checked'),
      );
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
}
