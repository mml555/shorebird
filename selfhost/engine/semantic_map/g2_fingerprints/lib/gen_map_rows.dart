// Copyright (c) 2026, the Shorebird self-host fork.
//
// gen_map_rows.dart -- SEMANTIC-MAP-1 G2: emit one map row per declaration,
// carrying THREE INDEPENDENT identities.
//
//   DECLARATION_ID    names the declaration              (SM1-G1's model)
//   ABI_FINGERPRINT   interface / shape
//   BODY_FINGERPRINT  canonical implementation structure
//
// They answer two independent questions:
//
//   same ABI + same body       -> candidate_unchanged
//   same ABI + different body  -> changed_existing_declaration
//   different ABI              -> not_reusable_under_old_abi
//
// NEITHER FINGERPRINT IS DERIVED FROM THE OTHER. The ABI is built from the
// declaration's signature nodes; the body is built from a walk of the function
// body. A body edit cannot move the ABI and a signature edit cannot move the
// body, and G2's corpus arms exist to demonstrate exactly that -- four of them
// change only a signature while leaving the body text identical.
//
// PRINTED KERNEL IS NOT THE CONTRACT. `packaging/build_patch.dart` prints
// Procedure nodes to decide whether a member changed, because binary offsets and
// canonical indices are unstable. That remains the INCUMBENT REFERENCE ORACLE
// and is emitted here as `incumbent_printed_sha256` for cross-checking -- it is
// not what either fingerprint is computed from.
//
// THIS TOOL DOES NOT ATTEMPT SEMANTIC EQUIVALENCE. Whether two differently
// written algorithms compute the same result is out of scope. The body
// fingerprint is a canonical STRUCTURE, not a meaning.
//
// WHICH KERNEL EACH FINGERPRINT COMES FROM, and why it is not one kernel.
//
// SM1-G2 measured that `gen_kernel --aot` STRIPS PARAMETERS:
//
//                         pre-AOT       AOT
//   topLevel(int x)       req=1 pos=1   req=0 pos=0
//   Shape.area(int,int)   req=2 pos=2   req=0 pos=0
//
// So an ABI computed from the AOT kernel is not the declared interface a caller
// depends on -- it is the post-TFA specialised signature, and two different
// declared signatures can erase to the same empty shape. Computing the ABI from
// the AOT kernel made `abi_added_positional` and `abi_positional_to_named`
// report abi_equal, which is exactly the over-claim SM1-G5 forbids.
//
//   DOMAIN  which declarations exist          AOT kernel  (conservative: only
//                                             what survived can be patchable)
//   ABI     the declared interface            PRE-AOT kernel
//   BODY    the implementation                BOTH, combined conservatively --
//                                             changed if EITHER moved, so the
//                                             map can never report unchanged
//                                             when something did change
//
// ignore_for_file: avoid_print, implementation_imports
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';
import 'package:kernel/src/printer.dart' show defaultAstTextStrategy;
import 'package:kernel/text/ast_to_text.dart' show Printer;

const String _sep = '\u0000';

String _hash(List<String> parts) =>
    sha256.convert(utf8.encode(parts.join(_sep))).toString();

String vmMemberName(String name, String kind) => switch (kind) {
  'getter' => 'get:$name',
  'setter' => 'set:$name',
  _ => name,
};

/// SM1-G1's identity, recomputed here rather than imported.
///
/// Deliberate duplication: the driver cross-checks this against G1's own tool on
/// the same input. If they shared code the check would prove nothing, which is
/// the same reasoning `coverage/parity.sh` applies to the reference tooling.
String canonicalId({
  required String library,
  required String ownerPath,
  required String kind,
  required String name,
}) => _hash([library, ownerPath, kind, name]);

/// Canonical text for a type. Structural, carries nullability and type
/// arguments, and contains no source position.
String typeText(DartType? t) =>
    t == null ? '<null>' : t.toText(defaultAstTextStrategy);

// ---------------------------------------------------------------- ABI shape
/// What the release-time contract can actually support today, STATED by the map
/// rather than left for a caller to infer.
///
/// ROADMAP P2 widened the replacement ABI to receiver + REQUIRED POSITIONALS.
/// Named, optional-positional and type arguments are deliberately unsupported
/// and refused before publication. A map that classified them as reusable would
/// be mis-stating the product.
String abiShape(FunctionNode? f) {
  if (f == null) return 'supported';
  if (f.typeParameters.isNotEmpty) return 'refused:type_parameters';
  if (f.namedParameters.isNotEmpty) return 'refused:named';
  if (f.positionalParameters.length != f.requiredParameterCount) {
    return 'refused:optional_positional';
  }
  return 'supported';
}

List<String> _abiOfFunction(FunctionNode f) => [
  'ret', typeText(f.returnType),
  'reqCount', '${f.requiredParameterCount}',
  // Type-parameter NAMES are excluded: they are not observable at a call site.
  // Position and bound are what a caller depends on. Exclusion #3, justified by
  // the g2_typeparam_rename arm.
  'typeParams',
  f.typeParameters
      .map((p) => typeText(p.bound))
      .join(','),
  'positional',
  f.positionalParameters.map((v) => typeText(v.type)).join(','),
  // Named-parameter NAMES are NOT excluded: a call site names them, so a rename
  // is an ABI break.
  'named',
  (f.namedParameters.map((v) => '${v.name}:${typeText(v.type)}'
          '${v.isRequired ? '!' : '?'}').toList()
        ..sort())
      .join(','),
];

// ------------------------------------------------------------ body encoding
/// A structural, order-preserving encoding of a function body.
///
/// EXCLUDED, each justified by an arm in the corpus:
///   1. source positions (fileOffset, file URIs) -- incidental source metadata
///   2. local variable NAMES, encoded by binding ordinal instead -- a local's
///      name is not observable (g2_local_rename)
///
/// NOT EXCLUDED, deliberately:
///   * statement and expression ORDER -- execution order is observable
///     (g2_stmt_order proves the encoding moves when order does)
///   * literal values -- `x + 1` and `x + 2` must differ (body_only)
///   * invocation target identities -- calling a different function is a
///     different body
///   * named-argument names at call sites
class _BodyEncoder extends RecursiveVisitor {
  final StringBuffer out = StringBuffer();
  final Map<VariableDeclaration, int> _locals = {};

  void _emit(String s) => out.write('$s;');

  int _ordinal(VariableDeclaration v) =>
      _locals.putIfAbsent(v, () => _locals.length);

  @override
  void defaultNode(Node node) {
    // The node KIND, and nothing positional about where it came from.
    _emit(node.runtimeType.toString());
    node.visitChildren(this);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    _emit('VarDecl#${_ordinal(node)}:${typeText(node.type)}');
    node.visitChildren(this);
  }

  @override
  void visitVariableGet(VariableGet node) {
    _emit('VarGet#${_locals[node.variable] ?? -1}');
    node.visitChildren(this);
  }

  @override
  void visitVariableSet(VariableSet node) {
    _emit('VarSet#${_locals[node.variable] ?? -1}');
    node.visitChildren(this);
  }

  @override
  void visitIntLiteral(IntLiteral node) => _emit('Int:${node.value}');

  @override
  void visitDoubleLiteral(DoubleLiteral node) => _emit('Double:${node.value}');

  @override
  void visitStringLiteral(StringLiteral node) => _emit('Str:${node.value}');

  @override
  void visitBoolLiteral(BoolLiteral node) => _emit('Bool:${node.value}');

  @override
  void visitNullLiteral(NullLiteral node) => _emit('Null');

  @override
  void visitStaticInvocation(StaticInvocation node) {
    _emit('StaticInvoke:${_refKey(node.targetReference)}');
    node.visitChildren(this);
  }

  @override
  void visitStaticGet(StaticGet node) {
    _emit('StaticGet:${_refKey(node.targetReference)}');
    node.visitChildren(this);
  }

  @override
  void visitInstanceInvocation(InstanceInvocation node) {
    _emit('InstanceInvoke:${_refKey(node.interfaceTargetReference)}');
    node.visitChildren(this);
  }

  @override
  void visitInstanceGet(InstanceGet node) {
    _emit('InstanceGet:${_refKey(node.interfaceTargetReference)}');
    node.visitChildren(this);
  }

  @override
  void visitInstanceSet(InstanceSet node) {
    _emit('InstanceSet:${_refKey(node.interfaceTargetReference)}');
    node.visitChildren(this);
  }

  @override
  void visitConstructorInvocation(ConstructorInvocation node) {
    _emit('CtorInvoke:${_refKey(node.targetReference)}');
    node.visitChildren(this);
  }

  @override
  void visitArguments(Arguments node) {
    // Named-argument names are observable at a call site.
    _emit('Args:${node.named.map((n) => n.name).join(',')}'
        ':${node.types.map(typeText).join(',')}');
    node.visitChildren(this);
  }

  /// A target is identified by its CANONICAL NAME, never by a reference index.
  ///
  /// Read from the Reference rather than by dereferencing to a Member: the
  /// pre-AOT kernel is built `--no-link-platform`, so `dart:core` targets are
  /// unbound and `interfaceTarget` throws
  ///
  ///   Reference to dart:core::num::@methods::+ is not bound to an AST node
  ///
  /// The canonical name carries library, class and member and is available
  /// whether or not the platform was linked, so it works on both kernels --
  /// which is required, since the body is fingerprinted from both.
  static String _refKey(Reference? r) {
    if (r == null) return '<none>';
    final cn = r.canonicalName;
    return cn == null ? '<unbound>' : cn.toString();
  }
}

String bodyFingerprint(FunctionNode? f) {
  if (f == null) return _hash(['no-function-node']);
  final body = f.body;
  if (body == null) return _hash(['no-body']);
  final enc = _BodyEncoder();
  body.accept(enc);
  return _hash(['body', enc.out.toString()]);
}

/// The INCUMBENT oracle: printed Kernel, as `build_patch.dart` computes it.
/// Emitted for cross-checking only; neither fingerprint is derived from it.
String incumbentPrinted(Member m) {
  final buffer = StringBuffer();
  Printer(buffer).writeNode(m);
  return sha256.convert(utf8.encode(buffer.toString())).toString();
}

void main(List<String> args) {
  String? dillPath;
  String? preDillPath;
  var outPath = 'map_rows.json';
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
      case '--pre-dill':
        preDillPath = next();
      case '--out':
        outPath = next();
      case '--include':
        includePrefixes.add(next());
      case '-h':
      case '--help':
        print('gen_map_rows.dart --dill <aot.dill> --pre-dill <preaot.dill> '
            '[--out out.json] [--include <library-uri-prefix>]...');
        return;
      default:
        _die('unknown argument: $a');
    }
  }
  if (dillPath == null) _die('--dill is required');
  if (preDillPath == null) {
    _die('--pre-dill is required: the ABI cannot be read from the AOT kernel, '
        'which strips parameters');
  }

  final component = Component();
  BinaryBuilder(File(dillPath).readAsBytesSync()).readComponent(component);
  final preComponent = Component();
  BinaryBuilder(File(preDillPath).readAsBytesSync()).readComponent(preComponent);

  bool isApp(Library lib) {
    final uri = lib.importUri.toString();
    if (uri.startsWith('dart:')) return false;
    if (includePrefixes.isEmpty) return true;
    return includePrefixes.any(uri.startsWith);
  }

  // The pre-AOT kernel, indexed by the same structured key the identity uses.
  // The ABI and the pre-AOT body are read from here.
  final preByKey = <String, Member>{};
  String memberKeyOf(String library, String? owner, String kind, String name) =>
      _hash([library, owner ?? '', kind, name]);
  for (final lib in preComponent.libraries.where(isApp)) {
    final library = lib.importUri.toString();
    for (final p in lib.procedures) {
      preByKey[memberKeyOf(library, null, _procKind(p), p.name.text)] = p;
    }
    for (final f in lib.fields) {
      preByKey[memberKeyOf(library, null, 'field', f.name.text)] = f;
    }
    for (final cls in lib.classes) {
      for (final p in cls.procedures) {
        preByKey[memberKeyOf(library, cls.name, _procKind(p), p.name.text)] = p;
      }
      for (final c in cls.constructors) {
        preByKey[memberKeyOf(library, cls.name, 'constructor', c.name.text)] = c;
      }
      for (final f in cls.fields) {
        preByKey[memberKeyOf(library, cls.name, 'field', f.name.text)] = f;
      }
    }
  }
  final preClasses = <String, Class>{};
  for (final lib in preComponent.libraries.where(isApp)) {
    for (final cls in lib.classes) {
      preClasses[memberKeyOf(lib.importUri.toString(), null, 'class', cls.name)] = cls;
    }
  }

  final extensionOwner = <Reference, List<String>>{};
  for (final lib in component.libraries.where(isApp)) {
    for (final ext in lib.extensions) {
      for (final d in ext.memberDescriptors) {
        final ref = d.memberReference;
        if (ref != null) extensionOwner[ref] = [ext.name, d.name.text];
      }
    }
  }

  final rows = <Map<String, Object?>>[];

  void addRow({
    required String library,
    required String? owner,
    required String name,
    required String kind,
    required List<String> abiParts,
    required String shape,
    required String body,
    required String? printed,
    bool isStatic = false,
    String? loweredName,
    String? ownerKind,
    String? bodyPre,
    bool abiFromPreAot = false,
  }) {
    // CONSERVATIVE BODY COMBINATION. Changed if EITHER kernel's body moved, so
    // the map can never report unchanged when something did change.
    final bodyCombined = bodyPre == null
        ? body
        : _hash(['body-combined', body, bodyPre]);
    rows.add({
      'library': library,
      'owner': owner,
      'name': name,
      'kind': kind,
      'ownerKind': ownerKind,
      'loweredName': loweredName,
      'static': isStatic,
      'vmName': vmMemberName(loweredName ?? name, kind),
      'declaration_id': canonicalId(
        library: library,
        ownerPath: owner ?? '',
        kind: kind,
        name: name,
      ),
      'abi_fingerprint': _hash(['abi', kind, '$isStatic', owner ?? '', ...abiParts]),
      'abi_shape': shape,
      'abi_components': abiParts,
      'abi_source': abiFromPreAot ? 'pre_aot_kernel' : 'aot_kernel',
      'body_fingerprint': bodyCombined,
      'body_fingerprint_aot': body,
      'body_fingerprint_pre_aot': bodyPre,
      'incumbent_printed_sha256': printed,
    });
  }

  for (final lib in component.libraries.where(isApp)) {
    final library = lib.importUri.toString();

    void addProcedure(Procedure p, String? owner) {
      final ext = extensionOwner[p.reference];
      final rowOwner = ext?[0] ?? owner;
      final rowName = ext?[1] ?? p.name.text;
      // The ABI comes from the PRE-AOT member, because --aot strips parameters.
      // When there is no pre-AOT counterpart the ABI is UNAVAILABLE and is
      // recorded as such -- never silently taken from the AOT signature.
      final pre = preByKey[memberKeyOf(library, owner, _procKind(p), p.name.text)];
      final preFn = pre is Procedure ? pre.function : null;
      addRow(
        library: library,
        owner: rowOwner,
        name: rowName,
        kind: _procKind(p),
        isStatic: p.isStatic || owner == null,
        abiParts: preFn == null
            ? const ['abi', 'UNAVAILABLE_NO_PRE_AOT_COUNTERPART']
            : _abiOfFunction(preFn),
        shape: preFn == null ? 'unknown:no_pre_aot_counterpart' : abiShape(preFn),
        body: bodyFingerprint(p.function),
        bodyPre: preFn == null ? null : bodyFingerprint(preFn),
        printed: incumbentPrinted(p),
        loweredName: ext == null ? null : p.name.text,
        ownerKind: ext == null ? null : 'extension',
        abiFromPreAot: preFn != null,
      );
    }

    for (final p in lib.procedures) {
      addProcedure(p, null);
    }
    for (final f in lib.fields) {
      final preF = preByKey[memberKeyOf(library, null, 'field', f.name.text)];
      final ft = preF is Field ? preF : f;
      addRow(
        library: library, owner: null, name: f.name.text, kind: 'field',
        isStatic: true,
        abiFromPreAot: preF is Field,
        abiParts: ['type', typeText(ft.type), 'final', '${ft.isFinal}',
                   'const', '${ft.isConst}'],
        shape: 'supported',
        body: _hash(['field-initializer', f.initializer == null ? 'none' : 'present']),
        printed: incumbentPrinted(f),
      );
    }
    for (final cls in lib.classes) {
      final preCls = preClasses[memberKeyOf(library, null, 'class', cls.name)] ?? cls;
      addRow(
        library: library, owner: null, name: cls.name, kind: 'class',
        abiFromPreAot: preClasses.containsKey(
            memberKeyOf(library, null, 'class', cls.name)),
        // A class's ABI is its shape as a TYPE: type parameters and bounds,
        // supertype, mixin and interfaces. A generic bound lives here and on no
        // member, which is why SM1-G1 had to name classes at all.
        abiParts: [
          'typeParams', preCls.typeParameters.map((p) => typeText(p.bound)).join(','),
          'super', typeText(preCls.supertype?.asInterfaceType),
          'mixin', typeText(preCls.mixedInType?.asInterfaceType),
          'implements',
          (preCls.implementedTypes.map((t) => typeText(t.asInterfaceType)).toList()..sort())
              .join(','),
          'abstract', '${preCls.isAbstract}',
        ],
        shape: preCls.typeParameters.isEmpty
            ? 'supported'
            : 'refused:type_parameters',
        body: _hash(['class-has-no-body']),
        printed: null,
      );
      for (final p in cls.procedures) {
        addProcedure(p, cls.name);
      }
      for (final c in cls.constructors) {
        final pre = preByKey[memberKeyOf(library, cls.name, 'constructor', c.name.text)];
        final preFn = pre is Constructor ? pre.function : null;
        addRow(
          library: library, owner: cls.name, name: c.name.text, kind: 'constructor',
          abiParts: preFn == null
              ? const ['abi', 'UNAVAILABLE_NO_PRE_AOT_COUNTERPART']
              : _abiOfFunction(preFn),
          shape: preFn == null ? 'unknown:no_pre_aot_counterpart' : abiShape(preFn),
          body: bodyFingerprint(c.function),
          bodyPre: preFn == null ? null : bodyFingerprint(preFn),
          printed: incumbentPrinted(c),
          abiFromPreAot: preFn != null,
        );
      }
      for (final f in cls.fields) {
        final preF = preByKey[memberKeyOf(library, cls.name, 'field', f.name.text)];
        final ft = preF is Field ? preF : f;
        addRow(
          library: library, owner: cls.name, name: f.name.text, kind: 'field',
          isStatic: f.isStatic,
          abiFromPreAot: preF is Field,
          abiParts: ['type', typeText(ft.type), 'final', '${ft.isFinal}',
                     'const', '${ft.isConst}'],
          shape: 'supported',
          body: _hash(['field-initializer', f.initializer == null ? 'none' : 'present']),
          printed: incumbentPrinted(f),
        );
      }
    }
  }

  rows.sort((a, b) {
    for (final k in ['library', 'owner', 'kind', 'name']) {
      final c = (a[k] ?? '').toString().compareTo((b[k] ?? '').toString());
      if (c != 0) return c;
    }
    return 0;
  });

  File(outPath).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({
      'schema': 'semantic-map-1/map-rows/1',
      'sourceDill': dillPath,
      'preAotDill': preDillPath,
      'count': rows.length,
      'contract': {
        'kernel_domains':
            'DOMAIN (which declarations exist) comes from the AOT kernel, the '
            'conservative choice. ABI comes from the PRE-AOT kernel, because '
            '--aot strips parameters: topLevel(int x) reads req=1 pre-AOT and '
            'req=0 after, so two different declared signatures erase to the '
            'same empty shape and an AOT-derived ABI over-claims. BODY is '
            'combined from both and counts as changed if EITHER moved.',
        'independence':
            'abi_fingerprint is built from signature nodes and body_fingerprint '
            'from a walk of the function body. Neither is derived from the other.',
        'incumbent':
            'incumbent_printed_sha256 is printed Kernel as build_patch.dart '
            'computes it -- a reference ORACLE for cross-checking, never the '
            'contract, and not an input to either fingerprint.',
        'body_exclusions': [
          'source positions (fileOffset, file URIs) -- incidental source metadata',
          'local variable NAMES, encoded by binding ordinal instead -- a local '
              'name is not observable (justified by g2_local_rename)',
        ],
        'body_non_exclusions': [
          'statement and expression ORDER -- execution order is observable '
              '(g2_stmt_order)',
          'literal values (body_only)',
          'invocation target declaration identities',
          'named-argument names at call sites',
        ],
        'abi_exclusions': [
          'type-parameter NAMES, encoded by position and bound -- not observable '
              'at a call site (justified by g2_typeparam_rename)',
        ],
        'abi_shape':
            'States the ROADMAP P2 refusal boundary in the map itself: named, '
            'optional-positional and type arguments are refused before '
            'publication, so the map says so rather than classifying them '
            'reusable.',
      },
      'rows': rows,
    })}\n',
  );
  stderr.writeln('wrote $outPath  rows=${rows.length}');
}

String _procKind(Procedure p) => switch (p.kind) {
  ProcedureKind.Getter => 'getter',
  ProcedureKind.Setter => 'setter',
  ProcedureKind.Operator => 'operator',
  ProcedureKind.Factory => 'factory',
  ProcedureKind.Method => 'method',
};

Never _die(String message) {
  stderr.writeln('error: $message');
  exit(2);
}
