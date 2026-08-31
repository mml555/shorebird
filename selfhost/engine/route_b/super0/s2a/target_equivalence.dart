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

/// D-SUPER-2A.2. The SEMANTIC identity of a target, built from SOURCE
/// PROVENANCE rather than from its transformed owner.
///
/// Canonical names are not usable across the boundary: AOT mixin deduplication
/// renames the owning mixin-application class, so
/// `dart:mixin_deduplication::_MixinApplication279&State&…::dispose` and
/// `package:wonders/…::__HomeScreenState&State&…::dispose` are the same
/// declaration under two identities (D-SUPER-2A). A mixin-application member is
/// a CLONE of the mixin's member, so the question this fingerprint asks is
/// whether the clone keeps the provenance of what it was cloned from.
///
/// Deliberately excludes the enclosing class. Including it would reintroduce
/// exactly the transformed identity the design is trying to become independent
/// of.
/// PROVENANCE ONLY: where the declaration came from. Dart has no overloading,
/// so within a library a file offset plus a name and kind identifies exactly one
/// declaration, and no rename can move any of them.
String? _fingerprint(Member? m) {
  if (m == null) return null;
  return [
    m.fileUri.toString(),
    m.fileOffset,
    m.name.text,
    m is Procedure ? m.kind.name : m.runtimeType.toString(),
  ].join('|');
}

/// The SHAPE, reported SEPARATELY and deliberately not part of the provenance
/// key, because it is not stable across the AOT boundary.
///
/// TFA specialises a callee for its call sites. Measured on `ArgParent.tag`:
/// the import kernel has `tag(String a, int b)` and the source super call reads
/// `super.tag('a', 7)`, while the AOT kernel has `tag()` with the two arguments
/// frozen into the body as constants and the call site rewritten to
/// `super.tag()`. Folding arity into the provenance key made that site read as a
/// target mismatch, which it is not — the declaration is the same one, at the
/// same offset.
String? _shape(Member? m) {
  if (m is! Procedure) return null;
  final f = m.function;
  return [
    f.requiredParameterCount,
    f.positionalParameters.length,
    (f.namedParameters.map((p) => p.name).toList()..sort()).join(','),
    f.typeParameters.length,
  ].join('|');
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

  /// A [Name] usable in [component]'s own hierarchy.
  ///
  /// A private name carries a library REFERENCE, and the reference from the AOT
  /// component does not match the import component's library object -- which is
  /// why the first run of this tool reported `PrivChild.go` as "not comparable"
  /// rather than as a result. Rebuilding the name against the target component
  /// makes the private case measurable instead of silently excluded.
  Name nameIn(Component? component, Name name) {
    if (component == null || !name.text.startsWith('_')) return name;
    final uri = name.library?.importUri.toString();
    if (uri == null) return name;
    for (final lib in component.libraries) {
      if (lib.importUri.toString() == uri) return Name(name.text, lib);
    }
    return name;
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
              nameIn(imp, site.name),
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
            // The 2A.2 comparison. A == B is the claim; the canonical names
            // above are kept only to show WHY the name comparison fails.
            'fingerprintAot': _fingerprint(site.interfaceTarget),
            'fingerprintImport': _fingerprint(viaImport),
            'shapeAot': _shape(site.interfaceTarget),
            'shapeImport': _shape(viaImport),
            // The argument count AT THE CALL SITE in the AOT kernel. Recorded
            // because a v1 gate of "zero arguments" read from this kernel would
            // be unsound: TFA can rewrite `super.tag('a', 7)` to `super.tag()`.
            'callSiteArgsAot': site.argCount,
            'twinFound': t != null,
          });
        }
      }
    }
  }

  var matchAot = 0, mismatchAot = 0, matchImport = 0, mismatchImport = 0;
  var noTwin = 0;
  var fpMatch = 0, fpMismatch = 0, fpUnavailable = 0;
  var shapeSame = 0, shapeDiffers = 0;
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
    final a = r['fingerprintAot'], b = r['fingerprintImport'];
    if (a == null || b == null) {
      fpUnavailable++;
    } else if (a == b) {
      fpMatch++;
    } else {
      fpMismatch++;
    }
    final sa = r['shapeAot'], sb = r['shapeImport'];
    if (sa != null && sb != null) {
      if (sa == sb) {
        shapeSame++;
      } else {
        shapeDiffers++;
      }
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
    'fingerprintMatch': fpMatch,
    'fingerprintMismatch': fpMismatch,
    'fingerprintUnavailable': fpUnavailable,
    'shapeSame': shapeSame,
    'shapeDiffersAcrossKernels': shapeDiffers,
  }));
  for (final r in rows) {
    final nameBad = r['retainedInterfaceTarget'] != r['viaHierarchyAot'] ||
        (r['twinFound'] == true &&
            r['viaHierarchyImport'] != null &&
            r['retainedInterfaceTarget'] != r['viaHierarchyImport']);
    final fpA = r['fingerprintAot'], fpB = r['fingerprintImport'];
    final fpBad = fpA == null || fpB == null || fpA != fpB;
    // Two labels, because they are two different claims: NAME-ONLY is the
    // expected 2A finding and is not a failure of the 2A.2 rule.
    final shapeBad = r['shapeAot'] != null &&
        r['shapeImport'] != null &&
        r['shapeAot'] != r['shapeImport'];
    final label = fpBad
        ? 'FINGERPRINT-MISMATCH '
        : shapeBad
        ? 'SHAPE-DIFFERS        '
        : (nameBad ? 'name-only-differs    ' : 'match                ');
    print('$label${jsonEncode(r)}');
  }
  if (fpMismatch != 0 || fpUnavailable != 0) {
    stderr.writeln('\nSTOP: $fpMismatch fingerprint mismatch(es), '
        '$fpUnavailable unavailable. Locally re-derived targets do not '
        'provably name the same declaration as the retained ones, and there is '
        'NO fallback to canonical names.');
    exit(1);
  }
  if (mismatchAot != 0) {
    stderr.writeln('\nSTOP: $mismatchAot within-AOT mismatch(es) — '
        'interfaceTarget and the AOT hierarchy disagree, which 2A did not see.');
    exit(1);
  }
  if (shapeDiffers != 0) {
    stderr.writeln('\nNOTE: $shapeDiffers site(s) whose TARGET SIGNATURE differs '
        'between the two kernels. The declaration is the same; TFA specialised '
        'it. A v1 gate that reads an argument count from the AOT kernel would '
        'be unsound.');
  }
  stderr.writeln('\nCross-kernel structural re-derivation: fingerprints agree '
      'on all ${rows.length} site(s). $mismatchImport of them have '
      'DIFFERENT canonical names, which is the 2A finding and is exactly what '
      'the fingerprint is designed not to depend on.');
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
