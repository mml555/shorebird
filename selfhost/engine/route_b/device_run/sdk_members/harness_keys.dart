// harness_keys.dart <app.dill> <out.keys>
//
// The `library#Class#member` keys (and `dynamic#<selector>`) of the SDK instance members that the
// release app's OWN code references, outside the probe functions `p_*`. A member the app itself
// calls is kept by the app, so a "resolves" on it would be the app's doing, not Flutter's.
// Same visitor as the host matrix's map_keys.dart (--harness), restricted to the app's library.
import 'dart:io';
import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';

void main(List<String> a) {
  final c = Component();
  BinaryBuilder(File(a[0]).readAsBytesSync()).readComponent(c);
  final keys = <String>{};
  for (final lib in c.libraries) {
    if (lib.importUri.toString() != 'package:untab/main.dart') continue;
    lib.accept(_V(keys, skipProbes: true));
  }
  File(a[1]).writeAsStringSync(
      '${(keys.toList()..sort()).join('\n')}\n');
  stdout.writeln('${keys.length} keys');
}

class _V extends RecursiveVisitor {
  _V(this.keys, {this.skipProbes = false});
  final Set<String> keys;
  final bool skipProbes;

  @override
  void visitProcedure(Procedure node) {
    final n = node.name.text;
    if (skipProbes &&
        n.startsWith('p_')) {
      return;
    }
    super.visitProcedure(node);
  }

  void _m(Reference? r, {bool tearOff = false}) {
    final m = r?.node;
    if (m is! Member) return;
    final cls = m.enclosingClass;
    final lib = m.enclosingLibrary.importUri;
    if (cls == null || lib.scheme != 'dart') return;
    var n = m.name.text;
    if (m is Procedure && m.isGetter) n = 'get:$n';
    if (m is Procedure && m.isSetter) n = 'set:$n';
    if (tearOff) n = 'tearoff:$n';
    keys.add('$lib#${cls.name}#$n');
  }

  @override
  void visitInstanceInvocation(InstanceInvocation n) {
    _m(n.interfaceTargetReference);
    super.visitInstanceInvocation(n);
  }

  @override
  void visitInstanceGet(InstanceGet n) {
    _m(n.interfaceTargetReference);
    super.visitInstanceGet(n);
  }

  @override
  void visitInstanceSet(InstanceSet n) {
    _m(n.interfaceTargetReference);
    super.visitInstanceSet(n);
  }

  @override
  void visitEqualsCall(EqualsCall n) {
    _m(n.interfaceTargetReference);
    super.visitEqualsCall(n);
  }

  @override
  void visitInstanceTearOff(InstanceTearOff n) {
    _m(n.interfaceTargetReference, tearOff: true);
    super.visitInstanceTearOff(n);
  }

  @override
  void visitDynamicInvocation(DynamicInvocation n) {
    keys.add('dynamic#${n.name.text}');
    super.visitDynamicInvocation(n);
  }

  @override
  void visitDynamicGet(DynamicGet n) {
    keys.add('dynamic#get:${n.name.text}');
    super.visitDynamicGet(n);
  }

  @override
  void visitDynamicSet(DynamicSet n) {
    keys.add('dynamic#set:${n.name.text}');
    super.visitDynamicSet(n);
  }

  @override
  void visitForInStatement(ForInStatement n) {
    keys.add('dart:core#Iterable#get:iterator');
    keys.add('dart:core#Iterator#moveNext');
    keys.add('dart:core#Iterator#get:current');
    super.visitForInStatement(n);
  }
}
