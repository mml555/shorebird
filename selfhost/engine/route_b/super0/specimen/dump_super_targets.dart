// D-SUPER-0 step 1: what does the RELEASE kernel retain for a super call?
// ignore_for_file: avoid_print
import 'dart:io';
import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';
import 'package:kernel/text/ast_to_text.dart';

void main(List<String> args) {
  final c = Component();
  BinaryBuilder(File(args[0]).readAsBytesSync()).readComponent(c);
  for (final lib in c.libraries) {
    if (!lib.importUri.toString().startsWith('package:corpus/')) continue;
    for (final cls in lib.classes) {
      for (final p in cls.procedures) {
        final v = _Super();
        p.function.accept(v);
        if (v.hits.isEmpty) continue;
        print('${cls.name}.${p.name.text}');
        for (final h in v.hits) print('    $h');
        print('    printed: ${_print(p).trim().split('\n').last.trim()}');
      }
    }
  }
}

String _print(Procedure p) {
  final b = StringBuffer();
  Printer(b).writeNode(p);
  return b.toString();
}

class _Super extends RecursiveVisitor {
  final hits = <String>[];
  @override
  void visitSuperMethodInvocation(SuperMethodInvocation node) {
    hits.add('SuperMethodInvocation name=${node.name.text} '
        'interfaceTarget=${node.interfaceTarget.enclosingClass?.name}'
        '.${node.interfaceTarget.name.text} '
        'kind=${node.interfaceTarget.kind} '
        'ref=${node.interfaceTarget.reference.canonicalName}');
    node.visitChildren(this);
  }

  @override
  void visitSuperPropertyGet(SuperPropertyGet node) {
    hits.add('SuperPropertyGet name=${node.name.text} '
        'interfaceTarget=${node.interfaceTarget?.enclosingClass?.name}'
        '.${node.interfaceTarget?.name.text} '
        'ref=${node.interfaceTarget?.reference.canonicalName}');
    node.visitChildren(this);
  }
}
