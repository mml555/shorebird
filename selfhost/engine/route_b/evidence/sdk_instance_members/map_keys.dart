// map_keys.dart <patched.dill> <out.tsv>: for every probe function `p_<id>`
// in the container target, the `library#Class#member` key of each dart:
// instance member it references (the same key the retention check uses).
import 'dart:io';
import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';

void main(List<String> a) {
  final c = Component();
  BinaryBuilder(File(a[0]).readAsBytesSync()).readComponent(c);
  final out = StringBuffer();
  for (final lib in c.libraries) {
    if (!lib.importUri.path.endsWith('container_target.dart')) continue;
    for (final p in lib.procedures) {
      if (!p.name.text.startsWith('p_')) continue;
      final keys = <String>{};
      p.accept(_V(keys));
      out.writeln('${p.name.text.substring(2)}\t${keys.join(' ')}');
    }
  }
  File(a[1]).writeAsStringSync(out.toString());
}

class _V extends RecursiveVisitor {
  _V(this.keys);
  final Set<String> keys;
  void _m(Reference? r) {
    final m = r?.node;
    if (m is! Member) return;
    final cls = m.enclosingClass;
    final lib = m.enclosingLibrary.importUri;
    if (cls == null || lib.scheme != 'dart') return;
    var n = m.name.text;
    if (m is Procedure && m.isGetter) n = 'get:$n';
    if (m is Procedure && m.isSetter) n = 'set:$n';
    keys.add('$lib#${cls.name}#$n');
  }
  @override
  void visitInstanceInvocation(InstanceInvocation n) { _m(n.interfaceTargetReference); super.visitInstanceInvocation(n); }
  @override
  void visitInstanceGet(InstanceGet n) { _m(n.interfaceTargetReference); super.visitInstanceGet(n); }
  @override
  void visitInstanceSet(InstanceSet n) { _m(n.interfaceTargetReference); super.visitInstanceSet(n); }
  @override
  void visitEqualsCall(EqualsCall n) { _m(n.interfaceTargetReference); super.visitEqualsCall(n); }
}
