// cspell:words nohash
// Unit test for gen_dynamic_interface.dart's --extendable flag
// (extendableSections). Plain asserts, no package:test, like the other probes.
// Run with the Dart tree's package config so package:kernel resolves:
//
//   $OUT/dart-sdk/bin/dart \
//     --packages=<dart-tree>/.dart_tool/package_config.json \
//     gen_extendable_flag_test.dart
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:kernel/ast.dart';

import '../gen_dynamic_interface.dart';

const _fw = 'package:flutter/src/widgets/framework.dart';
var _fails = 0;

void check_(String name, bool ok, Object? got) => check(name, ok, true);

void check(String name, Object? got, Object? want) {
  if (got == want) {
    print('PASS $name');
  } else {
    _fails++;
    print('FAIL $name\n--- got\n$got\n--- want\n$want');
  }
}

void main() {
  // Flag off: nothing is emitted, so the interface is byte-identical.
  check('no specs -> empty', extendableSections(const []), '');

  check(
    'whole classes, sorted, one library item',
    extendableSections([
      '$_fw#State',
      '$_fw#StatelessWidget',
      '$_fw#StatefulWidget',
    ]),
    '''

# --extendable: classes a patch module may extend.
extendable:
  - library: '$_fw'
    class: ['State', 'StatefulWidget', 'StatelessWidget']

can-be-overridden:
  - library: '$_fw'
    class: 'State'
  - library: '$_fw'
    class: 'StatefulWidget'
  - library: '$_fw'
    class: 'StatelessWidget'
''',
  );

  check(
    'Class.member narrows overrides, class stays extendable',
    extendableSections(['$_fw#StatelessWidget.build']),
    '''

# --extendable: classes a patch module may extend.
extendable:
  - library: '$_fw'
    class: ['StatelessWidget']

can-be-overridden:
  - library: '$_fw'
    class: 'StatelessWidget'
    member: 'build'
''',
  );

  check(
    'bare class wins over a member of the same class; duplicates collapse',
    extendableSections(['a#B.m', 'a#B', 'a#B']),
    '''

# --extendable: classes a patch module may extend.
extendable:
  - library: 'a'
    class: ['B']

can-be-overridden:
  - library: 'a'
    class: 'B'
''',
  );

  for (final bad in ['nohash', '#Class', 'lib#', 'lib#.m', 'lib#C.']) {
    var threw = false;
    try {
      extendableSections([bad]);
    } on FormatException {
      threw = true;
    }
    check('malformed "$bad" throws', threw, true);
  }

  // Validation against a kernel built in memory.
  final uri = Uri.parse('package:t/t.dart');
  final lib = Library(uri, fileUri: uri);
  Class mk(String n, {bool isFinal = false, bool isSealed = false}) =>
      Class(name: n, fileUri: uri)
        ..isFinal = isFinal
        ..isSealed = isSealed;
  Procedure meth(String n, {bool isStatic = false}) => Procedure(
    Name(n, n.startsWith('_') ? lib : null),
    ProcedureKind.Method,
    FunctionNode(null),
    isStatic: isStatic,
    fileUri: uri,
  );
  final base = mk('Base')
    ..addProcedure(meth('build'))
    ..addProcedure(meth('_secret'))
    ..addProcedure(meth('make', isStatic: true))
    ..addConstructor(
      Constructor(FunctionNode(null), name: Name(''), fileUri: uri),
    );
  lib
    ..addClass(base)
    ..addClass(mk('Fin', isFinal: true))
    ..addClass(mk('Seal', isSealed: true));
  final comp = Component(libraries: [lib]);
  List<String> checkSpecs(List<String> s) =>
      checkExtendableSpecs(parseExtendableSpecs(s), [comp]);
  const u = 'package:t/t.dart';
  check1(String name, List<String> specs, int problems, [String? has]) {
    final got = checkSpecs(specs);
    final ok = got.length == problems && (has == null || got.join().contains(has));
    check_(name, ok, got);
  }

  check1('valid class and member', ['$u#Base', '$u#Base.build'], 0);
  check1('unknown class', ['$u#Nope'], 1, 'no class Nope');
  check1('unknown library', ['package:x/x.dart#Base'], 1, 'no class Base');
  check1('final class', ['$u#Fin'], 1, 'final');
  check1('sealed class', ['$u#Seal'], 1, 'sealed');
  check1('missing member', ['$u#Base.nope'], 1, "no public instance member 'nope'");
  check1('private member', ['$u#Base._secret'], 1, '_secret');
  check1('static member', ['$u#Base.make'], 1, 'make');
  check1('constructor is not a member', ['$u#Base.new'], 1, 'new');

  final g = extendableGrants(parseExtendableSpecs(['a#B.m', 'a#B', 'a#C.z', 'a#C.y']));
  check('grants: extendable', g.extendable.map((e) => '${e.library}#${e.cls}').toList().toString(), '[a#B, a#C]');
  check('grants: overridable', g.overridable.map((o) => '${o.library}#${o.cls}.${o.member}').toList().toString(), '[a#B.null, a#C.y, a#C.z]');

  if (_fails > 0) {
    print('$_fails FAILED');
    exit(1);
  }
  print('ALL PASS');
}
