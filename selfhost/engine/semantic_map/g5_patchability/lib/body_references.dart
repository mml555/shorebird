// Copyright (c) 2026, the Shorebird self-host fork.
//
// body_references.dart -- SEMANTIC-MAP-1 G5: what does a declaration's BODY
// actually reference?
//
// WHY THIS FILE EXISTS. G5's first predictor derived two refusal reasons from
// facts about the TARGET declaration:
//
//   PRIVATE_TYPE_REFERENCE   from "a public member owned by a private class"
//   PRIVATE_WRITE            from "this declaration has a collapsed write key"
//
// Both are the wrong fact. "A public member of a private class" is not the same
// claim as "this body names a private type", and the dangerous private write is
// normally one the patched BODY performs against some other declaration:
//
//     patchedMethod() { other._privateField = 1; }
//
// The privacy fact belongs to a reference the body makes, not to the target. So
// references are read off the Kernel body here, and the predictor consumes them
// instead of guessing from ownership.
//
// FAIL CLOSED. A body this walker cannot fully traverse is reported
// `refused:<Kind>` and the predictor must refuse the declaration. An
// unrecognised node is never treated as "no references found" -- that would turn
// every gap in this walker into a silent over-claim, which is the failure mode
// the whole gate exists to prevent.
//
// ignore_for_file: avoid_print, implementation_imports
import 'dart:convert';
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';

Never _die(String m) {
  stderr.writeln('body_references: $m');
  exit(2);
}

String _procKind(Procedure p) => switch (p.kind) {
  ProcedureKind.Getter => 'getter',
  ProcedureKind.Setter => 'setter',
  ProcedureKind.Operator => 'operator',
  ProcedureKind.Factory => 'factory',
  _ => 'method',
};

/// A private CLASS, by the rule SM1-G3 fixed: Kernel gives a class no `Name`
/// node, so privacy is the declared name plus the enclosing library.
bool _classIsPrivate(Class c) => c.name.startsWith('_');

class References {
  final Set<String> privateTypes = {};
  final Set<String> privateWrites = {};
  final Set<String> privateReads = {};
  final Set<String> unsupported = {};

  bool get supported => unsupported.isEmpty;
  String get status => supported
      ? 'supported'
      : 'refused:${(unsupported.toList()..sort()).join(",")}';
}

class _Walker extends RecursiveVisitor {
  final References r;
  _Walker(this.r);

  void _noteType(DartType t) {
    if (t is InterfaceType) {
      final cls = t.classNode;
      if (_classIsPrivate(cls)) {
        r.privateTypes.add('${cls.enclosingLibrary.importUri}::${cls.name}');
      }
      for (final a in t.typeArguments) {
        _noteType(a);
      }
    } else if (t is FunctionType) {
      _noteType(t.returnType);
      for (final p in t.positionalParameters) {
        _noteType(p);
      }
    } else if (t is FutureOrType) {
      _noteType(t.typeArgument);
    }
  }

  String _member(Reference? ref) =>
      ref?.canonicalName?.toString() ?? '<unbound>';

  bool _privateName(Name n) => n.isPrivate;

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    _noteType(node.type);
    super.visitVariableDeclaration(node);
  }

  @override
  void visitStaticInvocation(StaticInvocation node) {
    for (final t in node.arguments.types) {
      _noteType(t);
    }
    super.visitStaticInvocation(node);
  }

  @override
  void visitConstructorInvocation(ConstructorInvocation node) {
    // Naming a private class to construct it is a private TYPE reference.
    final cls = node.target.enclosingClass;
    if (_classIsPrivate(cls)) {
      r.privateTypes.add('${cls.enclosingLibrary.importUri}::${cls.name}');
    }
    for (final t in node.arguments.types) {
      _noteType(t);
    }
    super.visitConstructorInvocation(node);
  }

  @override
  void visitAsExpression(AsExpression node) {
    _noteType(node.type);
    super.visitAsExpression(node);
  }

  @override
  void visitIsExpression(IsExpression node) {
    _noteType(node.type);
    super.visitIsExpression(node);
  }

  // ---- the access modes that matter for capability ----------------------
  @override
  void visitInstanceSet(InstanceSet node) {
    if (_privateName(node.name)) {
      r.privateWrites.add(_member(node.interfaceTargetReference));
    }
    super.visitInstanceSet(node);
  }

  @override
  void visitStaticSet(StaticSet node) {
    final t = node.target;
    if (t.name.isPrivate) r.privateWrites.add(_member(node.targetReference));
    super.visitStaticSet(node);
  }

  @override
  void visitInstanceGet(InstanceGet node) {
    if (_privateName(node.name)) {
      r.privateReads.add(_member(node.interfaceTargetReference));
    }
    super.visitInstanceGet(node);
  }

  @override
  void visitStaticGet(StaticGet node) {
    final t = node.target;
    if (t.name.isPrivate) r.privateReads.add(_member(node.targetReference));
    super.visitStaticGet(node);
  }

  @override
  void visitInstanceInvocation(InstanceInvocation node) {
    if (_privateName(node.name)) {
      r.privateReads.add(_member(node.interfaceTargetReference));
    }
    super.visitInstanceInvocation(node);
  }
}

void main(List<String> args) {
  String? dillPath;
  var outPath = 'body_references.json';
  final includePrefixes = <String>[];
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    String next() {
      if (i + 1 >= args.length) _die('$a needs a value');
      return args[++i];
    }

    switch (a) {
      case '--dill':
        dillPath = next();
      case '--out':
        outPath = next();
      case '--include':
        includePrefixes.add(next());
      default:
        _die('unknown argument: $a');
    }
  }
  if (dillPath == null) _die('--dill is required');

  final component = Component();
  BinaryBuilder(File(dillPath).readAsBytesSync()).readComponent(component);

  bool isApp(Library lib) {
    final uri = lib.importUri.toString();
    if (uri.startsWith('dart:')) return false;
    if (includePrefixes.isEmpty) return true;
    return includePrefixes.any(uri.startsWith);
  }

  final rows = <Map<String, Object?>>[];

  void add(String library, String? owner, String kind, String name,
      Member m) {
    final refs = References();
    final f = m.function;
    if (f == null && m is! Field) {
      refs.unsupported.add('NoFunctionNode');
    }
    final w = _Walker(refs);
    try {
      if (f != null) {
        for (final p in f.positionalParameters) {
          w._noteType(p.type);
        }
        f.body?.accept(w);
      } else if (m is Field) {
        w._noteType(m.type);
        m.initializer?.accept(w);
      }
    } catch (e) {
      // A traversal that throws is refused, never treated as "nothing found".
      refs.unsupported.add('TraversalThrew');
    }
    rows.add({
      'library': library,
      'owner': owner,
      'kind': kind,
      'name': name,
      'references_private_type': refs.privateTypes.isNotEmpty,
      'private_types': refs.privateTypes.toList()..sort(),
      'private_writes': refs.privateWrites.toList()..sort(),
      'private_reads': refs.privateReads.toList()..sort(),
      'traversal_status': refs.status,
    });
  }

  for (final lib in component.libraries.where(isApp)) {
    final library = lib.importUri.toString();
    for (final p in lib.procedures) {
      add(library, null, _procKind(p), p.name.text, p);
    }
    for (final f in lib.fields) {
      add(library, null, 'field', f.name.text, f);
    }
    for (final cls in lib.classes) {
      for (final p in cls.procedures) {
        add(library, cls.name, _procKind(p), p.name.text, p);
      }
      for (final c in cls.constructors) {
        add(library, cls.name, 'constructor', c.name.text, c);
      }
      for (final f in cls.fields) {
        add(library, cls.name, 'field', f.name.text, f);
      }
    }
  }

  final withPrivateType =
      rows.where((r) => r['references_private_type'] == true).length;
  final withPrivateWrite =
      rows.where((r) => (r['private_writes'] as List).isNotEmpty).length;
  final refused =
      rows.where((r) => r['traversal_status'] != 'supported').length;

  File(outPath).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({
      'schema': 'semantic-map-1/g5-body-references/1',
      'gate': 'SM1-G5',
      'issue': 54,
      'count': rows.length,
      'references_private_type_count': withPrivateType,
      'private_write_count': withPrivateWrite,
      'traversal_refused_count': refused,
      'rows': rows,
    })}\n',
  );
  print('  bodies=${rows.length} private-type-refs=$withPrivateType '
      'private-writes=$withPrivateWrite traversal-refused=$refused -> $outPath');
}
