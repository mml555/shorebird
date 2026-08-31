// D-SUPER-2B.1f. The semantic super targets a given method direct-calls, as
// source-provenance fingerprints.
//
// Run over TWO kernels for two different jobs:
//
//   RELEASE AOT        what the release version of this method already
//                      direct-called -- and therefore what AOT had to compile
//   PATCHED no-AOT     what the patched version of the same method resolves to
//                      locally, which is what the DirectCall will name
//
// THE FINGERPRINT IS PROVENANCE ONLY: fileUri | fileOffset | name | kind. No
// synthetic owner: AOT mixin deduplication renames the owning
// mixin-application class, so a canonical name is not portable between these
// two kernels (2A / 2A.2). No arity either -- TFA rewrites it (2B.0).
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/core_types.dart';

String fingerprint(Member m) => [
  m.fileUri.toString(),
  m.fileOffset,
  m.name.text,
  m is Procedure ? m.kind.name : m.runtimeType.toString(),
].join('|');

void main(List<String> args) {
  String? dill;
  String? platform;
  String? className;
  String? method;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--dill':
        dill = args[++i];
      case '--platform':
        platform = args[++i];
      case '--class':
        className = args[++i];
      case '--method':
        method = args[++i];
      default:
        stderr.writeln('unknown argument: ${args[i]}');
        exit(2);
    }
  }
  if (dill == null || className == null || method == null) {
    stderr.writeln('usage: --dill <d> [--platform <p>] --class <C> '
        '--method <m>');
    exit(2);
  }

  final component = Component();
  // A --no-aot --no-link-platform kernel has no `dart:core`, and ClassHierarchy
  // cannot be built without it.
  if (platform != null) {
    BinaryBuilder(File(platform).readAsBytesSync()).readComponent(component);
  }
  BinaryBuilder(File(dill).readAsBytesSync()).readComponent(component);
  final hierarchy = ClassHierarchy(component, CoreTypes(component));

  final out = <Map<String, Object?>>[];
  for (final lib in component.libraries) {
    if (lib.importUri.toString().startsWith('dart:')) continue;
    for (final cls in lib.classes) {
      if (cls.name != className) continue;
      for (final p in cls.procedures) {
        if (p.name.text != method) continue;
        final visitor = _Sites();
        p.function.accept(visitor);
        for (final site in visitor.sites) {
          final superclass = cls.superclass;
          final resolved = superclass == null
              ? null
              : hierarchy.getDispatchTarget(
                  superclass,
                  site.name.text.startsWith('_')
                      ? Name(site.name.text, lib)
                      : site.name,
                );
          out.add({
            'member': site.name.text,
            'offset': site.fileOffset,
            // Null when nothing resolves. Reported rather than skipped: a site
            // with no target is a finding, not an absence.
            'fingerprint': resolved == null ? null : fingerprint(resolved),
          });
        }
      }
    }
  }
  print(jsonEncode(out));
}

class _Sites extends RecursiveVisitor {
  final sites = <SuperMethodInvocation>[];
  @override
  void visitSuperMethodInvocation(SuperMethodInvocation node) {
    sites.add(node);
    node.visitChildren(this);
  }
}
