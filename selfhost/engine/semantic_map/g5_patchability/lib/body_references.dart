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

/// One private reference a body makes, resolved to a structured identity so the
/// predictor can join it to G3's capability rows. A canonical-name string is
/// not enough: the predictor has to ask G3 about a specific declaration.
class PrivateRef {
  final String library;
  final String? owner;
  /// The referenced declaration's KIND, derived from the resolved Member.
  ///
  /// Without it the predictor had to search G3 across kinds and take the first
  /// match, so a private getter's row could answer for a same-named setter --
  /// the identical loose-identity fault just removed from the release-contract
  /// path, where evidence for A authorises B.
  final String kind;
  final String name;
  final String mode; // read | write | construct
  final bool resolved;
  PrivateRef(this.library, this.owner, this.kind, this.name, this.mode,
      this.resolved);

  /// The exact key the predictor looks up. No fallback search.
  String get targetKey => '$library#${owner ?? ''}#$kind#$name';

  Map<String, Object?> toJson() => {
    'library': library,
    'owner': owner,
    'kind': kind,
    'name': name,
    'target_key': targetKey,
    'mode': mode,
    // An unresolved reference must fail closed in the predictor: "we could not
    // tell which declaration this was" is not "there was nothing to check".
    'resolved': resolved,
  };

  String get k => '$library#${owner ?? ''}#$kind#$name#$mode';
}

class References {
  final Set<String> privateTypes = {};
  final Map<String, PrivateRef> refs = {};
  final Set<String> unsupported = {};

  void add(PrivateRef r) => refs[r.k] = r;

  bool get supported => unsupported.isEmpty;
  String get status => supported
      ? 'supported'
      : 'refused:${(unsupported.toList()..sort()).join(",")}';
}

/// NODE KINDS THIS WALKER UNDERSTANDS.
///
/// Everything outside this set lands in `defaultNode` and marks the body
/// unsupported. That is the difference between a walker that reports "no
/// private references found" and one that reports "I could not see all of this
/// body" -- and it is the whole reason this file exists, since the first
/// version overrode selected node types under RecursiveVisitor and therefore
/// made an unhandled construct look clean.
///
/// The set is grounded by censusing the corpora (`--census`) rather than
/// guessed, exactly as SM1-G2 grounded its body allowlist.
const allowedNodes = <String>{
  // structural / benign
  'Arguments', 'Block', 'Name', 'FunctionNode', 'EmptyStatement',
  'ExpressionStatement', 'ReturnStatement', 'VariableDeclaration',
  'IfStatement', 'NamedExpression', 'Let', 'BlockExpression',
  // literals and constants
  'IntLiteral', 'DoubleLiteral', 'StringLiteral', 'BoolLiteral', 'NullLiteral',
  'SymbolLiteral', 'TypeLiteral', 'ConstantExpression', 'ListLiteral',
  'MapLiteral', 'SetLiteral', 'StringConcatenation',
  // control flow that cannot hide a reference from the overrides below
  'Not', 'LogicalExpression', 'ConditionalExpression', 'ThisExpression',
  'EqualsCall', 'EqualsNull', 'VariableGet', 'VariableSet', 'Throw',
  'Rethrow', 'AwaitExpression', 'ForStatement', 'ForInStatement',
  'WhileStatement', 'DoStatement', 'SwitchStatement', 'SwitchCase',
  'TryCatch', 'Catch', 'TryFinally', 'BreakStatement', 'LabeledStatement',
  'ContinueSwitchStatement', 'AssertStatement', 'AssertBlock',
  'FunctionDeclaration', 'FunctionExpression', 'YieldStatement',
  'InstanceTearOff', 'StaticTearOff', 'FunctionTearOff',
  'LocalFunctionInvocation', 'DynamicInvocation', 'DynamicGet', 'DynamicSet',
  'InstanceGetterInvocation', 'RecordLiteral', 'RecordIndexGet',
  'RecordNameGet', 'NullCheck', 'InstanceCreation', 'FileUriExpression',
  'CheckLibraryIsLoaded', 'LoadLibrary', 'SuperMethodInvocation',
  'SuperPropertyGet', 'SuperPropertySet', 'AbstractSuperMethodInvocation',
  'AbstractSuperPropertyGet', 'AbstractSuperPropertySet',
  'ConstructorTearOff', 'RedirectingFactoryTearOff', 'TypedefTearOff',
  'IsExpression', 'AsExpression', 'InvalidExpression',
  // Kernel's Name is abstract; the runtime types are these two.
  '_PrivateName', '_PublicName',
};

class _Walker extends RecursiveVisitor {
  final References r;
  final bool census;
  final Set<String> seen;
  _Walker(this.r, {this.census = false, Set<String>? seen})
      : seen = seen ?? <String>{};

  // ---- exhaustive type handling ----------------------------------------
  void _noteType(DartType t) {
    switch (t) {
      case InterfaceType():
        final cls = t.classNode;
        if (_classIsPrivate(cls)) {
          r.privateTypes.add('${cls.enclosingLibrary.importUri}::${cls.name}');
        }
        for (final a in t.typeArguments) {
          _noteType(a);
        }
      case ExtensionType():
        for (final a in t.typeArguments) {
          _noteType(a);
        }
      case FunctionType():
        _noteType(t.returnType);
        for (final p in t.positionalParameters) {
          _noteType(p);
        }
        // NAMED PARAMETER TYPES. The first version walked return and positional
        // types only, so a private type reachable only through a named
        // parameter was invisible.
        for (final n in t.namedParameters) {
          _noteType(n.type);
        }
      case RecordType():
        for (final p in t.positional) {
          _noteType(p);
        }
        for (final n in t.named) {
          _noteType(n.type);
        }
      case FutureOrType():
        _noteType(t.typeArgument);
      case TypedefType():
        for (final a in t.typeArguments) {
          _noteType(a);
        }
        _noteType(t.unalias);
      case IntersectionType():
        _noteType(t.left);
        _noteType(t.right);
      case TypeParameterType():
      case StructuralParameterType():
      case DynamicType():
      case VoidType():
      case NeverType():
      case NullType():
      case InvalidType():
        break;
      default:
        // A type this walker does not model cannot be certified free of
        // private references.
        r.unsupported.add('Type:${t.runtimeType}');
    }
  }

  /// TYPES NEVER FALL THROUGH TO defaultNode.
  ///
  /// A DartType reaching the generic path would only be checked against the
  /// node allowlist, which says nothing about whether it hides a private type.
  /// Routing every type through `_noteType` keeps the exhaustive switch there
  /// the single decision point -- and that switch refuses anything it does not
  /// model.
  @override
  void defaultDartType(DartType node) {
    _noteType(node);
  }

  @override
  void defaultNode(Node node) {
    final kind = node.runtimeType.toString();
    if (census) {
      seen.add(kind);
    } else if (!allowedNodes.contains(kind)) {
      r.unsupported.add(kind);
    }
    node.visitChildren(this);
  }

  String? _libOf(Member? m) => m?.enclosingLibrary.importUri.toString();
  String? _ownerOf(Member? m) => m?.enclosingClass?.name;

  /// The declaration kind, read off the resolved Member rather than guessed.
  String? _kindOf(Member? m) => switch (m) {
    Field() => 'field',
    Constructor() => 'constructor',
    Procedure() => _procKind(m),
    _ => null,
  };

  void _record(Member? target, Name name, String mode) {
    if (!name.isPrivate) return;
    final lib = _libOf(target) ??
        name.libraryReference?.asLibrary.importUri.toString();
    final kind = _kindOf(target);
    // A reference whose declaration kind cannot be established is REFUSED, not
    // recorded with a guessed kind. "We could not tell which declaration this
    // was" must never become "here is a declaration that looks close enough".
    if (lib == null || kind == null) {
      r.unsupported.add('UnresolvedPrivateRef');
      return;
    }
    r.add(PrivateRef(lib, _ownerOf(target), kind, name.text, mode, true));
  }

  // ---- the fact-bearing nodes. NOTE: these call visitChildren directly, not
  // super.visitX, because super would route through defaultNode and mark an
  // allowlisted node unsupported.
  @override
  void visitInstanceSet(InstanceSet node) {
    _record(node.interfaceTarget, node.name, 'write');
    node.visitChildren(this);
  }

  @override
  void visitStaticSet(StaticSet node) {
    _record(node.target, node.target.name, 'write');
    node.visitChildren(this);
  }

  @override
  void visitInstanceGet(InstanceGet node) {
    _record(node.interfaceTarget, node.name, 'read');
    node.visitChildren(this);
  }

  @override
  void visitStaticGet(StaticGet node) {
    _record(node.target, node.target.name, 'read');
    node.visitChildren(this);
  }

  @override
  void visitInstanceInvocation(InstanceInvocation node) {
    _record(node.interfaceTarget, node.name, 'read');
    node.visitChildren(this);
  }

  @override
  void visitStaticInvocation(StaticInvocation node) {
    _record(node.target, node.target.name, 'read');
    for (final t in node.arguments.types) {
      _noteType(t);
    }
    node.visitChildren(this);
  }

  @override
  void visitConstructorInvocation(ConstructorInvocation node) {
    final cls = node.target.enclosingClass;
    if (_classIsPrivate(cls)) {
      r.privateTypes.add('${cls.enclosingLibrary.importUri}::${cls.name}');
      r.add(PrivateRef(cls.enclosingLibrary.importUri.toString(), cls.name,
          'constructor', node.target.name.text, 'construct', true));
    }
    for (final t in node.arguments.types) {
      _noteType(t);
    }
    node.visitChildren(this);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    _noteType(node.type);
    node.visitChildren(this);
  }

  @override
  void visitAsExpression(AsExpression node) {
    _noteType(node.type);
    node.visitChildren(this);
  }

  @override
  void visitIsExpression(IsExpression node) {
    _noteType(node.type);
    node.visitChildren(this);
  }
}

void main(List<String> args) {
  String? dillPath;
  var outPath = 'body_references.json';
  var census = false;
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
      case '--census':
        // Grounds the allowlist against real corpora instead of guessing it.
        census = true;
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
  final censusSeen = <String>{};

  void add(String library, String? owner, String kind, String name,
      Member m) {
    final refs = References();
    final f = m.function;
    if (f == null && m is! Field) {
      refs.unsupported.add('NoFunctionNode');
    }
    final w = _Walker(refs, census: census, seen: censusSeen);
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
    final all = refs.refs.values.toList()
      ..sort((a, b) => a.k.compareTo(b.k));
    rows.add({
      'library': library,
      'owner': owner,
      'kind': kind,
      'name': name,
      'references_private_type': refs.privateTypes.isNotEmpty,
      'private_types': refs.privateTypes.toList()..sort(),
      // STRUCTURED, so the predictor can join each reference to a G3 row and
      // ask the capability question rather than pattern-matching a string.
      'private_refs': [for (final r in all) r.toJson()],
      'private_writes': [for (final r in all) if (r.mode == 'write') r.k],
      'private_reads': [for (final r in all) if (r.mode == 'read') r.k],
      'unresolved_refs': [for (final r in all) if (!r.resolved) r.k],
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
  final withPrivateRead =
      rows.where((r) => (r['private_reads'] as List).isNotEmpty).length;
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
      'private_read_count': withPrivateRead,
      if (census) 'census_node_kinds': (censusSeen.toList()..sort()),
      'traversal_refused_count': refused,
      'rows': rows,
    })}\n',
  );
  print('  bodies=${rows.length} private-type-refs=$withPrivateType '
      'private-writes=$withPrivateWrite traversal-refused=$refused -> $outPath');
}
