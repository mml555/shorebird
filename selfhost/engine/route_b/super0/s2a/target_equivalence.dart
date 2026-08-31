// D-SUPER-2A. Is `SuperMethodInvocation.interfaceTarget` — the identity the
// release kernel retains and the analyzer would report — the SAME Procedure that
// dart2bytecode selects today via
// `hierarchy.getDispatchTarget(enclosingClass.superclass, name)`?
//
// This must be settled BEFORE the product intrinsic consumes interfaceTarget,
// because the two are different derivations of "the super target" and this
// project keeps disproving "two representations ought to mean the same thing".
// dart2bytecode's own `visitSuperInitializer` even carries the comment
// "Re-resolve target due to partial mixin resolution", which is a standing hint
// about where they would diverge.
//
// THE COMPARISON SPANS TWO DILLS ON PURPOSE. In the product pipeline these two
// derivations do not even happen in the same kernel:
//
//   interfaceTarget      read by the analyzer from the RELEASE's --aot --tfa dill
//   getDispatchTarget    computed by dart2bytecode while compiling the
//                        replacement against the --no-aot --import-dill kernel
//
// Comparing them only inside one dill would miss a divergence introduced by the
// AOT/TFA transforms themselves, which is exactly the kind of gap that shows up
// on a device instead of here.
//
// Reports every site. Any mismatch is a STOP, not something to normalise.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/core_types.dart';

Component _load(String path, {String? platform}) {
  final c = Component();
  // The platform first, when given. An `--import-dill` kernel is built
  // `--no-link-platform`, so `dart:core` is absent from it and ClassHierarchy
  // cannot be constructed at all -- the first run of this tool died on exactly
  // that. dart2bytecode has the same requirement and solves it the same way, by
  // being handed `--platform` alongside `--import-dill`, so loading both here is
  // reproducing its conditions rather than working around a limitation.
  if (platform != null) {
    BinaryBuilder(File(platform).readAsBytesSync()).readComponent(c);
  }
  BinaryBuilder(File(path).readAsBytesSync()).readComponent(c);
  return c;
}

String? _canonical(Member? m) {
  if (m == null) return null;
  final cls = m.enclosingClass?.name ?? '<top>';
  final lib = m.enclosingLibrary.importUri.toString();
  final kind = m is Procedure ? m.kind.name : m.runtimeType.toString();
  return '$lib::$cls::$kind::${m.name.text}';
}

void main(List<String> args) {
  String? aotPath;
  String? importPath;
  String? platformPath;
  final prefixes = <String>[];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--aot-dill':
        aotPath = args[++i];
      case '--import-dill':
        importPath = args[++i];
      case '--platform':
        platformPath = args[++i];
      case '--include':
        prefixes.add(args[++i]);
      default:
        stderr.writeln('unknown argument: ${args[i]}');
        exit(2);
    }
  }
  if (aotPath == null) {
    stderr.writeln('usage: --aot-dill <release.dill> '
        '[--import-dill <import.dill> --platform <vm_platform.dill>] '
        '[--include <prefix>]...');
    exit(2);
  }

  final aot = _load(aotPath);
  final aotHierarchy = ClassHierarchy(aot, CoreTypes(aot));

  Component? imp;
  ClassHierarchy? impHierarchy;
  if (importPath != null) {
    imp = _load(importPath, platform: platformPath);
    impHierarchy = ClassHierarchy(imp, CoreTypes(imp));
  }

  bool isApp(Library lib) {
    final uri = lib.importUri.toString();
    if (uri.startsWith('dart:')) return false;
    return prefixes.isEmpty || prefixes.any(uri.startsWith);
  }

  // The same class, located in the OTHER component. Matched by library URI and
  // class name rather than by identity, because they are different objects from
  // different dills — which is the whole point of comparing across them.
  Class? twin(Class cls) {
    if (imp == null) return null;
    final uri = cls.enclosingLibrary.importUri.toString();
    for (final lib in imp!.libraries) {
      if (lib.importUri.toString() != uri) continue;
      for (final c in lib.classes) {
        if (c.name == cls.name) return c;
      }
    }
    return null;
  }

  final rows = <Map<String, Object?>>[];
  for (final lib in aot.libraries.where(isApp)) {
    for (final cls in lib.classes) {
      for (final p in cls.procedures) {
        final visitor = _SuperSites(cls);
        p.function.accept(visitor);
        for (final site in visitor.sites) {
          final retained = _canonical(site.interfaceTarget);

          // dart2bytecode's derivation, in the AOT dill.
          Member? viaAot;
          final sup = cls.superclass;
          if (sup != null) {
            viaAot = aotHierarchy.getDispatchTarget(
              sup,
              site.name,
              setter: site.isSetter,
            );
          }

          // The same derivation where it ACTUALLY happens: the import kernel.
          Member? viaImport;
          final t = twin(cls);
          final tSup = t?.superclass;
          if (tSup != null && impHierarchy != null) {
            viaImport = impHierarchy.getDispatchTarget(
              tSup,
              site.name,
              setter: site.isSetter,
            );
          }

          rows.add({
            'site': '${lib.importUri}#${cls.name}.${p.name.text}',
            'shape': site.shape,
            'name': site.name.text,
            'enclosingClass': cls.name,
            'superclass': sup?.name,
            'retainedInterfaceTarget': retained,
            'viaHierarchyAot': _canonical(viaAot),
            'viaHierarchyImport': _canonical(viaImport),
            'twinFound': t != null,
          });
        }
      }
    }
  }

  var matchAot = 0, mismatchAot = 0, matchImport = 0, mismatchImport = 0;
  var noTwin = 0;
  for (final r in rows) {
    final retained = r['retainedInterfaceTarget'];
    if (retained == r['viaHierarchyAot']) {
      matchAot++;
    } else {
      mismatchAot++;
    }
    if (r['twinFound'] != true || r['viaHierarchyImport'] == null) {
      noTwin++;
    } else if (retained == r['viaHierarchyImport']) {
      matchImport++;
    } else {
      mismatchImport++;
    }
  }

  print(jsonEncode({
    'aotDill': aotPath,
    'importDill': importPath,
    'sites': rows.length,
    'matchInAotDill': matchAot,
    'mismatchInAotDill': mismatchAot,
    'matchInImportDill': matchImport,
    'mismatchInImportDill': mismatchImport,
    'importSideNotComparable': noTwin,
  }));
  for (final r in rows) {
    final bad = r['retainedInterfaceTarget'] != r['viaHierarchyAot'] ||
        (r['twinFound'] == true &&
            r['viaHierarchyImport'] != null &&
            r['retainedInterfaceTarget'] != r['viaHierarchyImport']);
    print('${bad ? 'MISMATCH ' : 'match    '}${jsonEncode(r)}');
  }
  if (mismatchAot != 0 || mismatchImport != 0) {
    stderr.writeln('\nSTOP: ${mismatchAot + mismatchImport} mismatch(es). '
        'The two derivations of "the super target" do not agree, and the '
        'product rule cannot be chosen until the ORIGINAL UNPATCHED program is '
        'run to establish which Procedure actually executes.');
    exit(1);
  }
}

class _SuperSites extends RecursiveVisitor {
  _SuperSites(this.enclosing);
  final Class enclosing;
  final sites = <_Site>[];

  @override
  void visitSuperMethodInvocation(SuperMethodInvocation node) {
    sites.add(_Site('SuperMethodInvocation', node.name, node.interfaceTarget,
        isSetter: false,
        argCount: node.arguments.positional.length +
            node.arguments.named.length +
            node.arguments.types.length));
    node.visitChildren(this);
  }

  @override
  void visitSuperPropertyGet(SuperPropertyGet node) {
    sites.add(_Site('SuperPropertyGet', node.name, node.interfaceTarget,
        isSetter: false, argCount: 0));
    node.visitChildren(this);
  }

  @override
  void visitSuperPropertySet(SuperPropertySet node) {
    sites.add(_Site('SuperPropertySet', node.name, node.interfaceTarget,
        isSetter: true, argCount: 1));
    node.visitChildren(this);
  }
}

class _Site {
  _Site(this.shape, this.name, this.interfaceTarget,
      {required this.isSetter, required this.argCount});
  final String shape;
  final Name name;
  final Member? interfaceTarget;
  final bool isSetter;
  final int argCount;
}
