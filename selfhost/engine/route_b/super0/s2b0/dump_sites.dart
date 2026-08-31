// Where does SuperMethodInvocation.fileOffset point, and what does each kernel
// say the call site's argument count is? Both are needed before a source-level
// gate can be written against that offset.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';

void main(List<String> args) {
  final source = File(args[0]).readAsStringSync();
  // The platform first. An --import-dill kernel is --no-link-platform, so
  // `dart:core` is absent and any traversal that touches a type dies on an
  // unbound reference. Same requirement dart2bytecode has.
  final platform = args[1];
  for (final path in args.sublist(2)) {
    final c = Component();
    BinaryBuilder(File(platform).readAsBytesSync()).readComponent(c);
    BinaryBuilder(File(path).readAsBytesSync()).readComponent(c);
    print('=== ${path.split('/').last} ===');
    for (final lib in c.libraries) {
      if (!lib.importUri.toString().startsWith('package:corpus/')) continue;
      for (final cls in lib.classes) {
        for (final p in cls.procedures) {
          final v = _V();
          p.function.accept(v);
          for (final n in v.found) {
            final off = n.fileOffset;
            final snippet = (off >= 0 && off < source.length)
                ? source.substring(off, (off + 26).clamp(0, source.length))
                : '<no offset>';
            print(jsonEncode({
              'site': '${cls.name}.${p.name.text}',
              'member': n.name.text,
              'fileOffset': off,
              'callSiteArgs': n.arguments.positional.length +
                  n.arguments.named.length,
              'typeArgs': n.arguments.types.length,
              'sourceAtOffset': snippet.replaceAll('\n', '\\n'),
            }));
          }
        }
      }
    }
  }
}

class _V extends RecursiveVisitor {
  final found = <SuperMethodInvocation>[];
  @override
  void visitSuperMethodInvocation(SuperMethodInvocation n) {
    found.add(n);
    n.visitChildren(this);
  }
}
