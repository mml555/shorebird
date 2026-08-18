// Copyright (c) 2026, the Shorebird self-host fork.
//
// this_offsets.dart -- can the KERNEL tell us exactly where a method body
// touches its receiver, and where those touches are in the source?
//
// This decides the shape of implicit-`this` lowering, and it is worth settling
// before writing a transformer, because the two candidate designs cost very
// different amounts:
//
//   A. a cell-owned Kernel transformer emitting a dill
//      -> needs dart2bytecode to accept a dill input, which is another Dart
//         fork change, another engine hash, another cell
//
//   B. kernel-RESOLVED, source-EDITED: the kernel says which identifiers are
//      receiver accesses and at what offset, and the producer rewrites exactly
//      those spans
//      -> no fork change at all
//
// B is only viable if the kernel carries a usable fileOffset for each access.
// The rule the design has to honour either way is the same: never re-derive
// Dart name resolution in the producer. In B the kernel still does all the
// resolving; text is only the transport.
//
// Run with the Dart tree's package config so package:kernel resolves:
//
//   dart --packages=<dart-tree>/.dart_tool/package_config.json \
//     this_offsets.dart --dill app.dill --target 'pkg:app/main.dart#Cls.member'
//
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_from_binary.dart';

void main(List<String> args) {
  String? dillPath;
  String? target;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--dill':
        dillPath = args[++i];
      case '--target':
        target = args[++i];
    }
  }
  if (dillPath == null || target == null) {
    stderr.writeln('need --dill and --target library#Class.member');
    exit(2);
  }

  final component = Component();
  BinaryBuilder(File(dillPath).readAsBytesSync()).readComponent(component);

  final hash = target.indexOf('#');
  final libraryUri = target.substring(0, hash);
  final selector = target.substring(hash + 1);
  final dot = selector.indexOf('.');
  final className = dot > 0 ? selector.substring(0, dot) : null;
  final memberName = dot > 0 ? selector.substring(dot + 1) : selector;

  Procedure? found;
  Class? owner;
  for (final lib in component.libraries) {
    if (lib.importUri.toString() != libraryUri) continue;
    if (className == null) {
      for (final p in lib.procedures) {
        if (p.name.text == memberName) found = p;
      }
    } else {
      for (final c in lib.classes.where((c) => c.name == className)) {
        for (final p in c.procedures) {
          if (p.name.text == memberName) {
            found = p;
            owner = c;
          }
        }
      }
    }
  }
  if (found == null) {
    stderr.writeln('no such member: $target');
    exit(3);
  }

  print('target        : $target');
  print('owner class   : ${owner?.name ?? '<top level>'}');
  print('is instance   : ${!found.isStatic}');
  print('declaration   : [${found.fileStartOffset}, ${found.fileEndOffset}]');
  print('source        : ${found.fileUri}');
  print('');

  final visitor = _ThisUses();
  found.function.accept(visitor);

  if (visitor.uses.isEmpty) {
    print('no receiver use — the existing top-level slicer already handles it');
    return;
  }
  print('receiver uses (what a lowering must rewrite):');
  final source = File.fromUri(found.fileUri).readAsStringSync();
  for (final u in visitor.uses) {
    final at = u.offset;
    final ok = at >= 0 && at < source.length;
    // The exact text at the offset is what decides design B: if the kernel
    // points at the identifier, a targeted edit is possible; if it points at
    // nothing useful, only a Kernel-to-dill transformer will do.
    final excerpt = ok
        ? source
              .substring(at, (at + 24).clamp(0, source.length))
              .split('\n')
              .first
        : '<no offset>';
    print('  ${u.kind.padRight(22)} ${u.name.padRight(16)} '
        'offset ${at.toString().padLeft(6)}  |$excerpt');
    print('    explicit `this` in source: ${u.explicitThis}');
    print('    resolved target          : ${u.resolved}');
  }
}

class _Use {
  _Use(this.kind, this.name, this.offset, this.explicitThis, this.resolved);
  final String kind;
  final String name;
  final int offset;
  final bool explicitThis;
  final String resolved;
}

/// Every access whose receiver is `this`, however it was spelled.
///
/// The point of doing this in kernel rather than over text: `label` and
/// `this.label` are the SAME node here, a local variable named `label` is a
/// different node entirely, and the interface target says whether it is a
/// getter, a setter or a method — none of which is recoverable from spelling.
class _ThisUses extends RecursiveVisitor {
  final uses = <_Use>[];

  bool _isThis(Expression e) => e is ThisExpression;

  /// Whether the source actually wrote `this.`, which only matters for
  /// deciding how many characters an edit has to replace.
  bool _explicit(Expression receiver) =>
      receiver is ThisExpression && receiver.fileOffset >= 0;

  @override
  void visitInstanceGet(InstanceGet node) {
    if (_isThis(node.receiver)) {
      uses.add(
        _Use(
          'instance get',
          node.name.text,
          node.fileOffset,
          _explicit(node.receiver),
          '${node.interfaceTarget.enclosingClass?.name}.'
              '${node.interfaceTarget.name.text}',
        ),
      );
    }
    node.visitChildren(this);
  }

  @override
  void visitInstanceSet(InstanceSet node) {
    if (_isThis(node.receiver)) {
      uses.add(
        _Use(
          'instance set',
          node.name.text,
          node.fileOffset,
          _explicit(node.receiver),
          '${node.interfaceTarget.enclosingClass?.name}.'
              '${node.interfaceTarget.name.text}',
        ),
      );
    }
    node.visitChildren(this);
  }

  @override
  void visitInstanceInvocation(InstanceInvocation node) {
    if (_isThis(node.receiver)) {
      uses.add(
        _Use(
          'instance invocation',
          node.name.text,
          node.fileOffset,
          _explicit(node.receiver),
          '${node.interfaceTarget.enclosingClass?.name}.'
              '${node.interfaceTarget.name.text}',
        ),
      );
    }
    node.visitChildren(this);
  }

  @override
  void visitThisExpression(ThisExpression node) {
    uses.add(_Use('bare this', 'this', node.fileOffset, true, '<receiver>'));
  }
}
