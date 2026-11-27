// Tests for the external-reference walk of analyze_coverage.dart (analysis
// version 19): dynamic calls, tear-offs, extension-type members, for-in loops
// and the `viaConstant` split. Builds kernel nodes by hand, so it needs no
// compiler.
//
// Run with the engine's Dart, which has package:kernel:
//   $OUT/dart-sdk/bin/dart --packages=$SRC/flutter/third_party/dart/.dart_tool/package_config.json \
//     selfhost/engine/route_b/coverage/external_uses_test.dart
// cspell:words tearoff
import 'dart:io';

import 'package:kernel/ast.dart';

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

Library _lib(String uri) =>
    Library(Uri.parse(uri), fileUri: Uri.parse('file:///x.dart'));

Procedure _proc(
  Library l,
  String name,
  List<Statement> body, {
  ProcedureKind kind = ProcedureKind.Method,
}) {
  final p = Procedure(
    Name(name, l),
    kind,
    FunctionNode(Block(body)),
    fileUri: l.fileUri,
  );
  l.addProcedure(p);
  return p;
}

Class _cls(Library l, String name) {
  final c = Class(name: name, fileUri: l.fileUri);
  l.addClass(c);
  return c;
}

Procedure _method(
  Class c,
  String name, {
  ProcedureKind kind = ProcedureKind.Method,
}) {
  final p = Procedure(
    Name(name, c.enclosingLibrary),
    kind,
    FunctionNode(null),
    fileUri: c.fileUri,
  );
  c.addProcedure(p);
  return p;
}

Map<String, Object?>? _find(
  List<Map<String, Object?>> refs,
  String kind,
  String member, {
  String? cls,
}) {
  for (final r in refs) {
    if (r['kind'] == kind &&
        r['member'] == member &&
        (cls == null || r['class'] == cls)) {
      return r;
    }
  }
  return null;
}

Arguments get _noArgs => Arguments([]);

void main() {
  check(analysisVersion == 25, 'analysis version is 25');

  final app = _lib('package:app/a.dart');
  final core = _lib('dart:core');
  final list = _cls(core, 'List');
  final add = _method(list, 'add');
  final getter = _method(list, 'length', kind: ProcedureKind.Getter);
  final v = LocalVariable(name: 'x');
  final ft = FunctionType(
    const [],
    const DynamicType(),
    Nullability.nonNullable,
  );

  // A class of the app with a member named `build`.
  final widget = _cls(app, 'Widget');
  final build = _method(widget, 'build');

  final dyn = _proc(app, 'dyn', [
    ExpressionStatement(
      DynamicInvocation(
        DynamicAccessKind.Dynamic,
        VariableGet(v),
        Name('build'),
        _noArgs,
      ),
    ),
    ExpressionStatement(
      DynamicGet(DynamicAccessKind.Dynamic, VariableGet(v), Name('first')),
    ),
    ExpressionStatement(
      DynamicSet(
        DynamicAccessKind.Dynamic,
        VariableGet(v),
        Name('name'),
        IntLiteral(1),
      ),
    ),
    ExpressionStatement(
      DynamicInvocation(
        DynamicAccessKind.Dynamic,
        VariableGet(v),
        Name('[]'),
        Arguments([StringLiteral('k')]),
      ),
    ),
  ]);
  final refs = externalReferencesOf(
    dyn,
    {},
    appMembersByName: {
      'build': [build],
    },
  );
  check(_find(refs, 'dynamic', 'build') != null, 'dynamic invocation by name');
  check(_find(refs, 'dynamic', 'get:first') != null, 'dynamic get is get:name');
  check(_find(refs, 'dynamic', 'set:name') != null, 'dynamic set is set:name');
  check(_find(refs, 'dynamic', '[]') != null, 'dynamic [] (jsonDecode data)');
  check(
    _find(refs, 'instance', 'build', cls: 'Widget') != null,
    'an app class with the called name is a candidate reference',
  );

  final recv = LocalVariable(name: 'l');
  final tear = _proc(app, 'tear', [
    ExpressionStatement(
      InstanceTearOff(
        InstanceAccessKind.Instance,
        VariableGet(recv),
        Name('add'),
        interfaceTarget: add,
        resultType: ft,
      ),
    ),
    ExpressionStatement(
      InstanceInvocation(
        InstanceAccessKind.Instance,
        VariableGet(recv),
        Name('add'),
        _noArgs,
        interfaceTarget: add,
        functionType: ft,
      ),
    ),
    ExpressionStatement(
      InstanceGet(
        InstanceAccessKind.Instance,
        VariableGet(recv),
        Name('length'),
        interfaceTarget: getter,
        resultType: const DynamicType(),
      ),
    ),
  ]);
  final t = externalReferencesOf(tear, {});
  check(_find(t, 'instance', 'tearoff:add') != null, 'tear-off is its own key');
  check(_find(t, 'instance', 'add') != null, 'the call keeps the plain key');
  check(_find(t, 'instance', 'get:length') != null, 'getter is get:length');

  // Extension-type member.
  final et = _lib('package:app/et.dart');
  final etMember = _proc(et, 'ET|get#x', [], kind: ProcedureKind.Method)
    ..isExtensionTypeMember = true;
  final useEt = _proc(app, 'useEt', [
    ExpressionStatement(
      StaticInvocation(etMember, _noArgs),
    ),
  ]);
  final e = externalReferencesOf(useEt, {});
  check(
    _find(e, 'top-level', 'ET|get#x') != null,
    'an extension-type member is reported',
  );

  // for-in.
  final item = LocalVariable(name: 'i');
  final loop = _proc(app, 'loop', [
    ForInStatement(item, NullLiteral(), Block([])),
  ]);
  final f = externalReferencesOf(loop, {});
  for (final m in ['get:iterator']) {
    check(_find(f, 'instance', m, cls: 'Iterable') != null, 'for-in $m');
  }
  check(
    _find(f, 'instance', 'moveNext', cls: 'Iterator') != null,
    'for-in moveNext',
  );
  check(
    _find(f, 'instance', 'get:current', cls: 'Iterator') != null,
    'for-in current',
  );

  // viaConstant does not collapse into a direct use.
  final fw = _lib('package:fw/x.dart');
  final box = _cls(fw, 'Box');
  final field = Field.immutable(
    Name('size', fw),
    fileUri: fw.fileUri,
    type: const DynamicType(),
  );
  box.addField(field);
  final both = _proc(app, 'both', [
    ExpressionStatement(
      InstanceGet(
        InstanceAccessKind.Instance,
        NullLiteral(),
        Name('size'),
        interfaceTarget: field,
        resultType: const DynamicType(),
      ),
    ),
    ExpressionStatement(
      ConstantExpression(
        InstanceConstant(box.reference, const [], {
          field.getterReference: IntConstant(1),
        }),
      ),
    ),
  ]);
  final b = externalReferencesOf(both, {});
  check(
    b.where((r) => r['member'] == 'size').length == 2 &&
        b.any((r) => r['member'] == 'size' && r['viaConstant'] == true) &&
        b.any((r) => r['member'] == 'size' && r['viaConstant'] != true),
    'a direct use and a constant use are two entries',
  );

  // Class scope (`enclosingScope`): a use of the class's OWN static is reported
  // with its identifier's offset, a class type parameter is reported, and a
  // static of another class is not.
  final scopeLib = _lib('package:app/scope.dart');
  final owner = _cls(scopeLib, 'C');
  final typeParam = TypeParameter('T');
  owner.typeParameters.add(typeParam);
  typeParam.parent = owner;
  final ownStatic = Field.mutable(
    Name('k', scopeLib),
    isStatic: true,
    fileUri: scopeLib.fileUri,
    type: const DynamicType(),
  );
  owner.addField(ownStatic);
  final otherStatic = Field.mutable(
    Name('j', scopeLib),
    isStatic: true,
    fileUri: scopeLib.fileUri,
    type: const DynamicType(),
  );
  _cls(scopeLib, 'D').addField(otherStatic);
  final member = _method(owner, 'f');
  member.function.body = Block([
    ExpressionStatement(StaticGet(ownStatic)..fileOffset = 42),
    ExpressionStatement(StaticGet(otherStatic)..fileOffset = 50),
    ExpressionStatement(
      AsExpression(
        NullLiteral(),
        TypeParameterType(typeParam, Nullability.nonNullable),
      ),
    ),
  ]);
  final scope = enclosingScopeOf(
    member,
    source: '${' ' * 42}k;',
  )!;
  final used = (scope['staticReferences']! as List).cast<Map>();
  check(
    used.length == 1 &&
        used.single['offset'] == 42 &&
        used.single['member'] == 'k' &&
        used.single['kind'] == 'get',
    'an own class static is reported at its offset, another class is not',
  );
  check(
    (scope['usedTypeParameters']! as List).contains('T') &&
        (scope['problems']! as List).isEmpty,
    'a class type parameter is reported',
  );
  check(
    enclosingScopeOf(_proc(app, 'top', [])) == null,
    'a top-level member has no class scope',
  );

  if (_failures > 0) exit(1);
  stdout.writeln('all passed');
}
