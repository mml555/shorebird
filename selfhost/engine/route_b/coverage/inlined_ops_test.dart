// Unit test of `inlined` (analysis version 20): which operator references the
// analyzer marks, the AND across the sites of one member, and the body-wide
// clear for `super.`. Builds kernel nodes by hand over the real core library of
// a platform dill, so `RecognizedMethods` sees real `int`/`double`/`num`.
//
// Run with the engine's Dart, which has package:kernel and dart2bytecode:
//   ROUTE_B_PLATFORM=$OUT/vm_platform.dill \
//   $OUT/dart-sdk/bin/dart --packages=$SRC/flutter/third_party/dart/.dart_tool/package_config.json \
//     selfhost/engine/route_b/coverage/inlined_ops_test.dart
// inlined_ops_qualify.sh is the same question asked of the real compiler; this
// one needs no compiler and pins the analyzer's own bookkeeping.
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/type_environment.dart';

import 'analyze_coverage.dart';

var _failures = 0;

void check(bool ok, String what) {
  if (!ok) {
    _failures++;
    stderr.writeln('FAIL: $what');
  } else {
    stdout.writeln('ok: $what');
  }
}

void main() {
  final platform =
      Platform.environment['ROUTE_B_PLATFORM'] ??
      '${Platform.environment['HOME']}/shorebird-engine/flutter/engine/src/'
          'out/host_release_arm64_ddm/vm_platform.dill';
  final component = Component();
  BinaryBuilder(File(platform).readAsBytesSync()).readComponent(component);
  final coreLib = component.libraries.firstWhere(
    (l) => l.importUri.toString() == 'dart:core',
  );
  Class core(String name) => coreLib.classes.firstWhere((c) => c.name == name);
  final intC = core('int'), doubleC = core('double'), numC = core('num');
  Procedure member(Class c, String name) =>
      c.procedures.firstWhere((p) => p.name.text == name);

  final lib = Library(
    Uri.parse('package:app/a.dart'),
    fileUri: Uri.parse('file:///a.dart'),
  );
  final owner = Class(name: 'Owner', fileUri: lib.fileUri);
  lib.addClass(owner);
  component.libraries.add(lib);
  lib.parent = component;
  final env = TypeEnvironment(
    CoreTypes(component),
    ClassHierarchy(component, CoreTypes(component)),
  );

  InterfaceType t(Class c, [bool nullable = false]) => InterfaceType(
    c,
    nullable ? Nullability.nullable : Nullability.nonNullable,
  );

  final ft = FunctionType(
    const [],
    const DynamicType(),
    Nullability.nonNullable,
  );
  var n = 0;

  /// A procedure whose body is the given sites, each `(op, target class, a
  /// type, b type)`; `b` type null is a unary site.
  Map<String, Object?>? refOf(
    List<(String, Class, DartType, DartType?)> sites, {
    String member = '',
    bool withSuper = false,
    bool typed = true,
  }) {
    final params = <PositionalParameter>[];
    final body = <Statement>[];
    for (final (op, cls, aType, bType) in sites) {
      final a = PositionalParameter(cosmeticName: 'a${n++}', type: aType);
      final b = bType == null
          ? null
          : PositionalParameter(cosmeticName: 'b${n++}', type: bType);
      params.addAll([a, ?b]);
      body.add(
        ExpressionStatement(
          InstanceInvocation(
            InstanceAccessKind.Instance,
            VariableGet(a),
            Name(op),
            Arguments(b == null ? [] : [VariableGet(b)]),
            interfaceTarget: this_member(cls, op),
            functionType: ft,
          ),
        ),
      );
    }
    if (withSuper) {
      body.add(
        ExpressionStatement(
          SuperPropertyGet(
            ThisExpression(),
            Name('hashCode'),
            this_member(core('Object'), 'hashCode', getter: true),
          ),
        ),
      );
    }
    final p = Procedure(
      Name('f${n++}'),
      ProcedureKind.Method,
      FunctionNode(Block(body), positionalParameters: params),
      fileUri: lib.fileUri,
    );
    lib.addProcedure(p);
    final refs = externalReferencesOf(p, {}, types: typed ? env : null);
    return refs
        .where((r) => r['kind'] == 'instance' && r['member'] == member)
        .cast<Map<String, Object?>?>()
        .firstWhere((_) => true, orElse: () => null);
  }

  final i = t(intC), d = t(doubleC), nu = t(numC), iq = t(intC, true);
  String? flag(Map<String, Object?>? r) => r?['inlined'] as String?;

  check(
    flag(refOf([('+', numC, i, i)], member: '+')) == 'AddInt',
    'int + int is AddInt',
  );
  check(
    flag(refOf([('+', numC, d, d)], member: '+')) == 'AddDouble',
    'double + double is AddDouble',
  );
  check(
    flag(refOf([('&', intC, i, i)], member: '&')) == 'BitAndInt',
    'int & int is BitAndInt',
  );
  check(
    flag(refOf([('unary-', intC, i, null)], member: 'unary-')) == 'NegateInt',
    '-int is NegateInt',
  );
  check(
    flag(refOf([('unary-', doubleC, d, null)], member: 'unary-')) ==
        'NegateDouble',
    '-double is NegateDouble',
  );
  check(
    refOf([('<', numC, i, i)], member: '<')?.containsKey('inlined') == true,
    'int < int is inlined',
  );
  check(
    flag(refOf([('+', numC, nu, nu)], member: '+')) == null,
    'num + num is not inlined',
  );
  check(
    flag(refOf([('+', numC, i, d)], member: '+')) == null,
    'int + double is not inlined',
  );
  check(
    flag(refOf([('+', numC, d, i)], member: '+')) == null,
    'double + int is not inlined',
  );
  check(
    flag(refOf([('+', numC, iq, i)], member: '+')) == null,
    'int? + int is not inlined',
  );
  check(
    flag(refOf([('>>>', intC, i, i)], member: '>>>')) == null,
    'int >>> int is not inlined',
  );
  check(
    flag(refOf([('/', numC, i, i)], member: '/')) == null,
    'int / int is not inlined',
  );

  // The AND across the sites of one member, in both orders.
  check(
    flag(refOf([('+', numC, i, i), ('+', numC, nu, nu)], member: '+')) == null,
    'inlined site then a call: not inlined',
  );
  check(
    flag(refOf([('+', numC, nu, nu), ('+', numC, i, i)], member: '+')) == null,
    'a call then an inlined site: not inlined',
  );
  check(
    flag(refOf([('+', numC, i, i), ('+', numC, i, i)], member: '+')) ==
        'AddInt',
    'two inlined sites stay inlined',
  );
  // One key, two opcodes: both are named, so the name is never wrong.
  check(
    flag(refOf([('<', numC, i, i), ('<', numC, d, d)], member: '<')) ==
        'CompareDoubleLt|CompareIntLt',
    'int < and double < in one body name both opcodes',
  );
  check(
    flag(refOf([('+', numC, i, i), ('+', numC, d, d)], member: '+')) ==
        'AddDouble|AddInt',
    'int + and double + in one body name both opcodes',
  );
  // Mixed int/double in one body where one site is a call.
  check(
    flag(refOf([('+', numC, i, i), ('+', numC, i, d)], member: '+')) == null,
    'int+int then int+double: not inlined',
  );
  // A different member does not affect this one.
  check(
    flag(refOf([('&', intC, i, i), ('+', numC, nu, nu)], member: '&')) ==
        'BitAndInt',
    'a call to another member leaves this one inlined',
  );

  // `super.` anywhere in the body clears every flag: the producer compiles
  // `$routeBSuper(...) as dynamic` instead.
  check(
    flag(refOf([('+', numC, i, i)], member: '+', withSuper: true)) == null,
    'a super call in the body clears inlined',
  );

  // Without a type environment nothing is marked.
  check(
    refOf([('+', numC, i, i)], member: '+', typed: false) != null &&
        flag(refOf([('+', numC, i, i)], member: '+', typed: false)) == null,
    'no type environment, no inlined',
  );

  if (_failures > 0) exit(1);
  stdout.writeln('all passed');
}

Procedure this_member(Class c, String name, {bool getter = false}) =>
    c.procedures.firstWhere(
      (p) => p.name.text == name && (p.kind == ProcedureKind.Getter) == getter,
    );
