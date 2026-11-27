// Unit test of `inlined` (analysis version 21): which operator references the
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
import 'dart:typed_data';

import 'package:dart2bytecode/recognized_methods.dart' show RecognizedMethods;
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
    // Which super form the body holds, if any: 'get', 'method', 'operator'
    // (`super + x`), 'set', or any of them inside a closure ('closure-get',
    // 'closure-method').
    String? superKind,
    bool typed = true,
  }) {
    superKind ??= withSuper ? 'get' : null;
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
    if (superKind != null) {
      final inClosure = superKind.startsWith('closure-');
      final kind = superKind.replaceFirst('closure-', '');
      final Expression site = switch (kind) {
        'get' => SuperPropertyGet(
          ThisExpression(),
          Name('hashCode'),
          this_member(core('Object'), 'hashCode', getter: true),
        ),
        'method' => SuperMethodInvocation(
          ThisExpression(),
          Name('toString'),
          Arguments([]),
          this_member(core('Object'), 'toString'),
        ),
        'operator' => SuperMethodInvocation(
          ThisExpression(),
          Name('=='),
          Arguments([NullLiteral()]),
          this_member(core('Object'), '=='),
        ),
        'set' => SuperPropertySet(
          ThisExpression(),
          Name('hashCode'),
          NullLiteral(),
          this_member(core('Object'), 'hashCode', getter: true),
        ),
        _ => throw ArgumentError(superKind),
      };
      body.add(
        ExpressionStatement(
          inClosure
              ? FunctionExpression(
                  FunctionNode(ReturnStatement(site)),
                )
              : site,
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

  // The producer rewrites every super form, not only a getter, and a closure in
  // the body holds its own: each clears the flags of the whole body.
  for (final kind in [
    'get',
    'method',
    'operator',
    'set',
    'closure-get',
    'closure-method',
    'closure-operator',
  ]) {
    check(
      flag(refOf([('+', numC, i, i)], member: '+', superKind: kind)) == null,
      'a super $kind in the body clears inlined',
    );
  }
  check(
    refOf([('+', numC, i, i)], member: '+', superKind: 'method') != null,
    'the reference is still listed after the clear',
  );

  // Without a type environment nothing is marked.
  check(
    refOf([('+', numC, i, i)], member: '+', typed: false) != null &&
        flag(refOf([('+', numC, i, i)], member: '+', typed: false)) == null,
    'no type environment, no inlined',
  );

  // The bytecode scan fails closed when the text format changes.
  const pool = "  [1] = InterfaceCall 'dart:core::num::+', ArgDesc num-args 2\n"
      "  [2] = DynamicCall '-', ArgDesc num-args 2\n"
      '  [3] = DirectCall \'a::b\', ArgDesc num-args 0\n';
  const body = '  InterfaceCall        CP#1, 2\n';
  final good = scanBytecodeText("Function 'f'\n$body$pool");
  check(
    good['unparsed'] == 0 && '${good['calls']}' == '[+, -]',
    'a well-formed pool reads completely: $good',
  );
  final moved = scanBytecodeText("Function 'f'\n$body${pool.replaceAll('] = ', ']: ')}");
  check(
    (moved['unparsed'] as int) > 0 && (moved['calls'] as List).isEmpty,
    'a changed pool-line prefix leaves call lines unread: $moved',
  );
  final closure = scanBytecodeText(
    "Function 'f'\n$body$pool"
    'Closure a::f (VoidCallback cb) -> void\n'
    '    parameters [dart:ui::VoidCallback \'cb\']\n',
  );
  check(
    closure['unparsed'] == 0 && '${closure['calls']}' == '[+, -]',
    'a closure header naming VoidCallback is not a call line: $closure',
  );
  final renamed = scanBytecodeText(
    "Function 'f'\n$body${pool.replaceAll('  [', '  #').replaceAll('] = ', ' -> ')}",
  );
  check(
    (renamed['unparsed'] as int) > 0 && (renamed['calls'] as List).isEmpty,
    'an unrecognisable entry shape with calls in the code is unreadable',
  );
  final quoted = scanBytecodeText(
    "Function 'f'\n$body$pool  [4] = ConstantX 'a::makeCall', ArgDesc\n",
  );
  check(quoted['unparsed'] == 0, 'a quoted name containing Call is not counted');

  // _writableType and the import check (S4).
  Library mk(String uri, {String? source}) {
    final l = Library(Uri.parse(uri), fileUri: Uri.parse('file:///${uri.hashCode}.dart'));
    return l;
  }

  final target = mk('package:app/t.dart');
  final comp = Component(libraries: [target]);
  final shadow = mk('package:app/models.dart')
    ..addClass(Class(name: 'int', fileUri: Uri.parse('file:///m.dart')));
  final plain = mk('package:app/plain.dart')
    ..addClass(Class(name: 'Other', fileUri: Uri.parse('file:///p.dart')));
  final reexport = mk('package:app/re.dart');
  comp.libraries.addAll([shadow, plain, reexport]);
  final intType = InterfaceType(intC, Nullability.nonNullable);
  check(
    writableTypeForTesting(intType, target) == null,
    'no recorded dependencies and no source: not trusted, not written',
  );
  target.addDependency(LibraryDependency.import(plain));
  check(
    writableTypeForTesting(intType, target) == 'int',
    'an import that does not expose the name: written',
  );
  target.addDependency(LibraryDependency.import(reexport));
  reexport.addDependency(LibraryDependency.export(shadow));
  check(
    writableTypeForTesting(intType, target) == null,
    'a re-export that exposes the name: refused',
  );
  final target2 = mk('package:app/t2.dart');
  comp.libraries.add(target2);
  target2.parent = comp;
  target2.addDependency(LibraryDependency.import(plain));
  comp.uriToSource[target2.fileUri] = Source(
    const [0],
    Uint8List.fromList(
      "import 'a.dart';\nimport 'b.dart';\n".codeUnits,
    ),
    target2.importUri,
    target2.fileUri,
  );
  check(
    writableTypeForTesting(intType, target2) == null,
    'fewer recorded dependencies than source directives: refused',
  );

  // The CLI's whitelist (route_b_coverage.dart `inlinedOpcodes`) is a hand copy
  // of the compiler's tables. It must be exactly them, minus `==` (which never
  // reaches an `inlined` flag), with `unary-` added.
  final expected = <String, Set<String>>{};
  for (final table in [
    RecognizedMethods.binaryIntOps,
    RecognizedMethods.binaryDoubleOps,
  ]) {
    table.forEach((selector, opcode) {
      if (selector == '==') return;
      expected.putIfAbsent(selector, () => {}).add(opcode.name.substring(1));
    });
  }
  expected['unary-'] = {'NegateInt', 'NegateDouble'};
  final cliSource = File(
    '${File.fromUri(Platform.script).parent.path}/../../../../packages/'
    'shorebird_cli/lib/src/route_b_coverage.dart',
  ).readAsStringSync();
  final block = RegExp(
    r'static const inlinedOpcodes = <String, Set<String>>\{(.*?)\n  \};',
    dotAll: true,
  ).firstMatch(cliSource)!.group(1)!;
  final actual = <String, Set<String>>{
    for (final m in RegExp(r"'([^']+)': \{([^}]*)\}").allMatches(block))
      m.group(1)!: {
        for (final o in RegExp(r"'(\w+)'").allMatches(m.group(2)!)) o.group(1)!,
      },
  };
  check(
    expected.length == actual.length &&
        expected.entries.every(
          (e) =>
              actual[e.key] != null &&
              actual[e.key]!.length == e.value.length &&
              actual[e.key]!.containsAll(e.value),
        ),
    'the CLI inlinedOpcodes table equals the compiler\'s RecognizedMethods '
    'tables (expected $expected, CLI $actual)',
  );

  // For-in receivers (analysis version 23): the `Iterable.get:iterator`
  // reference names the class of the iterable's static type.
  final listC = core('List'), setC = core('Set'), iterableC = core('Iterable');
  List<Map<String, Object?>> iteratorRefs(
    List<DartType> iterables, {
    bool typed = true,
  }) {
    final params = <PositionalParameter>[];
    final body = <Statement>[];
    for (final type in iterables) {
      final xs = PositionalParameter(cosmeticName: 'xs${n++}', type: type);
      params.add(xs);
      body.add(
        ForInStatement(
          LocalVariable(name: 'x${n++}'),
          VariableGet(xs),
          Block([]),
        ),
      );
    }
    final p = Procedure(
      Name('loop${n++}'),
      ProcedureKind.Method,
      FunctionNode(Block(body), positionalParameters: params),
      fileUri: lib.fileUri,
    );
    lib.addProcedure(p);
    return externalReferencesOf(
      p,
      {},
      types: typed ? env : null,
    ).where((r) => r['member'] == 'get:iterator').toList();
  }

  final overList = iteratorRefs([t(listC)]);
  check(
    overList.length == 1 &&
        overList.single['class'] == 'Iterable' &&
        overList.single['library'] == 'dart:core' &&
        overList.single['receiverLibrary'] == 'dart:core' &&
        overList.single['receiverClass'] == 'List',
    'a for-in over a List names List as the receiver ($overList)',
  );
  final both = iteratorRefs([t(listC), t(setC), t(listC)]);
  check(
    both.length == 2 &&
        both.map((r) => r['receiverClass']).toSet().containsAll({
          'List',
          'Set',
        }),
    'loops over a List and a Set report one entry per receiver ($both)',
  );
  for (final (what, refs) in [
    ('an Iterable', iteratorRefs([t(iterableC)])),
    ('a dynamic value', iteratorRefs([const DynamicType()])),
    (
      'a List without a type environment',
      iteratorRefs([t(listC)], typed: false),
    ),
  ]) {
    check(
      refs.length == 1 &&
          refs.single['class'] == 'Iterable' &&
          !refs.single.containsKey('receiverClass') &&
          !refs.single.containsKey('receiverLibrary'),
      'a for-in over $what names no receiver ($refs)',
    );
  }
  final appIterable = Class(
    name: 'Shapes',
    fileUri: lib.fileUri,
    supertype: Supertype(iterableC, [const DynamicType()]),
  );
  lib.addClass(appIterable);
  final overApp = iteratorRefs([t(appIterable)]);
  check(
    overApp.length == 1 &&
        overApp.single['receiverLibrary'] == 'package:app/a.dart' &&
        overApp.single['receiverClass'] == 'Shapes',
    'a for-in over an app class names it and its library ($overApp)',
  );
  // A nullable, type-parameter, extension-type or FutureOr iterable names no
  // receiver: none of them is a class the CLI can narrow to.
  final elem = TypeParameter('E', t(listC), t(listC));
  final shapesType = ExtensionTypeDeclaration(
    name: 'ShapeList',
    fileUri: lib.fileUri,
  )..declaredRepresentationType = t(listC);
  lib.addExtensionTypeDeclaration(shapesType);
  for (final (what, type) in <(String, DartType)>[
    ('a nullable List', t(listC, true)),
    (
      'a type parameter bounded by List',
      TypeParameterType(elem, Nullability.nonNullable),
    ),
    (
      'an extension type over List',
      ExtensionType(shapesType, Nullability.nonNullable),
    ),
    ('a FutureOr<List>', FutureOrType(t(listC), Nullability.nonNullable)),
  ]) {
    final refs = iteratorRefs([type]);
    check(
      refs.length == 1 &&
          refs.single['class'] == 'Iterable' &&
          !refs.single.containsKey('receiverClass') &&
          !refs.single.containsKey('receiverLibrary'),
      'a for-in over $what names no receiver ($refs)',
    );
  }
  // The same, in the lowered form a real dill holds: no ForInStatement, a
  // synthetic `:sync-for-iterator` variable initialized with `xs.iterator`.
  final iterableIterator = this_member(iterableC, 'iterator', getter: true);
  List<Map<String, Object?>> loweredRefs(
    DartType type, {
    String variableName = ':sync-for-iterator',
    Member? target,
    bool typed = true,
    DartType? promotedTo,
  }) {
    final xs = PositionalParameter(cosmeticName: 'xs${n++}', type: type);
    final p = Procedure(
      Name('lowered${n++}'),
      ProcedureKind.Method,
      FunctionNode(
        Block([
          VariableStatement(
            VariableDeclaration(
              SyntheticVariable(
                cosmeticName: variableName,
                initializer: InstanceGet(
                  InstanceAccessKind.Instance,
                  VariableGet(xs, promotedTo),
                  Name('iterator'),
                  interfaceTarget: target ?? iterableIterator,
                  // The real lowered type, `Iterator<int>`, as the VM's
                  // for-in lowering writes it.
                  resultType: InterfaceType(
                    core('Iterator'),
                    Nullability.nonNullable,
                    [t(core('int'))],
                  ),
                ),
              ),
            ),
          ),
        ]),
        positionalParameters: [xs],
      ),
      fileUri: lib.fileUri,
    );
    lib.addProcedure(p);
    return externalReferencesOf(
      p,
      {},
      types: typed ? env : null,
    ).where((r) => r['member'] == 'get:iterator').toList();
  }

  final loweredList = loweredRefs(t(listC));
  check(
    loweredList.length == 1 &&
        loweredList.single['class'] == 'Iterable' &&
        loweredList.single['receiverLibrary'] == 'dart:core' &&
        loweredList.single['receiverClass'] == 'List',
    'a lowered for-in over a List names List as the receiver ($loweredList)',
  );
  final loweredSet = loweredRefs(t(setC));
  check(
    loweredSet.length == 1 && loweredSet.single['receiverClass'] == 'Set',
    'a lowered for-in over a Set names Set as the receiver ($loweredSet)',
  );
  final loweredApp = loweredRefs(t(appIterable));
  check(
    loweredApp.length == 1 &&
        loweredApp.single['receiverLibrary'] == 'package:app/a.dart' &&
        loweredApp.single['receiverClass'] == 'Shapes',
    'a lowered for-in over an app class names it and its library '
    '($loweredApp)',
  );
  // A promoted variable (`if (xs is List)` over an Iterable) has the promoted
  // type, a sound narrowing: the value is a List.
  final loweredPromoted = loweredRefs(t(iterableC), promotedTo: t(listC));
  check(
    loweredPromoted.length == 1 &&
        loweredPromoted.single['receiverClass'] == 'List',
    'a lowered for-in over a variable promoted to List names List '
    '($loweredPromoted)',
  );
  // A subclass static type names that subclass (the CLI then asks it and its
  // subtypes), not the List it extends.
  final collectionLib = env.coreTypes.index.getLibrary('dart:collection');
  final listBase = collectionLib.classes.firstWhere(
    (c) => c.name == 'ListBase',
  );
  final loweredBase = loweredRefs(t(listBase));
  check(
    loweredBase.length == 1 &&
        loweredBase.single['receiverLibrary'] == 'dart:collection' &&
        loweredBase.single['receiverClass'] == 'ListBase',
    'a lowered for-in over a ListBase names ListBase ($loweredBase)',
  );
  final listBound = TypeParameter('L', t(listC), t(listC));
  final loweredShapes = Class(
    name: 'ShapeBase',
    fileUri: lib.fileUri,
    supertype: Supertype(listBase, [t(core('int'))]),
  );
  lib.addClass(loweredShapes);
  final loweredSub = loweredRefs(t(loweredShapes));
  check(
    loweredSub.length == 1 &&
        loweredSub.single['receiverLibrary'] == 'package:app/a.dart' &&
        loweredSub.single['receiverClass'] == 'ShapeBase',
    'a lowered for-in over a class extending ListBase names that class '
    '($loweredSub)',
  );
  for (final (what, refs) in [
    (
      'a type parameter bounded by List',
      loweredRefs(TypeParameterType(listBound, Nullability.nonNullable)),
    ),
    (
      'a FutureOr<List>',
      loweredRefs(FutureOrType(t(listC), Nullability.nonNullable)),
    ),
    ('an Iterable', loweredRefs(t(iterableC))),
    ('a dynamic value', loweredRefs(const DynamicType())),
    ('a nullable List', loweredRefs(t(listC, true))),
    ('a List without a type environment', loweredRefs(t(listC), typed: false)),
    (
      'a variable that is not the for-in iterator',
      loweredRefs(t(listC), variableName: 'it'),
    ),
  ]) {
    check(
      refs.length == 1 &&
          refs.single['class'] == 'Iterable' &&
          !refs.single.containsKey('receiverClass') &&
          !refs.single.containsKey('receiverLibrary'),
      'a lowered for-in over $what names no receiver ($refs)',
    );
  }
  check(analysisVersion == 25, 'analysis version is 25');

  if (_failures > 0) exit(1);
  stdout.writeln('all passed');
}

Procedure this_member(Class c, String name, {bool getter = false}) =>
    c.procedures.firstWhere(
      (p) => p.name.text == name && (p.kind == ProcedureKind.Getter) == getter,
    );
