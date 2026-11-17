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

import '../gen_dynamic_interface.dart';

const _fw = 'package:flutter/src/widgets/framework.dart';
var _fails = 0;

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

  if (_fails > 0) {
    print('$_fails FAILED');
    exit(1);
  }
  print('ALL PASS');
}
