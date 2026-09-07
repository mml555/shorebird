// Copyright (c) 2026, the Shorebird self-host fork.
//
// body_encoder.dart -- SEMANTIC-MAP-1 G2: a canonical, FAIL-CLOSED structural
// encoding of an implementation.
//
// WHY AN EXPLICIT ALLOWLIST AND NOT A GENERIC VISITOR.
//
// The first version walked the body with `RecursiveVisitor` and a `defaultNode`
// that emitted only the node's runtime type plus its children. That cannot
// support the claim "only source positions and local names are excluded": every
// scalar and reference field of every node it did not special-case was silently
// dropped. A body could differ in a field the encoder never looked at and be
// reported identical.
//
// So encoding is an explicit allowlist. Every supported node has its
// behaviour-relevant scalar and reference fields written out by hand. An
// unrecognised node kind does NOT fall back to something permissive -- it sets
// `unsupported` and the caller must refuse the row. An unsupported body can
// never become `candidate_unchanged`.
//
// FORMAL PARAMETERS ARE PART OF THE BODY'S SCOPE. The first version began at
// `f.body`, so formals never entered the local table and every reference to one
// encoded as `VarGet#-1`. `f(int a, int b) => a` and `=> b` were therefore
// identical. Formals are now registered, in declaration order, before the body
// is walked.
//
// TYPE NODES ARE NOT DESCENDED INTO. `visitChildren` walks into DartType nodes,
// which adds structure the ABI already covers and made the census noisy. Types
// are written through `typeText`, once, where they matter.
//
// ignore_for_file: implementation_imports
import 'package:kernel/ast.dart';

import 'type_text.dart';

/// The outcome of encoding one implementation.
class BodyEncoding {
  final String tokens;

  /// Set when a node kind outside the allowlist was reached. The caller must
  /// refuse the row rather than treat the encoding as complete.
  final Set<String> unsupportedKinds;

  BodyEncoding(this.tokens, this.unsupportedKinds);

  bool get supported => unsupportedKinds.isEmpty;

  String get status => supported
      ? 'supported'
      : 'refused:unsupported_node:${(unsupportedKinds.toList()..sort()).join(",")}';
}

class BodyEncoder {
  final StringBuffer _out = StringBuffer();
  final Map<VariableDeclaration, int> _locals = {};
  final Set<String> _unsupported = {};

  void _w(String s) => _out.write('$s;');

  int _ordinal(VariableDeclaration v) =>
      _locals.putIfAbsent(v, () => _locals.length);

  /// Encode a function: formals first, then the body.
  BodyEncoding encodeFunction(FunctionNode? f, {List<Initializer>? initializers}) {
    if (f == null) return BodyEncoding('no-function-node', const {});
    // Formals are REGISTERED but not emitted, and the return type is not
    // emitted at all. Both are ABI, and writing them into the body made the
    // body a partial function of the ABI -- the independence arm caught exactly
    // that when abi_return_type moved the body fingerprint. Registration is
    // still required so a reference to the first parameter is distinguishable
    // from a reference to the second.
    for (final p in f.positionalParameters) {
      _ordinal(p);
    }
    for (final p in f.namedParameters) {
      _ordinal(p);
    }
    if (initializers != null) {
      // Constructor initializer lists are separate Kernel structure and are not
      // reachable from f.body. Omitting them let `: sides = 4` -> `: sides = 5`
      // disappear entirely.
      for (final i in initializers) {
        _initializer(i);
      }
    }
    final body = f.body;
    if (body == null) {
      _w('no-body');
    } else {
      _statement(body);
    }
    return BodyEncoding(_out.toString(), _unsupported);
  }

  /// Encode a standalone expression, e.g. a field initializer.
  BodyEncoding encodeExpression(Expression? e) {
    if (e == null) {
      _w('no-initializer');
    } else {
      _expression(e);
    }
    return BodyEncoding(_out.toString(), _unsupported);
  }

  void _refuse(Node n) {
    _unsupported.add(n.runtimeType.toString());
    _w('UNSUPPORTED:${n.runtimeType}');
  }

  /// A target is keyed by CANONICAL NAME read off the Reference, never by
  /// dereferencing to a Member: the pre-AOT kernel may leave platform targets
  /// unbound, and both kernels must encode identically.
  static String _ref(Reference? r) =>
      r?.canonicalName?.toString() ?? '<unbound>';

  // ------------------------------------------------------------- statements
  void _statement(Statement s) {
    switch (s) {
      case Block():
        _w('Block:${s.statements.length}');
        for (final c in s.statements) {
          _statement(c);
        }
      case ExpressionStatement():
        _w('ExprStmt');
        _expression(s.expression);
      case ReturnStatement():
        _w('Return:${s.expression == null ? 'void' : 'value'}');
        final e = s.expression;
        if (e != null) _expression(e);
      case EmptyStatement():
        _w('Empty');
      case VariableDeclaration():
        // A local's NAME is excluded; its ordinal, type and initializer are not.
        _w('VarDecl#${_ordinal(s)}:${typeText(s.type)}'
            ':final=${s.isFinal}:const=${s.isConst}:late=${s.isLate}');
        final init = s.initializer;
        if (init != null) _expression(init);
      case IfStatement():
        _w('If:${s.otherwise != null}');
        _expression(s.condition);
        _statement(s.then);
        final o = s.otherwise;
        if (o != null) _statement(o);
      default:
        _refuse(s);
    }
  }

  // ------------------------------------------------------------ initializers
  void _initializer(Initializer i) {
    switch (i) {
      case FieldInitializer():
        _w('FieldInit:${_ref(i.fieldReference)}');
        _expression(i.value);
      case SuperInitializer():
        _w('SuperInit:${_ref(i.targetReference)}');
        _arguments(i.arguments);
      case RedirectingInitializer():
        _w('RedirectInit:${_ref(i.targetReference)}');
        _arguments(i.arguments);
      case LocalInitializer():
        _w('LocalInit');
        _statement(i.variable);
      default:
        _refuse(i);
    }
  }

  // ------------------------------------------------------------ expressions
  void _arguments(Arguments a) {
    // Named-argument NAMES are observable at a call site; type arguments are
    // part of what is invoked.
    _w('Args:${a.positional.length}'
        ':types=${a.types.map(typeText).join(",")}'
        ':named=${a.named.map((n) => n.name).join(",")}');
    for (final p in a.positional) {
      _expression(p);
    }
    for (final n in a.named) {
      _w('NamedArg:${n.name}');
      _expression(n.value);
    }
  }

  void _expression(Expression e) {
    switch (e) {
      case VariableGet():
        _w('VarGet#${_lookup(e.variable)}');
      case VariableSet():
        _w('VarSet#${_lookup(e.variable)}');
        _expression(e.value);
      case IntLiteral():
        _w('Int:${e.value}');
      case DoubleLiteral():
        _w('Double:${e.value}');
      case StringLiteral():
        _w('Str:${e.value}');
      case BoolLiteral():
        _w('Bool:${e.value}');
      case NullLiteral():
        _w('Null');
      case ThisExpression():
        _w('This');
      case ConstantExpression():
        // --aot folds literals into ConstantExpression, so the same source
        // reaches the two kernels as different node kinds. Both must encode to
        // the same tokens or every row would differ between them.
        _w('Const');
        _constant(e.constant);
      case StaticInvocation():
        _w('StaticInvoke:${_ref(e.targetReference)}:const=${e.isConst}');
        _arguments(e.arguments);
      case StaticGet():
        _w('StaticGet:${_ref(e.targetReference)}');
      case StaticSet():
        _w('StaticSet:${_ref(e.targetReference)}');
        _expression(e.value);
      case InstanceInvocation():
        _w('InstanceInvoke:${_ref(e.interfaceTargetReference)}'
            ':name=${e.name.text}');
        _expression(e.receiver);
        _arguments(e.arguments);
      case InstanceGet():
        _w('InstanceGet:${_ref(e.interfaceTargetReference)}:name=${e.name.text}');
        _expression(e.receiver);
      case InstanceSet():
        _w('InstanceSet:${_ref(e.interfaceTargetReference)}:name=${e.name.text}');
        _expression(e.receiver);
        _expression(e.value);
      case ConstructorInvocation():
        _w('CtorInvoke:${_ref(e.targetReference)}:const=${e.isConst}');
        _arguments(e.arguments);
      case Not():
        _w('Not');
        _expression(e.operand);
      case EqualsCall():
        _w('EqualsCall:${_ref(e.interfaceTargetReference)}');
        _expression(e.left);
        _expression(e.right);
      case EqualsNull():
        _w('EqualsNull');
        _expression(e.expression);
      case AsExpression():
        _w('As:${typeText(e.type)}:unchecked=${e.isUnchecked}');
        _expression(e.operand);
      case IsExpression():
        _w('Is:${typeText(e.type)}');
        _expression(e.operand);
      case ConditionalExpression():
        _w('Conditional:${typeText(e.staticType)}');
        _expression(e.condition);
        _expression(e.then);
        _expression(e.otherwise);
      case StringConcatenation():
        _w('StrConcat:${e.expressions.length}');
        for (final c in e.expressions) {
          _expression(c);
        }
      case Let():
        _w('Let');
        _statement(e.variable);
        _expression(e.body);
      // NamedExpression is a TreeNode, not an Expression subtype, and named
      // arguments are already written out explicitly by _arguments.
      default:
        _refuse(e);
    }
  }

  void _constant(Constant c) {
    switch (c) {
      case IntConstant():
        _w('Int:${c.value}');
      case DoubleConstant():
        _w('Double:${c.value}');
      case StringConstant():
        _w('Str:${c.value}');
      case BoolConstant():
        _w('Bool:${c.value}');
      case NullConstant():
        _w('Null');
      default:
        _unsupported.add('Constant:${c.runtimeType}');
        _w('UNSUPPORTED_CONST:${c.runtimeType}');
    }
  }

  /// -1 would silently conflate every unregistered reference, which is the
  /// defect that hid formal-parameter selection. An unregistered variable is
  /// now a refusal, not an ordinal.
  String _lookup(VariableDeclaration v) {
    final o = _locals[v];
    if (o == null) {
      _unsupported.add('UnregisteredVariable');
      return 'UNREGISTERED';
    }
    return '$o';
  }
}
